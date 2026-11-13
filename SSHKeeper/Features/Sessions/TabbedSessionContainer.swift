import SwiftUI

struct TabbedSessionContainer: View {
    @Bindable var engine: SessionEngine

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(engine.sessions) { session in
                    TabButton(
                        session: session,
                        isActive: session.id == engine.activeSessionID,
                        onSelect: { engine.activeSessionID = session.id },
                        onClose: { engine.closeSession(id: session.id) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var content: some View {
        if engine.sessions.isEmpty {
            ContentUnavailableView(
                "无活动会话",
                systemImage: "terminal",
                description: Text("从左侧选择主机点击连接以打开新会话。")
            )
        } else {
            // 把所有 session 同时挂在 view tree 里，仅靠 opacity / hitTesting 控制可见
            // 性。这样切 tab 不会触发 SSHTerminalView dismantle → ssh 子进程一直活着，
            // 滚动 buffer / 当前命令 / vim 状态都保留。
            ZStack {
                ForEach(engine.sessions) { session in
                    SessionContent(engine: engine, session: session)
                        .opacity(session.id == engine.activeSessionID ? 1 : 0)
                        .allowsHitTesting(session.id == engine.activeSessionID)
                }
            }
        }
    }
}

private struct SessionContent: View {
    let engine: SessionEngine
    let session: Session

    var body: some View {
        switch session.split {
        case .none:
            if let pane = session.panes.first {
                paneView(pane)
            }
        case .vertical:
            HSplitView {
                ForEach(session.panes) { pane in
                    paneView(pane)
                        .frame(minWidth: 240)
                }
            }
        case .horizontal:
            VSplitView {
                ForEach(session.panes) { pane in
                    paneView(pane)
                        .frame(minHeight: 120)
                }
            }
        }
    }

    private func paneView(_ pane: Pane) -> some View {
        PaneView(
            engine: engine,
            session: session,
            pane: pane
        )
    }
}

private struct PaneView: View {
    let engine: SessionEngine
    let session: Session
    let pane: Pane
    @Environment(UploadCoordinator.self) private var uploadCoordinator

    var body: some View {
        ZStack {
            Color.black
            SSHTerminalView(
                alias: pane.alias,
                onTitleChange: { title in
                    engine.updatePaneTitle(sessionID: session.id, paneID: pane.id, title: title)
                },
                onProcessExit: { code in
                    engine.markPaneExited(sessionID: session.id, paneID: pane.id, code: code)
                },
                onDrop: { urls in
                    uploadCoordinator.beginUpload(alias: pane.alias, items: urls)
                }
            )
            if case .exited(let code) = pane.status {
                exitedOverlay(code: code)
            }
            if session.panes.count > 1 {
                activeIndicator
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture {
            engine.setActivePane(sessionID: session.id, paneID: pane.id)
        }
    }

    @ViewBuilder
    private var activeIndicator: some View {
        if pane.id == session.activePaneID {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                .padding(1)
                .allowsHitTesting(false)
        }
    }

    private func exitedOverlay(code: Int32?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Text("会话已结束\(code.map { " (exit \($0))" } ?? "")")
                        .font(.headline)
                    Button(session.panes.count > 1 ? "关闭此 pane" : "关闭标签") {
                        engine.closePane(sessionID: session.id, paneID: pane.id)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                Spacer()
            }
            Spacer()
        }
        .background(Color.black.opacity(0.4))
    }
}

private struct TabButton: View {
    let session: Session
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(session.displayTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200)
            if session.panes.count > 1 {
                Image(systemName: session.split == .horizontal ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .opacity(hovering || isActive ? 1 : 0.4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(session.primaryAlias)
    }

    private var statusColor: Color {
        if session.anyRunning { return .green }
        return .red
    }
}
