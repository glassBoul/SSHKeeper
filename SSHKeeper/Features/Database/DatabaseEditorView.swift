import SwiftUI
import SSHKeeperCore

struct DatabaseEditorView: View {
    @Environment(DatabaseStore.self) private var store
    @Environment(HostStore.self) private var hostStore
    @Environment(\.dismiss) private var dismiss

    let editing: Database?

    @State private var name: String
    @State private var kind: DatabaseKind
    @State private var host: String
    @State private var port: String
    @State private var defaultDatabase: String
    @State private var username: String
    @State private var tlsMode: DatabaseTLSMode
    @State private var allowSelfSigned: Bool
    @State private var tagsText: String
    @State private var passwordInput: String = ""
    @State private var passwordDirty: Bool = false
    @State private var hasStoredPassword: Bool
    @State private var saveError: String?
    @State private var sshTunnelEnabled: Bool
    @State private var sshHostAlias: String
    @State private var testing: Bool = false
    @State private var testResult: TestResult?

    private enum TestResult {
        case success(elapsedMs: Int)
        case failure(String)
    }

    init(editing: Database? = nil) {
        self.editing = editing
        let kind = editing?.kind ?? .postgres
        _name = State(initialValue: editing?.name ?? "")
        _kind = State(initialValue: kind)
        _host = State(initialValue: editing?.host ?? "")
        _port = State(initialValue: String(editing?.port ?? kind.defaultPort))
        _defaultDatabase = State(initialValue: editing?.defaultDatabase ?? "")
        _username = State(initialValue: editing?.username ?? "")
        _tlsMode = State(initialValue: editing?.tlsMode ?? .disable)
        _allowSelfSigned = State(initialValue: editing?.allowSelfSignedTLS ?? true)
        _tagsText = State(initialValue: editing?.tags.joined(separator: ", ") ?? "")
        _hasStoredPassword = State(
            initialValue: editing.map {
                PasswordKeychain.has(alias: "db:\($0.id.uuidString)")
            } ?? false
        )
        let alias = editing?.sshHostAlias ?? ""
        _sshTunnelEnabled = State(initialValue: !alias.isEmpty)
        _sshHostAlias = State(initialValue: alias)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("基本") {
                    TextField("名称", text: $name, prompt: Text("如：生产 PG 主库"))
                    Picker("类型", selection: $kind) {
                        ForEach(DatabaseKind.allCases, id: \.self) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .onChange(of: kind) { _, new in
                        if Int(port) == DatabaseKind.mysql.defaultPort
                            || Int(port) == DatabaseKind.postgres.defaultPort
                            || port.isEmpty {
                            port = String(new.defaultPort)
                        }
                    }
                }
                Section("连接") {
                    TextField("主机", text: $host, prompt: Text("ip 或 hostname"))
                    TextField("端口", text: $port).frame(maxWidth: 120)
                    TextField("默认数据库", text: $defaultDatabase)
                    TextField("用户名", text: $username)
                    SecureField(
                        hasStoredPassword && !passwordDirty
                            ? "密码（已存 Keychain，留空保持不变）"
                            : "密码",
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
                Section("TLS") {
                    Picker("TLS", selection: $tlsMode) {
                        ForEach(DatabaseTLSMode.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    Toggle("允许自签证书", isOn: $allowSelfSigned)
                        .disabled(tlsMode == .disable)
                }
                Section {
                    Toggle("通过 SSH 隧道连接", isOn: $sshTunnelEnabled)
                        .onChange(of: sshTunnelEnabled) { _, on in
                            if on, sshHostAlias.isEmpty,
                               let first = sortedHostAliases.first {
                                sshHostAlias = first
                            }
                        }
                    if sshTunnelEnabled {
                        if sortedHostAliases.isEmpty {
                            Label(
                                "未找到可用的 SSH 主机。先在主机列表里添加一台跳板机。",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        } else {
                            Picker("跳板主机", selection: $sshHostAlias) {
                                ForEach(sortedHostAliases, id: \.self) { alias in
                                    Text(alias).tag(alias)
                                }
                                // 当前值不在列表里（外部修改 / 主机已删）也展示出来不让 picker 空白
                                if !sshHostAlias.isEmpty,
                                   !sortedHostAliases.contains(sshHostAlias) {
                                    Text("\(sshHostAlias) (未找到)").tag(sshHostAlias)
                                }
                            }
                        }
                        Text("连接时会跑：ssh -N -L <本地端口>:\(host.isEmpty ? "<目标主机>" : host):\(port.isEmpty ? "<目标端口>" : port) \(sshHostAlias.isEmpty ? "<跳板>" : sshHostAlias)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("SSH 隧道")
                } footer: {
                    Text("生产 MySQL/PG 通常不开公网，需要先 SSH 到跳板机再转发。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Section("组织") {
                    TextField("标签（逗号分隔）", text: $tagsText)
                }
                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                if let testResult {
                    Section("测试结果") {
                        testResultView(testResult)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button {
                    Task { await runTest() }
                } label: {
                    if testing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在测试…")
                        }
                    } else {
                        Label("测试连接", systemImage: "bolt.horizontal")
                    }
                }
                .disabled(!isValid || testing)
                .help("用当前表单跑一遍连接握手，不保存。")

                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "新建" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || testing)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 540)
        .navigationTitle(editing == nil ? "新建数据库" : "编辑 \(editing!.name)")
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !defaultDatabase.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        Int(port) != nil &&
        (!sshTunnelEnabled || !sshHostAlias.isEmpty)
    }

    private var sortedHostAliases: [String] {
        hostStore.hosts.map(\.alias).sorted()
    }

    private func save() {
        guard let portInt = Int(port) else { return }
        let parsedTags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let id = editing?.id ?? UUID()
        let database = Database(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            kind: kind,
            host: host.trimmingCharacters(in: .whitespaces),
            port: portInt,
            defaultDatabase: defaultDatabase.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            tlsMode: tlsMode,
            allowSelfSignedTLS: allowSelfSigned,
            groupID: editing?.groupID,
            tags: parsedTags,
            colorHex: editing?.colorHex,
            lastUsedAt: editing?.lastUsedAt,
            sshHostAlias: sshTunnelEnabled ? sshHostAlias.trimmingCharacters(in: .whitespaces) : nil
        )
        do {
            try store.upsert(database)
            try persistPassword(for: database)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func testResultView(_ result: TestResult) -> some View {
        switch result {
        case .success(let ms):
            Label("连接成功 · 握手耗时 \(ms) ms", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("连接失败", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
    }

    /// 用当前表单值临时构造一个 Database，跑一次 connect()，然后立刻 close。
    /// 不写入 store，也不动 Keychain。
    private func runTest() async {
        testResult = nil
        testing = true
        defer { testing = false }

        guard let portInt = Int(port), portInt > 0, portInt < 65536 else {
            testResult = .failure("端口格式错误：\(port)")
            return
        }
        let pw: String
        if !passwordInput.isEmpty {
            pw = passwordInput
        } else if let editing, hasStoredPassword,
                  let stored = PasswordKeychain.read(alias: "db:\(editing.id.uuidString)") {
            pw = stored
        } else if hasStoredPassword {
            testResult = .failure("无法从 Keychain 读出已存的密码")
            return
        } else {
            testResult = .failure("请填写密码")
            return
        }

        let probe = Database(
            id: editing?.id ?? UUID(),
            name: name,
            kind: kind,
            host: host.trimmingCharacters(in: .whitespaces),
            port: portInt,
            defaultDatabase: defaultDatabase.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            tlsMode: tlsMode,
            allowSelfSignedTLS: allowSelfSigned,
            sshHostAlias: sshTunnelEnabled
                ? sshHostAlias.trimmingCharacters(in: .whitespaces)
                : nil
        )
        let client = DatabaseClientFactory.make(database: probe, password: pw)
        let start = Date()
        do {
            try await client.connect()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            await client.close()
            testResult = .success(elapsedMs: ms)
        } catch {
            await client.close()
            testResult = .failure(error.localizedDescription)
        }
    }

    private func persistPassword(for db: Database) throws {
        guard passwordDirty else { return }
        let alias = "db:\(db.id.uuidString)"
        if passwordInput.isEmpty {
            try PasswordKeychain.delete(alias: alias)
        } else {
            try PasswordKeychain.write(
                alias: alias,
                account: db.username,
                password: passwordInput
            )
        }
    }
}
