import SwiftUI
import SSHKeeperCore

struct KeygenSheet: View {
    let manager: KeyManager
    @Environment(\.dismiss) private var dismiss

    @State private var type: KeyType = .ed25519
    @State private var bits: Int = 4096
    @State private var comment: String = defaultComment()
    @State private var fileName: String = "id_ed25519_sshkeeper"
    @State private var passphrase: String = ""
    @State private var passphraseConfirm: String = ""
    @State private var addToKeychain: Bool = true
    @State private var generating = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("类型") {
                    Picker("算法", selection: $type) {
                        Text("Ed25519（推荐）").tag(KeyType.ed25519)
                        Text("RSA").tag(KeyType.rsa)
                        Text("ECDSA").tag(KeyType.ecdsa)
                    }
                    .onChange(of: type) { _, newValue in
                        fileName = defaultFileName(for: newValue)
                    }
                    if type == .rsa {
                        Picker("位数", selection: $bits) {
                            Text("2048").tag(2048)
                            Text("3072").tag(3072)
                            Text("4096").tag(4096)
                        }
                    }
                }
                Section("文件") {
                    TextField("文件名（保存到 ~/.ssh/ 下）", text: $fileName)
                    TextField("注释（comment）", text: $comment)
                }
                Section("Passphrase") {
                    SecureField("Passphrase（留空表示无）", text: $passphrase)
                    SecureField("确认", text: $passphraseConfirm)
                    Toggle("生成后加入 Keychain（Touch ID 解锁）", isOn: $addToKeychain)
                        .disabled(passphrase.isEmpty)
                }
                if let error = manager.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("生成") { generate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || generating)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 480)
        .navigationTitle("新建密钥")
    }

    private var isValid: Bool {
        !fileName.trimmingCharacters(in: .whitespaces).isEmpty &&
        passphrase == passphraseConfirm
    }

    private func generate() {
        generating = true
        let path = "~/.ssh/" + fileName.trimmingCharacters(in: .whitespaces)
        let options = KeygenRunner.Options(
            type: type,
            bitLength: type == .rsa ? bits : nil,
            comment: comment,
            path: path,
            passphrase: passphrase
        )
        let shouldKeychain = addToKeychain && !passphrase.isEmpty
        Task {
            await manager.generate(options, addToKeychain: shouldKeychain)
            generating = false
            if manager.lastError == nil { dismiss() }
        }
    }

    private static func defaultComment() -> String {
        let user = ProcessInfo.processInfo.userName
        let host = ProcessInfo.processInfo.hostName
        return "\(user)@\(host)"
    }

    private func defaultFileName(for type: KeyType) -> String {
        switch type {
        case .ed25519: "id_ed25519_sshkeeper"
        case .rsa: "id_rsa_sshkeeper"
        case .ecdsa: "id_ecdsa_sshkeeper"
        case .dsa: "id_dsa_sshkeeper"
        case .unknown: "id_ed25519_sshkeeper"
        }
    }
}
