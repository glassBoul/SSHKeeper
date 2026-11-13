import SwiftUI
import SSHKeeperCore

/// 更新弹窗。根据 coordinator.presentation 切换 3 种内容。
struct UpdateSheet: View {
    let presentation: UpdateCoordinator.Presentation
    let onDownload: () -> Void
    let onSkip: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Group {
            switch presentation {
            case .hidden:
                EmptyView()  // 实际不渲染；sheet 路由层用 isPresented 决定
            case .newVersion(let info):
                newVersionView(info: info)
            case .latest(let current):
                latestView(currentVersion: current)
            case .error(let msg):
                errorView(message: msg)
            }
        }
        .frame(minWidth: 460, idealWidth: 520)
    }

    private func newVersionView(info: VersionInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("发现新版本")
                        .font(.headline)
                    Text("当前 \(UpdateCoordinator.currentVersion) → 最新 \(info.latest)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("更新说明")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(info.releaseNotes)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
            }

            HStack {
                Button("跳过此版本") { onSkip() }
                Spacer()
                Button("稍后") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("下载") { onDownload() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private func latestView(currentVersion: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text("已是最新版本")
                .font(.headline)
            Text("当前版本：\(currentVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("好") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text("无法获取更新信息")
                    .font(.headline)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("好") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}
