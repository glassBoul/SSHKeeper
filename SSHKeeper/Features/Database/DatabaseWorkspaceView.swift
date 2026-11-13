import SwiftUI
import SSHKeeperCore

/// 数据库工作台窗口主视图。顶部一条 DB tab 栏，主区渲染 active session 的 `DatabaseQueryView`。
struct DatabaseWorkspaceView: View {
    @Environment(DatabaseWorkspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .navigationTitle("数据库工作台")
        .onDisappear {
            // 工作台窗口关闭 → 把所有 session 断开释放，避免 NIO 连接泄漏。
            // 用 detached 强引用 workspace，确保 disconnect 跑完再让对象释放。
            let ws = workspace
            Task.detached(priority: .background) {
                await ws.disconnectAll()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session = workspace.activeSession {
            // .id 让切换 tab 时彻底重建 DatabaseQueryView 的内部 @State，
            // 避免 SQL 编辑器 / sidebar 滚动位置串到错误 session 上。
            DatabaseQueryView(session: session)
                .id(session.database.id)
        } else {
            ContentUnavailableView(
                "没有打开的数据库",
                systemImage: "tablecells",
                description: Text("回到主窗口选一个数据库点「打开」")
            )
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.sessions, id: \.database.id) { session in
                        DBTabChip(
                            session: session,
                            isActive: session.database.id == workspace.activeSessionID,
                            onSelect: { workspace.setActive(session.database.id) },
                            onClose: { workspace.close(databaseID: session.database.id) }
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

private struct DBTabChip: View {
    let session: DatabaseSession
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var statusColor: Color {
        switch session.status {
        case .disconnected: .gray
        case .connecting: .yellow
        case .connected: .green
        case .error: .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.database.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(session.database.kind.displayName) · \(session.database.host)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 220, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .opacity(hovering || isActive ? 0.9 : 0.4)
            .help("关闭这个数据库标签")
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
