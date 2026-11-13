import SwiftUI
import SSHKeeperCore

struct IncludeConsentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let bootstrap: IncludeBootstrap
    let onCompletion: (Result<URL?, Error>) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.horizontal")
                    .font(.title)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text("接管 ~/.ssh/config")
                        .font(.title2.weight(.semibold))
                    Text("App 想在你 ~/.ssh/config 顶部加入一行：")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 12)

            Text("Include \(bootstrap.includePattern)")
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 8) {
                bullet("App 写入的主机会落到 ~/.ssh/config.d/sshkeeper.conf，命令行 ssh foo 直接可用")
                bullet("操作前会备份当前文件到 ~/.ssh/config.bak.<时间戳>")
                bullet("你手写的 config 主体不会被 App 修改")
                bullet("你也可以拒绝；App 仍可工作，但只在 App 内部使用，命令行 ssh 不会感知 App 添加的主机")
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.bottom, 20)

            HStack {
                Spacer()
                Button("暂不") {
                    onCompletion(.success(nil))
                    dismiss()
                }
                Button("加入并备份") {
                    do {
                        let backup = try bootstrap.injectInclude()
                        onCompletion(.success(backup))
                    } catch {
                        onCompletion(.failure(error))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 540)
        .frame(minHeight: 360)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.tint)
            Text(text)
            Spacer()
        }
    }
}
