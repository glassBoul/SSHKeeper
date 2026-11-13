import SwiftUI
import AppKit
import SSHKeeperCore

struct HostEditorView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let editing: SSHHost?

    @State private var alias: String
    @State private var hostname: String
    @State private var port: String
    @State private var user: String
    @State private var identityFile: String
    @State private var proxyJump: String
    @State private var groupID: UUID?
    @State private var tagsText: String
    @State private var saveError: String?
    @State private var availableKeys: [KeyRef] = []
    @State private var passwordInput: String = ""
    @State private var passwordDirty: Bool = false
    @State private var hasStoredPassword: Bool

    init(editing: SSHHost? = nil, preselectedGroupID: UUID? = nil) {
        self.editing = editing
        _alias = State(initialValue: editing?.alias ?? "")
        _hostname = State(initialValue: editing?.hostname ?? "")
        _port = State(initialValue: String(editing?.port ?? 22))
        _user = State(initialValue: editing?.user ?? "")
        _identityFile = State(initialValue: editing?.identityFile ?? "")
        _proxyJump = State(initialValue: editing?.proxyJump ?? "")
        _groupID = State(initialValue: editing?.groupID ?? preselectedGroupID)
        _tagsText = State(initialValue: editing?.tags.joined(separator: ", ") ?? "")
        _hasStoredPassword = State(
            initialValue: editing.map { PasswordKeychain.has(alias: $0.alias) } ?? false
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("基本") {
                    TextField("别名（ssh <alias>）", text: $alias)
                        .disabled(editing != nil)
                    if let msg = aliasValidationMessage {
                        Label(msg, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    TextField("主机名", text: $hostname)
                    HStack {
                        TextField("端口", text: $port)
                            .frame(maxWidth: 100)
                        TextField("用户", text: $user)
                    }
                }
                Section("认证") {
                    HStack {
                        Picker("私钥", selection: $identityFile) {
                            Text("无（用 ssh-agent / 默认 key）").tag("")
                            ForEach(availableKeys) { key in
                                Text(keyDisplayName(key)).tag(displayPath(key.path))
                            }
                            if !identityFile.isEmpty,
                               !availableKeys.contains(where: { displayPath($0.path) == identityFile }) {
                                Text(identityFile + " （自定义）").tag(identityFile)
                            }
                        }
                        Button("浏览…") { browseForKey() }
                            .buttonStyle(.bordered)
                    }
                    if !identityFile.isEmpty {
                        Text(identityFile)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    TextField("ProxyJump", text: $proxyJump, prompt: Text("如：bastion 或 user@host:port"))
                    passwordField
                }
                Section("组织") {
                    Picker("分组", selection: $groupID) {
                        Text("未分组").tag(UUID?.none)
                        ForEach(store.groups) { group in
                            Text(group.name).tag(UUID?.some(group.id))
                        }
                    }
                    TextField("标签（逗号分隔）", text: $tagsText)
                }
                if editing?.source == .imported {
                    Section {
                        Label(
                            "这是从 ~/.ssh/config 导入的条目。保存时会复制为 App 管理副本写入 config.d/sshkeeper.conf；OpenSSH 的 first-match 规则下 App 副本会先生效。",
                            systemImage: "info.circle"
                        )
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    }
                }
                if let error = saveError {
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
                Button(editing == nil ? "新建" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 420)
        .navigationTitle(editing == nil ? "新建主机" : "编辑 \(editing!.alias)")
        .onAppear {
            availableKeys = KeyScanner.scan().keys
        }
    }

    @ViewBuilder
    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(
                    hasStoredPassword && !passwordDirty
                        ? "密码（已存 Keychain，留空保持不变）"
                        : "密码（可选；存到 Keychain）",
                    text: $passwordInput
                )
                .onChange(of: passwordInput) { _, _ in passwordDirty = true }
                if hasStoredPassword {
                    Button("清除") {
                        passwordInput = ""
                        passwordDirty = true
                        hasStoredPassword = false
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("用 ssh-agent + 密钥更安全；密码登录时密码存 macOS Keychain，连接时通过 SSH_ASKPASS 注入。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var isValid: Bool {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        return !trimmedAlias.isEmpty &&
            Self.aliasIsValid(trimmedAlias) &&
            !hostname.trimmingCharacters(in: .whitespaces).isEmpty &&
            Int(port) != nil
    }

    private var aliasValidationMessage: String? {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        guard !trimmedAlias.isEmpty else { return nil }
        if Self.aliasIsValid(trimmedAlias) { return nil }
        return "别名只能用 ASCII 字母 / 数字 / _ - .  （OpenSSH 不接受中文/空格/特殊字符）"
    }

    /// OpenSSH 主机名规则（valid_domain）：ASCII 字母数字 + . _ -，至少 1 个字符。
    private static func aliasIsValid(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 255 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func keyDisplayName(_ key: KeyRef) -> String {
        let name = URL(fileURLWithPath: key.path).lastPathComponent
        var parts: [String] = [name]
        parts.append(key.type.displayName)
        if let comment = key.comment, !comment.isEmpty { parts.append(comment) }
        return parts.joined(separator: " · ")
    }

    private func displayPath(_ absolutePath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if absolutePath.hasPrefix(home + "/") {
            return "~" + absolutePath.dropFirst(home.count)
        }
        return absolutePath
    }

    private func browseForKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        panel.title = "选择私钥文件"
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            identityFile = displayPath(url.path)
        }
    }

    private func save() {
        guard let portInt = Int(port) else { return }
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        let parsedTags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let id = editing?.id ?? UUID()
        let host = SSHHost(
            id: id,
            alias: trimmedAlias,
            hostname: trimmedHost,
            port: portInt,
            user: user.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            identityFile: identityFile.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            proxyJump: proxyJump.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            extraOptions: editing?.extraOptions ?? [:],
            groupID: groupID,
            tags: parsedTags,
            colorHex: editing?.colorHex,
            lastUsedAt: editing?.lastUsedAt,
            source: .appManaged
        )
        do {
            try store.upsert(host)
            try persistPasswordIfNeeded(alias: trimmedAlias, account: host.user)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func persistPasswordIfNeeded(alias: String, account: String?) throws {
        guard passwordDirty else { return }
        if passwordInput.isEmpty {
            try PasswordKeychain.delete(alias: alias)
        } else {
            try PasswordKeychain.write(
                alias: alias,
                account: account,
                password: passwordInput
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
