import SwiftUI
import SSHKeeperCore

/// 面板工作台窗口主视图。顶部一条面板 tab 栏；主区用 ZStack 同时挂载所有面板 container，
/// 用 opacity / allowsHitTesting 切换可见 —— 这样切 tab 不会重建 WKWebView，登录态保留。
struct PanelWorkspaceView: View {
    @Environment(PanelWorkspace.self) private var workspace
    @Environment(PanelStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle("面板工作台")
        .onDisappear {
            // 关掉工作台窗口 → 清空 tab 列表（对齐 DB workspace 的 disconnectAll 语义）。
            // 否则再次打开会重建所有 WKWebView 并重新登录。
            workspace.closeAll()
        }
    }

    @ViewBuilder
    private var content: some View {
        if workspace.panelIDs.isEmpty {
            ContentUnavailableView(
                "没有打开的面板",
                systemImage: "rectangle.stack",
                description: Text("回到主窗口选一个面板点「打开」")
            )
        } else {
            ZStack {
                ForEach(workspace.panelIDs, id: \.self) { id in
                    let isActive = id == workspace.activePanelID
                    PanelLoginContainer(panelID: id)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        // 非活动 tab 不进 a11y 树，避免 VoiceOver 读到隐藏内容。
                        .accessibilityHidden(!isActive)
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.panelIDs, id: \.self) { id in
                        PanelTabChip(
                            panel: store.panel(id: id),
                            isActive: id == workspace.activePanelID,
                            onSelect: { workspace.setActive(id) },
                            onClose: { workspace.close(panelID: id) }
                        )
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }
}

private struct PanelTabChip: View {
    let panel: Panel?
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(panel?.name ?? "(已删除)")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let url = panel?.url {
                    Text(url)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .opacity(hovering || isActive ? 0.9 : 0.4)
            .help("关闭这个面板标签")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isActive ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isActive ? Color.accentColor.opacity(0.5) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}
