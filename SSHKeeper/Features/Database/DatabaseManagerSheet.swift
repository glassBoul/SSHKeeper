import SwiftUI
import SSHKeeperCore

struct DatabaseManagerSheet: View {
    @Environment(DatabaseStore.self) private var store
    @Environment(HostStore.self) private var hostStore
    @Environment(DatabaseWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var editorTarget: DatabaseEditorTarget?
    @State private var deleteCandidate: Database?
    @State private var openError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle("数据库")
        .sheet(item: $editorTarget) { target in
            DatabaseEditorView(editing: target.database)
                .environment(store)
                .environment(hostStore)
        }
        .confirmationDialog(
            deleteCandidate.map { "删除「\($0.name)」？" } ?? "",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteCandidate
        ) { db in
            Button("删除", role: .destructive) {
                try? store.remove(id: db.id)
                try? PasswordKeychain.delete(alias: "db:\(db.id.uuidString)")
                deleteCandidate = nil
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        } message: { _ in
            Text("将同时清除存在 Keychain 的密码。")
        }
        .alert(
            "无法打开",
            isPresented: Binding(
                get: { openError != nil },
                set: { if !$0 { openError = nil } }
            ),
            presenting: openError
        ) { _ in
            Button("好") { openError = nil }
        } message: { msg in
            Text(msg).textSelection(.enabled)
        }
    }

    private var header: some View {
        HStack {
            Text("已保存的数据库")
                .font(.headline)
            Spacer()
            Button("刷新", systemImage: "arrow.clockwise") { store.load() }
                .labelStyle(.iconOnly)
            Button("新建数据库") {
                editorTarget = .new
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.databases.isEmpty {
                    ContentUnavailableView(
                        "尚未添加数据库",
                        systemImage: "cylinder.split.1x2",
                        description: Text("点击「新建数据库」添加 MySQL / PostgreSQL 连接。")
                    )
                    .padding(.vertical, 32)
                }
                ForEach(store.databases.sorted(by: { $0.name < $1.name })) { db in
                    row(db)
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func row(_ db: Database) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: db.kind == .postgres ? "leaf.circle.fill" : "dolphin.fill")
                .font(.title2)
                .foregroundStyle(db.kind == .postgres ? .blue : .orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(db.name).font(.body.weight(.medium))
                    Text(db.kind.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if !PasswordKeychain.has(alias: "db:\(db.id.uuidString)") {
                        Label("缺密码", systemImage: "lock.slash")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(db.username)@\(db.host):\(db.port) / \(db.defaultDatabase)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date = db.lastUsedAt {
                    Text("最近使用：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                try? store.touch(id: db.id)
                // 先把 DB 加到 workspace（拉起连接），再让 WindowGroup 把工作台窗口拉前。
                // openWindow 对 singleton WindowGroup 是「已开 → 拉前；未开 → 新建」语义。
                Task {
                    do {
                        try await workspace.open(databaseID: db.id, in: store)
                        openWindow(id: "db-workspace")
                    } catch {
                        openError = error.localizedDescription
                    }
                }
            } label: {
                Label("打开", systemImage: "rectangle.and.text.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!PasswordKeychain.has(alias: "db:\(db.id.uuidString)"))
            Menu {
                Button("编辑") { editorTarget = .edit(db) }
                Divider()
                Button("删除", role: .destructive) { deleteCandidate = db }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 36)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Text("\(store.databases.count) 个数据库")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }
}

struct DatabaseEditorTarget: Identifiable {
    let id: String
    let database: Database?

    static let new = DatabaseEditorTarget(id: "__new__", database: nil)

    static func edit(_ db: Database) -> DatabaseEditorTarget {
        DatabaseEditorTarget(id: db.id.uuidString, database: db)
    }
}
