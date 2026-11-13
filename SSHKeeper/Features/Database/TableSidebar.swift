import SwiftUI
import SSHKeeperCore

struct TableSidebar: View {
    @Bindable var session: DatabaseSession

    @State private var showCreateTable = false
    @State private var pendingDanger: DangerOp?
    @State private var renameCandidate: DatabaseObject?
    @State private var renameInput: String = ""
    @State private var duplicateCandidate: DatabaseObject?
    @State private var duplicateInput: String = ""
    @State private var duplicateIncludeData: Bool = true
    @State private var actionError: String?

    /// 三种破坏性表级操作走同一个 confirmationDialog，靠这个枚举区分。
    private enum DangerOp: Identifiable {
        case drop(DatabaseObject)
        case truncate(DatabaseObject)
        case deleteAll(DatabaseObject)

        var id: String {
            switch self {
            case .drop(let t): "drop:\(t.id)"
            case .truncate(let t): "truncate:\(t.id)"
            case .deleteAll(let t): "deleteAll:\(t.id)"
            }
        }
        var table: DatabaseObject {
            switch self {
            case .drop(let t), .truncate(let t), .deleteAll(let t): t
            }
        }
        var title: String {
            switch self {
            case .drop(let t): "删除表「\(t.name)」？"
            case .truncate(let t): "清空表「\(t.name)」？"
            case .deleteAll(let t): "删除「\(t.name)」全部数据？"
            }
        }
        var message: String {
            switch self {
            case .drop:
                "DROP TABLE 不可恢复，所有数据 + 索引 + 触发器一并丢失。"
            case .truncate:
                "TRUNCATE 会清空所有行并重置自增 ID（下次插入从 1 开始）。不可撤销。被外键引用时会抛错，避免连带误删其它表数据。"
            case .deleteAll:
                "DELETE FROM 会清空所有行，但保留自增 ID（下次插入接着上次的值）。不可撤销。"
            }
        }
        var confirmLabel: String {
            switch self {
            case .drop: "删除表"
            case .truncate: "清空"
            case .deleteAll: "只删数据"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchRow
            Divider()
            list
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showCreateTable) {
            CreateTableSheet(
                database: session.currentDatabase,
                onCommit: { name, columns, primaryKeys in
                    do {
                        try await session.createTable(name: name, columns: columns, primaryKeys: primaryKeys)
                    } catch {
                        actionError = error.localizedDescription
                        throw error
                    }
                }
            )
        }
        .confirmationDialog(
            pendingDanger?.title ?? "",
            isPresented: Binding(
                get: { pendingDanger != nil },
                set: { if !$0 { pendingDanger = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDanger
        ) { op in
            Button(op.confirmLabel, role: .destructive) {
                Task { await runDanger(op) }
            }
            Button("取消", role: .cancel) { pendingDanger = nil }
        } message: { op in
            Text(op.message)
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            presenting: actionError
        ) { _ in
            Button("好") { actionError = nil }
        } message: { msg in
            Text(msg)
        }
        .alert(
            "重命名表",
            isPresented: Binding(
                get: { renameCandidate != nil },
                set: { newValue in
                    if !newValue { renameCandidate = nil; renameInput = "" }
                }
            ),
            presenting: renameCandidate
        ) { table in
            TextField("新名称", text: $renameInput)
            Button("取消", role: .cancel) {
                renameCandidate = nil
                renameInput = ""
            }
            Button("重命名") {
                let candidate = table
                let newName = renameInput.trimmingCharacters(in: .whitespaces)
                renameCandidate = nil
                renameInput = ""
                guard !newName.isEmpty, newName != candidate.name else { return }
                Task {
                    do { try await session.renameTable(candidate, to: newName) }
                    catch { actionError = error.localizedDescription }
                }
            }
        } message: { table in
            Text("把「\(table.name)」改名为：")
        }
        .sheet(item: $duplicateCandidate) { table in
            DuplicateTableSheet(
                source: table,
                newName: $duplicateInput,
                includeData: $duplicateIncludeData,
                onCommit: {
                    let newName = duplicateInput.trimmingCharacters(in: .whitespaces)
                    let includeData = duplicateIncludeData
                    let candidate = table
                    duplicateCandidate = nil
                    duplicateInput = ""
                    duplicateIncludeData = true
                    guard !newName.isEmpty else { return }
                    Task {
                        do {
                            try await session.duplicateTable(candidate, newName: newName, includeData: includeData)
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                },
                onCancel: {
                    duplicateCandidate = nil
                    duplicateInput = ""
                    duplicateIncludeData = true
                }
            )
            .onAppear {
                duplicateInput = "\(table.name)_copy"
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("搜索表名", text: $session.tableSearchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !session.tableSearchText.isEmpty {
                Button {
                    session.tableSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                showCreateTable = true
            } label: {
                Image(systemName: "plus").font(.caption)
            }
            .buttonStyle(.plain)
            .help("新建表 (⌘N)")
            .keyboardShortcut("n", modifiers: .command)
            Button {
                Task { await session.refreshTables() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
            .help("刷新")
        }
        .padding(8)
    }

    private var list: some View {
        List(selection: Binding(
            get: { session.inspector.selectedTable?.id },
            set: { newID in
                if let id = newID,
                   let table = session.tables.first(where: { $0.id == id }) {
                    Task { await session.inspector.selectTable(table) }
                }
            }
        )) {
            ForEach(session.filteredTables) { table in
                HStack(spacing: 8) {
                    Image(systemName: table.kind == .view ? "rectangle.stack" : "tablecells")
                        .foregroundStyle(table.kind == .view ? .purple : .secondary)
                        .font(.system(size: 14))
                    Text(table.name)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 2)
                .tag(table.id)
                .contextMenu {
                    Button("打开") {
                        Task { await session.inspector.selectTable(table) }
                    }
                    Divider()
                    Button("重命名…") {
                        renameCandidate = table
                    }
                    Button("复制为新表…") {
                        duplicateCandidate = table
                    }
                    Divider()
                    Button("清空表（重置自增 ID）…", role: .destructive) {
                        pendingDanger = .truncate(table)
                    }
                    Button("只删数据（保留自增 ID）…", role: .destructive) {
                        pendingDanger = .deleteAll(table)
                    }
                    Divider()
                    Button("删除表…", role: .destructive) {
                        pendingDanger = .drop(table)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var footer: some View {
        HStack {
            Text("\(session.filteredTables.count) / \(session.tables.count) 个表")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func runDanger(_ op: DangerOp) async {
        do {
            switch op {
            case .drop(let t): try await session.dropTable(t)
            case .truncate(let t): try await session.truncateTable(t)
            case .deleteAll(let t): try await session.deleteAllRows(t)
            }
            pendingDanger = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct DuplicateTableSheet: View {
    let source: DatabaseObject
    @Binding var newName: String
    @Binding var includeData: Bool
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("源表") {
                    Text(source.name)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("新表") {
                    TextField("新表名", text: $newName)
                        .font(.system(.body, design: .monospaced))
                    Toggle("同时复制数据（INSERT INTO ... SELECT）", isOn: $includeData)
                    if !includeData {
                        Text("仅复制结构、索引、约束；不拷数据。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("复制", action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 280)
        .navigationTitle("复制表")
    }
}
