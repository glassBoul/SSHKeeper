import SwiftUI
import SSHKeeperCore

struct PanelEditorView: View {
    @Environment(PanelStore.self) private var store
    @Environment(HostStore.self) private var hostStore
    @Environment(\.dismiss) private var dismiss

    let editing: Panel?

    @State private var name: String
    @State private var url: String
    @State private var username: String
    @State private var kind: PanelKind
    @State private var groupID: UUID?
    @State private var tagsText: String
    @State private var passwordInput: String = ""
    @State private var passwordDirty: Bool = false
    @State private var hasStoredPassword: Bool
    @State private var saveError: String?

    init(editing: Panel? = nil) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _url = State(initialValue: editing?.url ?? "https://")
        _username = State(initialValue: editing?.username ?? "")
        _kind = State(initialValue: editing?.kind ?? .baota)
        _groupID = State(initialValue: editing?.groupID)
        _tagsText = State(initialValue: editing?.tags.joined(separator: ", ") ?? "")
        _hasStoredPassword = State(
            initialValue: editing.map {
                PasswordKeychain.has(alias: "panel:\($0.id.uuidString)")
            } ?? false
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("基本") {
                    TextField("名称", text: $name, prompt: Text("如：生产 - 宝塔"))
                    Picker("类型", selection: $kind) {
                        ForEach(PanelKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    TextField("URL", text: $url, prompt: Text("https://1.2.3.4:8888/abc123"))
                }
                Section("登录") {
                    TextField("用户名", text: $username)
                    SecureField(
                        hasStoredPassword && !passwordDirty
                            ? "密码（已存 Keychain，留空保持不变）"
                            : "密码（存到 Keychain）",
                        text: $passwordInput
                    )
                    .onChange(of: passwordInput) { _, _ in passwordDirty = true }
                    if hasStoredPassword {
                        Button("清除密码") {
                            passwordInput = ""
                            passwordDirty = true
                            hasStoredPassword = false
                        }
                    }
                }
                Section("组织") {
                    Picker("分组", selection: $groupID) {
                        Text("未分组").tag(UUID?.none)
                        ForEach(hostStore.groups) { group in
                            Text(group.name).tag(UUID?.some(group.id))
                        }
                    }
                    TextField("标签（逗号分隔）", text: $tagsText)
                }
                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle")
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
        .frame(minWidth: 480, minHeight: 460)
        .navigationTitle(editing == nil ? "新建面板" : "编辑 \(editing!.name)")
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !url.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        URL(string: url) != nil
    }

    private func save() {
        let parsedTags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let id = editing?.id ?? UUID()
        let panel = Panel(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            url: url.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            kind: kind,
            groupID: groupID,
            tags: parsedTags,
            colorHex: editing?.colorHex,
            lastUsedAt: editing?.lastUsedAt
        )
        do {
            try store.upsert(panel)
            try persistPassword(for: panel)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func persistPassword(for panel: Panel) throws {
        guard passwordDirty else { return }
        let alias = "panel:\(panel.id.uuidString)"
        if passwordInput.isEmpty {
            try PasswordKeychain.delete(alias: alias)
        } else {
            try PasswordKeychain.write(
                alias: alias,
                account: panel.username,
                password: passwordInput
            )
        }
    }
}
