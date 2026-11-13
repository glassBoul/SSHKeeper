import Foundation
import Observation
import SSHKeeperCore

enum DBConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

enum TableInspectorTab: String, CaseIterable, Identifiable {
    case structure, content, relations, triggers, info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .structure: "结构"
        case .content: "内容"
        case .relations: "关系"
        case .triggers: "触发器"
        case .info: "表信息"
        }
    }

    var systemImage: String {
        switch self {
        case .structure: "list.bullet.indent"
        case .content: "tablecells"
        case .relations: "arrow.triangle.branch"
        case .triggers: "bolt"
        case .info: "info.circle"
        }
    }
}

struct SQLTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var queryText: String
    var lastResult: QueryResult?
    var lastError: String?
    var isRunning: Bool

    init(
        id: UUID = UUID(),
        title: String,
        queryText: String = "SELECT 1;",
        lastResult: QueryResult? = nil,
        lastError: String? = nil,
        isRunning: Bool = false
    ) {
        self.id = id
        self.title = title
        self.queryText = queryText
        self.lastResult = lastResult
        self.lastError = lastError
        self.isRunning = isRunning
    }

    /// 取 SQL 文本里第一段非空、非注释的 80 字符做 tab 标题。
    static func deriveTitle(from query: String, fallback: String) -> String {
        for line in query.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("--") || trimmed.hasPrefix("#") { continue }
            if trimmed.count > 32 { return String(trimmed.prefix(32)) + "…" }
            return trimmed
        }
        return fallback
    }
}

@Observable
@MainActor
final class DatabaseSession {
    var status: DBConnectionStatus = .disconnected
    var availableDatabases: [String] = []
    var currentDatabase: String
    var tables: [DatabaseObject] = []
    var tableSearchText: String = ""

    // 多 SQL 标签
    var sqlTabs: [SQLTab] = []
    var activeSQLTabID: UUID?
    var activeSelectedSQL: String = ""

    // Inspector 状态独立成子对象，避免 inspector 变化触发整个 session 的订阅者刷新
    let inspector = TableInspectorState()

    // 自动补全：表名 → 列名缓存（仅用于 SQL 编辑器的补全）
    var columnCache: [String: [String]] = [:]

    let database: Database
    private let password: String
    private var client: DatabaseClient?
    private var sqlTabCounter: Int = 0
    private var wasCancelledByUser: Bool = false

    /// 全局补全池（关键字 + 内置函数 + 表名 + 已知列名）。@ObservationIgnored 避免
    /// 缓存命中也触发整个 session 的订阅者重渲染。invalidate 时机：表列表变更、columnCache
    /// 写入、连接重建。预渲染：避免每次按键都重建 ~2000 个字符串的数组。
    @ObservationIgnored
    private var cachedGlobalCompletionPool: [String]?

    init(database: Database, password: String) {
        self.database = database
        self.password = password
        self.currentDatabase = database.defaultDatabase
        let initial = makeNewTab()
        self.sqlTabs = [initial]
        self.activeSQLTabID = initial.id
    }

    // MARK: - SQL tabs

    var activeSQLTab: SQLTab? {
        guard let id = activeSQLTabID else { return nil }
        return sqlTabs.first(where: { $0.id == id })
    }

    func newSQLTab() {
        let tab = makeNewTab()
        sqlTabs.append(tab)
        activeSQLTabID = tab.id
    }

    func closeSQLTab(_ id: UUID) {
        guard sqlTabs.count > 1 else { return }
        let oldIndex = sqlTabs.firstIndex(where: { $0.id == id })
        sqlTabs.removeAll { $0.id == id }
        if activeSQLTabID == id, let oldIndex {
            let next = max(0, min(oldIndex, sqlTabs.count - 1))
            activeSQLTabID = sqlTabs[next].id
        }
    }

    func setActiveSQLTab(_ id: UUID) {
        guard sqlTabs.contains(where: { $0.id == id }) else { return }
        activeSQLTabID = id
    }

    var activeQueryText: String {
        get { activeSQLTab?.queryText ?? "" }
        set {
            guard let id = activeSQLTabID,
                  let idx = sqlTabs.firstIndex(where: { $0.id == id }) else { return }
            let oldText = sqlTabs[idx].queryText
            sqlTabs[idx].queryText = newValue
            // 大多数键入发生在文本中段 — 头 64 字符没变就不可能影响 deriveTitle
            // (它只看第一段非空非注释行的前 32 字符)。避免每按一键都触发 SQLTab 重渲染。
            if oldText.prefix(64) == newValue.prefix(64) { return }
            let newTitle = SQLTab.deriveTitle(
                from: newValue,
                fallback: sqlTabs[idx].title.hasPrefix("SQL #") ? sqlTabs[idx].title : "SQL"
            )
            if sqlTabs[idx].title != newTitle {
                sqlTabs[idx].title = newTitle
            }
        }
    }

    func runActiveQuery() async {
        await runActiveQuery(transform: { $0 })
    }

    /// 在当前 SQL 前加 `EXPLAIN ` 跑一次。两端都仅取计划、不执行原查询；
    /// 如果想看真实执行耗时，用户可自己手敲 `EXPLAIN ANALYZE ...`。
    func runExplain() async {
        await runActiveQuery(transform: { sql in
            let lowered = sql.lowercased()
            // 已经是 EXPLAIN 开头就不再叠加（避免 EXPLAIN EXPLAIN）
            if lowered.hasPrefix("explain ") || lowered.hasPrefix("explain\n") {
                return sql
            }
            return "EXPLAIN \(sql)"
        })
    }

    private func runActiveQuery(transform: (String) -> String) async {
        guard let id = activeSQLTabID,
              let idx = sqlTabs.firstIndex(where: { $0.id == id }),
              let client else { return }
        let trimmedSelection = activeSelectedSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSQL: String
        if !trimmedSelection.isEmpty {
            baseSQL = trimmedSelection
        } else {
            baseSQL = sqlTabs[idx].queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !baseSQL.isEmpty else { return }
        let sql = transform(baseSQL)
        sqlTabs[idx].isRunning = true
        wasCancelledByUser = false
        defer {
            if let i = sqlTabs.firstIndex(where: { $0.id == id }) {
                sqlTabs[i].isRunning = false
            }
        }
        do {
            let result = try await client.runQuery(sql)
            if let i = sqlTabs.firstIndex(where: { $0.id == id }) {
                sqlTabs[i].lastResult = result
                sqlTabs[i].lastError = nil
            }
        } catch {
            if let i = sqlTabs.firstIndex(where: { $0.id == id }) {
                sqlTabs[i].lastResult = nil
                sqlTabs[i].lastError = wasCancelledByUser
                    ? "已取消（连接已重置）"
                    : error.localizedDescription
            }
            wasCancelledByUser = false
        }
    }

    /// 取消正在跑的查询：直接关掉当前连接（SQL 或 inspector 都共用同一连接，
    /// 关掉 → 双方 await 都抛出），然后立即重连。
    func cancelActiveQuery() async {
        guard let client else { return }
        wasCancelledByUser = true
        inspector.wasCancelledByUser = true
        await client.close()
        let newClient = DatabaseClientFactory.make(database: database, password: password)
        do {
            try await newClient.connect()
            if currentDatabase != database.defaultDatabase {
                try? await newClient.switchDatabase(currentDatabase)
            }
            self.client = newClient
            self.inspector.client = newClient
        } catch {
            self.client = nil
            self.inspector.client = nil
            self.status = .error(error.localizedDescription)
        }
    }

    private func makeNewTab() -> SQLTab {
        sqlTabCounter += 1
        return SQLTab(title: "SQL #\(sqlTabCounter)")
    }

    // MARK: - Connection

    var filteredTables: [DatabaseObject] {
        let q = tableSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tables }
        return tables.filter { $0.name.lowercased().contains(q) }
    }

    func connect() async {
        status = .connecting
        let client = DatabaseClientFactory.make(database: database, password: password)
        do {
            try await client.connect()
            self.client = client
            self.inspector.client = client
            self.status = .connected
            await refreshDatabases()
            await refreshTables()
        } catch {
            self.status = .error(error.localizedDescription)
            self.client = nil
            self.inspector.client = nil
        }
    }

    func disconnect() async {
        if let client {
            await client.close()
        }
        client = nil
        inspector.client = nil
        status = .disconnected
        tables = []
        availableDatabases = []
        inspector.reset()
        columnCache = [:]
        invalidateCompletionPool()
    }

    func switchDatabase(_ name: String) async {
        guard let client else { return }
        do {
            try await client.switchDatabase(name)
            currentDatabase = name
            inspector.reset()
            // 切库后旧库的列名补全用错；清掉重新预热
            columnCache = [:]
            invalidateCompletionPool()
            await refreshTables()
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func refreshDatabases() async {
        guard let client else { return }
        availableDatabases = (try? await client.listDatabases()) ?? []
    }

    func refreshTables() async {
        guard let client else { return }
        tables = (try? await client.listTables(in: currentDatabase)) ?? []
        invalidateCompletionPool()
    }

    func createTable(name: String, columns: [ColumnDefinition], primaryKeys: [String]) async throws {
        guard let client else { return }
        try await client.createTable(
            database: currentDatabase,
            name: name,
            columns: columns,
            primaryKeys: primaryKeys
        )
        await refreshTables()
    }

    func dropTable(_ table: DatabaseObject) async throws {
        guard let client else { return }
        try await client.dropTable(table)
        if inspector.selectedTable?.id == table.id {
            inspector.deselectTable()
        }
        await refreshTables()
    }

    /// 清空表数据 + 重置自增 ID（TRUNCATE）。表结构保留，所以无需 refreshTables，
    /// 只要让 inspector 重抓内容。
    func truncateTable(_ table: DatabaseObject) async throws {
        guard let client else { return }
        try await client.truncateTable(table)
        if inspector.selectedTable?.id == table.id {
            await inspector.reloadAfterBulkContentChange()
        }
    }

    /// 删除全部数据但保留自增 ID（DELETE FROM）。同上，不动表结构。
    func deleteAllRows(_ table: DatabaseObject) async throws {
        guard let client else { return }
        try await client.deleteAllRows(table)
        if inspector.selectedTable?.id == table.id {
            await inspector.reloadAfterBulkContentChange()
        }
    }

    func renameTable(_ table: DatabaseObject, to newName: String) async throws {
        guard let client else { return }
        try await client.renameTable(table, to: newName)
        // 当前选中的就是这个表 → 取消选中（id 已变）
        if inspector.selectedTable?.id == table.id {
            inspector.deselectTable()
        }
        await refreshTables()
    }

    func duplicateTable(_ table: DatabaseObject, newName: String, includeData: Bool) async throws {
        guard let client else { return }
        try await client.duplicateTable(table, newName: newName, includeData: includeData)
        await refreshTables()
    }

    // MARK: - Autocomplete

    /// SQL 编辑器的补全 provider（同步返回，需要的列异步预热）。
    func completions(prefix: String, contextBefore: String) -> [String] {
        let trimmedPrefix = prefix
        if let tableName = Self.tableNameBeforeDot(in: contextBefore) {
            preloadColumns(for: tableName)
            let cols = columnCache[tableName.lowercased()] ?? []
            if cols.isEmpty { return [] }
            return Self.matches(cols, prefix: trimmedPrefix)
        }
        return Self.matches(globalCompletionPool(), prefix: trimmedPrefix)
    }

    private func globalCompletionPool() -> [String] {
        if let cached = cachedGlobalCompletionPool { return cached }
        let columnCount = columnCache.values.reduce(0) { $0 + $1.count }
        var pool: [String] = []
        pool.reserveCapacity(SQLHighlighter.keywords.count + SQLHighlighter.builtins.count + tables.count + columnCount)
        pool.append(contentsOf: SQLHighlighter.keywords)
        pool.append(contentsOf: SQLHighlighter.builtins)
        pool.append(contentsOf: tables.map { $0.name })
        for cols in columnCache.values {
            pool.append(contentsOf: cols)
        }
        cachedGlobalCompletionPool = pool
        return pool
    }

    private func invalidateCompletionPool() {
        cachedGlobalCompletionPool = nil
    }

    private func preloadColumns(for tableName: String) {
        let key = tableName.lowercased()
        guard columnCache[key] == nil else { return }
        guard let table = tables.first(where: { $0.name.lowercased() == key }) else { return }
        guard let client else { return }
        Task { [client, tableName] in
            if let result = try? await client.tableStructure(table) {
                let names = result.rows.compactMap { $0.first ?? nil }
                await MainActor.run {
                    self.columnCache[tableName.lowercased()] = names
                    self.invalidateCompletionPool()
                }
            }
        }
    }

    private static func tableNameBeforeDot(in context: String) -> String? {
        let nsStr = context as NSString
        let n = nsStr.length
        guard n > 0, nsStr.character(at: n - 1) == 0x2E else { return nil }
        var i = n - 2
        while i >= 0 {
            let c = nsStr.character(at: i)
            let isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            let isDigit = c >= 0x30 && c <= 0x39
            let isUnderscore = c == 0x5F
            if isLetter || isDigit || isUnderscore { i -= 1 } else { break }
        }
        let start = i + 1
        let end = n - 1
        if start >= end { return nil }
        return nsStr.substring(with: NSRange(location: start, length: end - start))
    }

    private static func matches(_ candidates: [String], prefix: String) -> [String] {
        let p = prefix.lowercased()
        var seen: Set<String> = []
        var matched: [String] = []
        for s in candidates {
            let key = s.lowercased()
            if seen.contains(key) { continue }
            if p.isEmpty || key.hasPrefix(p) {
                seen.insert(key)
                matched.append(s)
            }
        }
        matched.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return Array(matched.prefix(50))
    }
}
