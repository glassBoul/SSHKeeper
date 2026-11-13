import SwiftUI
import SSHKeeperCore

struct PanelLoginContainer: View {
    let panelID: UUID
    @Environment(PanelStore.self) private var store

    @State private var status: PanelLoginStatus = .loading
    @State private var title: String = ""
    @State private var progress: Double = 0

    var body: some View {
        if let panel = store.panel(id: panelID) {
            VStack(spacing: 0) {
                statusBar(panel: panel)
                progressBar
                Divider()
                if let password = PasswordKeychain.read(alias: keychainAlias(for: panel)) {
                    PanelWebView(
                        panel: panel,
                        password: password,
                        onTitleChange: { title = $0 },
                        onStatusChange: { status = $0 },
                        onProgressChange: { progress = $0 }
                    )
                    .onAppear {
                        try? store.touch(id: panel.id)
                    }
                } else {
                    ContentUnavailableView(
                        "未保存密码",
                        systemImage: "lock.slash",
                        description: Text("请回到主窗口编辑该面板，填上密码后再登录。")
                    )
                }
            }
            .navigationTitle(title.isEmpty ? panel.name : title)
            .frame(minWidth: 800, minHeight: 560)
        } else {
            ContentUnavailableView(
                "面板不存在",
                systemImage: "questionmark.folder"
            )
        }
    }

    private func statusBar(panel: Panel) -> some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(panel.url)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var progressBar: some View {
        // 加载中显示一条 2px 蓝条，进度从 0→1；满载或错误状态隐藏
        let isActive: Bool = {
            switch status {
            case .loading, .filledNoButton, .noForm: return progress > 0 && progress < 1
            default: return false
            }
        }()
        if isActive {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
                .scaleEffect(x: 1, y: 0.6, anchor: .center)
                .frame(height: 2)
        } else {
            Rectangle().fill(Color.clear).frame(height: 2)
        }
    }

    private var statusColor: Color {
        switch status {
        case .loading: .yellow
        case .submitted: .green
        case .filledNoButton: .orange
        case .noForm: .gray
        case .error: .red
        }
    }

    private var statusText: String {
        switch status {
        case .loading:
            if progress > 0 && progress < 1 {
                return "加载中… \(Int(progress * 100))%"
            }
            return "加载中…"
        case .submitted: return "已自动填充并提交"
        case .filledNoButton: return "已填充表单，未找到提交按钮，请回车或手动点登录"
        case .noForm: return "未在当前页找到登录表单"
        case .error(let msg): return msg
        }
    }

    private func keychainAlias(for panel: Panel) -> String {
        "panel:\(panel.id.uuidString)"
    }
}
