import SwiftUI
import SSHKeeperCore

struct CopyIdSheet: View {
    let manager: KeyManager
    let key: KeyRef
    @Binding var target: String
    @Binding var result: String?
    @Environment(\.dismiss) private var dismiss
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("推送公钥到远端").font(.title2.weight(.semibold))
            Text("将运行：ssh-copy-id -i \(key.publicKeyPath ?? "—") <目标>")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("目标（user@host 或别名）", text: $target)
            if let result {
                ScrollView {
                    Text(result)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("推送") {
                    run()
                }
                .buttonStyle(.borderedProminent)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty || running)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func run() {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        running = true
        Task {
            let outcome = await manager.copyId(key: key, target: trimmed)
            result = outcome?.combinedOutput ?? "未执行"
            running = false
        }
    }
}
