import Foundation
import Observation
import SSHKeeperCore

/// Inspector 的所有可观察状态独立成一个 @Observable 对象，避免它的变化触发整个
/// DatabaseSession 的订阅者（比如 SQL 编辑器面板）一起 re-render。
@Observable
@MainActor
final class TableInspectorState {
    var selectedTable: DatabaseObject?
    var inspectorTab: TableInspectorTab = .content
    var inspectorResults: [String: QueryResult] = [:]
    var inspectorErrors: [String: String] = [:]
    var loadingInspector: Bool = false

    /// 「表信息」用的富格式数据（按 tableID 缓存）
    var infoDetailCache: [String: TableInfoDetail] = [:]

    /// 「结构」标签的字段定义（按 tableID 缓存）
    var columnDefinitionsCache: [String: [ColumnDefinition]] = [:]

    /// 「结构」标签的索引（按 tableID 缓存）
    var indexDefinitionsCache: [String: [IndexDefinition]] = [:]

    // 内容标签分页
    var contentPageSize: Int = 200
    var contentPage: [String: Int] = [:]
    var contentRowCount: [String: Int?] = [:]
    /// 行数 COUNT(*) 在 5s 内未返回的表 ID。区分「真返回了 nil」和「超时无结果」
    /// 让 UI 显示 "(行数估算超时)" 而不是隐式回退到「第 N 页」。
    var contentRowCountTimedOut: Set<String> = []
    /// 内容标签的 WHERE 表达式（按 tableID 缓存）— 由 filterRows 编译而来
    var contentFilters: [String: String] = [:]
    /// 结构化筛选行（按 tableID 缓存）
    var contentFilterRows: [String: [FilterRow]] = [:]

    /// 由 DatabaseSession 在 connect / cancel / reconnect 时同步维护
    var client: DatabaseClient?
    var wasCancelledByUser: Bool = false

    /// 当前正在 inline 编辑的草稿行（来自「复制行」或「+新增行」）。
    /// `values[col]`：
    ///   - 不存在 → 提交时跳过该列（DB 走 DEFAULT / auto_increment）
    ///   - `.some(nil)` → SQL 写 NULL
    ///   - `.some(.some(s))` → SQL 写 s
    /// 提交后清空；切表也清空。
    var draftRow: DraftRow?

    struct DraftRow: Equatable {
        /// 对应的表 id — 切表后还能识别旧 draft 不属于当前表。
        var tableID: String
        var values: [String: String?]
        /// 草稿在结果集中的渲染位置：
        ///   - nil → 表尾追加（「+新增行」入口）
        ///   - i  → 第 i 行之后（「复制此行」入口）
        var insertAfterRowIndex: Int?
    }

    /// 浏览过的表 ID 按访问时间排序（front = 最久未访问）。配合 maxCachedTables 做 LRU。
    /// 若不限制，用户在含上千张表的库里点完一遍，所有缓存（行数、列定义、内容、表信息）
    /// 都堆在内存里不释放。
    private var tableAccessOrder: [String] = []
    private static let maxCachedTables = 50

    func reset() {
        selectedTable = nil
        inspectorResults = [:]
        inspectorErrors = [:]
        contentPage = [:]
        contentRowCount = [:]
        contentRowCountTimedOut = []
        contentFilters = [:]
        contentFilterRows = [:]
        infoDetailCache = [:]
        columnDefinitionsCache = [:]
        indexDefinitionsCache = [:]
        tableAccessOrder = []
    }

    // MARK: - Table selection

    func selectTable(_ table: DatabaseObject) async {
        // 切表 / 重选表都清掉草稿（旧 draft 列对不上新表）
        if draftRow?.tableID != table.id { draftRow = nil }
        selectedTable = table
        touchTableCache(table.id)
        await loadInspector(tab: inspectorTab)
    }

    /// 把这个 tableID 标为最近访问；超过容量时驱逐最久未访问的 tableID 的所有缓存。
    private func touchTableCache(_ tableID: String) {
        tableAccessOrder.removeAll { $0 == tableID }
        tableAccessOrder.append(tableID)
        while tableAccessOrder.count > Self.maxCachedTables {
            let lru = tableAccessOrder.removeFirst()
            evictAllCaches(forTableID: lru)
        }
    }

    private func evictAllCaches(forTableID tableID: String) {
        infoDetailCache.removeValue(forKey: tableID)
        columnDefinitionsCache.removeValue(forKey: tableID)
        indexDefinitionsCache.removeValue(forKey: tableID)
        contentRowCount.removeValue(forKey: tableID)
        contentRowCountTimedOut.remove(tableID)
        contentPage.removeValue(forKey: tableID)
        contentFilters.removeValue(forKey: tableID)
        contentFilterRows.removeValue(forKey: tableID)
        let prefix = "\(tableID):"
        for key in inspectorResults.keys where key.hasPrefix(prefix) {
            inspectorResults.removeValue(forKey: key)
        }
        for key in inspectorErrors.keys where key.hasPrefix(prefix) {
            inspectorErrors.removeValue(forKey: key)
        }
    }

    func deselectTable() {
        selectedTable = nil
    }

    func switchInspectorTab(_ tab: TableInspectorTab) async {
        inspectorTab = tab
        await loadInspector(tab: tab)
    }

    func reloadCurrentInspector() async {
        let tab = inspectorTab
        if let table = selectedTable {
            if tab == .info {
                infoDetailCache.removeValue(forKey: table.id)
                inspectorErrors.removeValue(forKey: "\(table.id):info")
            } else {
                let key = inspectorKey(table: table, tab: tab)
                inspectorResults.removeValue(forKey: key)
                inspectorErrors.removeValue(forKey: key)
                if tab == .content {
                    contentRowCount.removeValue(forKey: table.id)
                    contentRowCountTimedOut.remove(table.id)
                }
            }
        }
        await loadInspector(tab: tab)
    }

    func loadInspector(tab: TableInspectorTab) async {
        guard let client, let table = selectedTable else { return }

        // 「表信息」走单独路径，加载 TableInfoDetail，不进 inspectorResults 缓存
        if tab == .info {
            if infoDetailCache[table.id] != nil { return }
            loadingInspector = true
            defer { loadingInspector = false }
            do {
                let detail = try await client.tableInfoDetailed(table)
                infoDetailCache[table.id] = detail
                inspectorErrors["\(table.id):info"] = nil
            } catch {
                inspectorErrors["\(table.id):info"] = wasCancelledByUser
                    ? "已取消（连接已重置）"
                    : error.localizedDescription
                wasCancelledByUser = false
            }
            return
        }

        let key = inspectorKey(table: table, tab: tab)
        if inspectorResults[key] != nil { return }
        loadingInspector = true
        defer { loadingInspector = false }
        do {
            let result: QueryResult
            switch tab {
            case .structure:
                result = try await client.tableStructure(table)
            case .content:
                let page = contentPage[table.id] ?? 0
                let filter = contentFilters[table.id] ?? ""
                result = try await client.tableContents(
                    table,
                    limit: contentPageSize,
                    offset: page * contentPageSize,
                    whereClause: filter
                )
                if contentRowCount[table.id] == nil {
                    Task { [client, tableID = table.id, filter, table] in
                        let outcome = await Self.countWithTimeout(client: client, table: table, filter: filter)
                        await MainActor.run {
                            switch outcome {
                            case .ok(let total):
                                self.contentRowCount[tableID] = total
                                self.contentRowCountTimedOut.remove(tableID)
                            case .timeout:
                                // 标记为已尝试（.some(nil)）避免每次切回这张表都重发 COUNT(*)
                                self.contentRowCount[tableID] = .some(nil)
                                self.contentRowCountTimedOut.insert(tableID)
                            }
                        }
                    }
                }
            case .relations:
                result = try await client.tableForeignKeys(table)
            case .triggers:
                result = try await client.tableTriggers(table)
            case .info:
                // 已在前面处理
                return
            }
            inspectorResults[key] = result
            inspectorErrors[key] = nil
        } catch {
            inspectorErrors[key] = wasCancelledByUser
                ? "已取消（连接已重置）"
                : error.localizedDescription
            inspectorResults[key] = nil
            wasCancelledByUser = false
        }
    }

    /// 获取当前选中表的「表信息」
    func currentTableInfoDetail() -> TableInfoDetail? {
        guard let table = selectedTable else { return nil }
        return infoDetailCache[table.id]
    }

    /// 提交表元信息修改 → ALTER TABLE → 重新拉取 TableInfoDetail
    func saveTableMetadata(_ changes: TableMetadataChanges) async throws {
        guard let client, let table = selectedTable else { return }
        try await client.updateTableMetadata(table, changes: changes)
        // 失效缓存让 reload 重抓
        infoDetailCache.removeValue(forKey: table.id)
    }

    func reloadInfoDetail() async {
        guard let table = selectedTable else { return }
        infoDetailCache.removeValue(forKey: table.id)
        inspectorErrors.removeValue(forKey: "\(table.id):info")
        await loadInspector(tab: .info)
    }

    // MARK: - 结构编辑

    /// 当前表的字段定义。如果未缓存，自动异步抓一次（结果通过 @Observable 更新到 UI）
    func currentColumnDefinitions() -> [ColumnDefinition]? {
        guard let table = selectedTable else { return nil }
        if let cached = columnDefinitionsCache[table.id] { return cached }
        Task { await loadColumnDefinitions() }
        return nil
    }

    func loadColumnDefinitions() async {
        guard let client, let table = selectedTable else { return }
        do {
            let cols = try await client.tableColumnDefinitions(table)
            columnDefinitionsCache[table.id] = cols
        } catch {
            inspectorErrors["\(table.id):structure"] = error.localizedDescription
        }
    }

    func addColumn(_ column: ColumnDefinition, after: String?) async throws {
        guard let client, let table = selectedTable else { return }
        try await client.addColumn(table, column: column, after: after)
        invalidateStructureCaches()
        await loadColumnDefinitions()
        // 「结构」/「内容」/「表信息」/「自动补全」缓存全失效
        await reloadCurrentInspector()
    }

    func dropColumn(_ name: String) async throws {
        guard let client, let table = selectedTable else { return }
        try await client.dropColumn(table, columnName: name)
        invalidateStructureCaches()
        await loadColumnDefinitions()
        await reloadCurrentInspector()
    }

    func modifyColumn(oldName: String, column: ColumnDefinition) async throws {
        guard let client, let table = selectedTable else { return }
        try await client.modifyColumn(table, oldName: oldName, column: column)
        invalidateStructureCaches()
        await loadColumnDefinitions()
        await reloadCurrentInspector()
    }

    private func invalidateStructureCaches() {
        guard let table = selectedTable else { return }
        // 结构 tab 的 QueryResult 显示也得失效
        for key in inspectorResults.keys where key.hasPrefix("\(table.id):") {
            inspectorResults.removeValue(forKey: key)
        }
        inspectorErrors.removeAll()
        infoDetailCache.removeValue(forKey: table.id)
        indexDefinitionsCache.removeValue(forKey: table.id)
        contentRowCount.removeValue(forKey: table.id)
        contentRowCountTimedOut.remove(table.id)
    }

    // MARK: - 索引

    func currentIndexDefinitions() -> [IndexDefinition]? {
        guard let table = selectedTable else { return nil }
        if let cached = indexDefinitionsCache[table.id] { return cached }
        Task { await loadIndexDefinitions() }
        return nil
    }

    func loadIndexDefinitions() async {
        guard let client, let table = selectedTable else { return }
        do {
            let idxs = try await client.tableIndexDefinitions(table)
            indexDefinitionsCache[table.id] = idxs
        } catch {
            inspectorErrors["\(table.id):indexes"] = error.localizedDescription
        }
    }

    func addIndex(_ index: IndexDefinition) async throws {
        guard let client, let table = selectedTable else { return }
        try await client.addIndex(table, index: index)
        indexDefinitionsCache.removeValue(forKey: table.id)
        await loadIndexDefinitions()
        // 索引变化也影响表信息（CREATE TABLE 显示）
        infoDetailCache.removeValue(forKey: table.id)
    }

    // MARK: - 行内修改

    /// 更新某行的某个字段。
    /// 提交成功后**就地 patch** 当前 inspector 结果，不重 query 整表 —— 这样：
    /// - 表格 ScrollView 滚动位置不丢（行号不变，LazyVStack 复用视图）
    /// - 不触发底部分页 / COUNT 等周边 query
    /// 副作用：trigger / generated 列 / 其他副作用看不到；用户手动 reload 按钮可强制刷新。
    func updateRow(primaryKey: [String: String], column: String, value: String?) async throws {
        guard let client, let table = selectedTable else { return }
        try await client.updateRow(table, primaryKey: primaryKey, column: column, value: value)
        // 注意：不 invalidateContentCaches —— invalidate 会把 inspectorResults[key] 置 nil，
        // 紧接着的 patch 就 no-op，UI 显示"加载中"。乐观 patch 后缓存即最新。
        patchInspectorRow(table: table, primaryKey: primaryKey, column: column, value: value)
    }

    /// 在 inspectorResults[content] 内按 pk 定位行后替换指定 col 的值。
    /// 找不到目标行 / 列时静默 no-op —— 调用方已 invalidate 缓存，下次刷新会重抓。
    private func patchInspectorRow(table: DatabaseObject, primaryKey: [String: String], column: String, value: String?) {
        let key = inspectorKey(table: table, tab: .content)
        guard let result = inspectorResults[key] else { return }
        guard let colIdx = result.columns.firstIndex(of: column) else { return }
        // pk 列号 → 期望值
        let pkLookups: [(Int, String)] = primaryKey.compactMap { pkPair in
            result.columns.firstIndex(of: pkPair.key).map { ($0, pkPair.value) }
        }
        guard pkLookups.count == primaryKey.count else { return }
        // 按 pk 匹配第一行
        guard let targetRowIdx = result.rows.firstIndex(where: { row in
            pkLookups.allSatisfy { idx, expected in
                idx < row.count && row[idx] == expected
            }
        }) else { return }
        // 构造新 row + 新 result（QueryResult 字段全是 let）
        var newRows = result.rows
        var targetRow = newRows[targetRowIdx]
        if colIdx < targetRow.count {
            targetRow[colIdx] = value
        }
        newRows[targetRowIdx] = targetRow
        inspectorResults[key] = QueryResult(
            columns: result.columns,
            rows: newRows,
            rowsAffected: result.rowsAffected,
            executionTime: result.executionTime,
            isTruncated: result.isTruncated
        )
    }

    func insertRow(values: [String: String?]) async throws {
        guard let client, let table = selectedTable else { return }
        try await client.insertRow(table, values: values)
        invalidateContentCaches(for: table.id)
        await loadInspector(tab: .content)
    }

    // MARK: - Draft row (inline 新增 / 复制行)

    /// 开一个空白草稿行（「+新增行」入口）。位置默认表尾。
    func startBlankDraft(insertAfter rowIdx: Int? = nil) {
        guard let table = selectedTable else { return }
        draftRow = DraftRow(tableID: table.id, values: [:], insertAfterRowIndex: rowIdx)
    }

    /// 以一行现有数据为模板开草稿（「复制行」入口）。
    /// 主键 / auto_increment 列会被剔除 — 让 DB 重新分配，避免唯一性冲突。
    /// - Parameters:
    ///   - row: 源行的单元格值（与 columnNames 同序）
    ///   - columnNames: 源行的列序（来自 QueryResult.columns）
    ///   - insertAfter: 草稿插入位置（nil = 表尾）
    func startDraftCopying(from row: [String?], columnNames: [String], insertAfter rowIdx: Int?) {
        guard let table = selectedTable else { return }
        let defs = currentColumnDefinitions() ?? []
        let skipNames = Set(defs.filter { $0.isPrimaryKey || $0.isAutoIncrement }.map { $0.name })
        var values: [String: String?] = [:]
        for (i, name) in columnNames.enumerated() where !skipNames.contains(name) {
            // 源行的 NULL 也复制成 NULL；空字符串复制成空字符串
            if i < row.count {
                values[name] = .some(row[i])
            }
        }
        draftRow = DraftRow(tableID: table.id, values: values, insertAfterRowIndex: rowIdx)
    }

    /// 单元格编辑：把这一列设为 `s`（s 可能是空字符串 — 仍算显式值）。
    func setDraftValue(column: String, value: String) {
        guard var draft = draftRow else { return }
        draft.values[column] = .some(.some(value))
        draftRow = draft
    }

    /// 显式 NULL — 用户在 inline 编辑里勾选「NULL」。
    func setDraftNull(column: String) {
        guard var draft = draftRow else { return }
        draft.values[column] = .some(nil)
        draftRow = draft
    }

    /// 让这列回到「走 DB 默认 / auto_increment」状态（dict 中移除）。
    func resetDraftToDefault(column: String) {
        guard var draft = draftRow else { return }
        draft.values.removeValue(forKey: column)
        draftRow = draft
    }

    func cancelDraft() {
        draftRow = nil
    }

    /// 提交草稿。失败抛错（不清 draft，让用户改完再提交）。
    func commitDraft() async throws {
        guard let client, let table = selectedTable, let draft = draftRow,
              draft.tableID == table.id else { return }
        try await client.insertRow(table, values: draft.values)
        draftRow = nil
        invalidateContentCaches(for: table.id)
        await loadInspector(tab: .content)
    }

    func deleteRow(primaryKey: [String: String]) async throws {
        guard let client, let table = selectedTable else { return }
        try await client.deleteRow(table, primaryKey: primaryKey)
        invalidateContentCaches(for: table.id)
        await loadInspector(tab: .content)
    }

    /// 表数据被外部全量改动（TRUNCATE / DELETE FROM 全表）后调：
    /// 失效缓存 + 回第一页 + reload 当前 tab。
    func reloadAfterBulkContentChange() async {
        guard let table = selectedTable else { return }
        invalidateContentCaches(for: table.id)
        contentPage[table.id] = 0
        await loadInspector(tab: inspectorTab)
    }

    /// 失效一张表的所有 content 缓存（含分页 + 行数 + 错误）。
    /// 增/删/改后调，让 UI reload 拉到新数据。
    private func invalidateContentCaches(for tableID: String) {
        // 先把要删的 key 取出来，再删；不要边迭代 .keys 边 mutate 容器（Swift UB）。
        let prefix = "\(tableID):content:"
        let toRemove = inspectorResults.keys.filter { $0.hasPrefix(prefix) }
        for key in toRemove {
            inspectorResults.removeValue(forKey: key)
            inspectorErrors.removeValue(forKey: key)
        }
        contentRowCount.removeValue(forKey: tableID)
        contentRowCountTimedOut.remove(tableID)
    }

    func dropIndex(_ name: String) async throws {
        guard let client, let table = selectedTable else { return }
        try await client.dropIndex(table, indexName: name)
        indexDefinitionsCache.removeValue(forKey: table.id)
        await loadIndexDefinitions()
        infoDetailCache.removeValue(forKey: table.id)
    }

    private func inspectorKey(table: DatabaseObject, tab: TableInspectorTab) -> String {
        if tab == .content {
            let page = contentPage[table.id] ?? 0
            let filter = contentFilters[table.id] ?? ""
            // hash 一下 filter 避免 key 过长
            let filterTag = filter.isEmpty ? "" : ":f\(abs(filter.hashValue))"
            return "\(table.id):content:p\(page)\(filterTag)"
        }
        return "\(table.id):\(tab.rawValue)"
    }

    func currentInspectorResult() -> QueryResult? {
        guard let table = selectedTable else { return nil }
        return inspectorResults[inspectorKey(table: table, tab: inspectorTab)]
    }

    func currentInspectorError() -> String? {
        guard let table = selectedTable else { return nil }
        return inspectorErrors[inspectorKey(table: table, tab: inspectorTab)]
    }

    // MARK: - 内容分页

    var currentContentPage: Int {
        guard let table = selectedTable else { return 0 }
        return contentPage[table.id] ?? 0
    }

    var currentContentRowCount: Int? {
        guard let table = selectedTable else { return nil }
        return contentRowCount[table.id] ?? nil
    }

    var currentContentTotalPages: Int? {
        guard let total = currentContentRowCount else { return nil }
        if total == 0 { return 1 }
        return (total + contentPageSize - 1) / contentPageSize
    }

    var currentContentRowCountTimedOut: Bool {
        guard let table = selectedTable else { return false }
        return contentRowCountTimedOut.contains(table.id)
    }

    /// COUNT(*) 5s 超时保护：大表精确计数可能阻塞数十秒，期间还会占用连接通道
    /// 阻塞其它表浏览。这里用 task group 与计时器赛跑，超时回退到 nil 让 UI 显示
    /// "(行数估算超时)"。注意 Task.cancel 不一定能中断 NIO future；继续跑的查询
    /// 会在自然完成或连接关闭时退出，但调用方已不再等待。
    private enum CountOutcome: Sendable {
        case ok(Int?)
        case timeout
    }

    private static func countWithTimeout(
        client: DatabaseClient,
        table: DatabaseObject,
        filter: String,
        seconds: Double = 5
    ) async -> CountOutcome {
        await withTaskGroup(of: CountOutcome.self) { group -> CountOutcome in
            group.addTask {
                // try? + 返回 Int? = Int??，扁平化一层；任何错误（含连接关闭）都回退到 nil
                let v: Int? = (try? await client.countRows(table, whereClause: filter)) ?? nil
                return .ok(v)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
    }

    func goToContentPage(_ page: Int) async {
        guard let table = selectedTable else { return }
        let safePage = max(0, page)
        contentPage[table.id] = safePage
        await loadInspector(tab: .content)
    }

    func nextContentPage() async { await goToContentPage(currentContentPage + 1) }
    func prevContentPage() async { await goToContentPage(currentContentPage - 1) }

    func setContentPageSize(_ size: Int) async {
        let safeSize = max(10, min(size, 5000))
        guard safeSize != contentPageSize else { return }
        contentPageSize = safeSize
        contentPage = [:]
        for key in inspectorResults.keys where key.contains(":content:") {
            inspectorResults.removeValue(forKey: key)
            inspectorErrors.removeValue(forKey: key)
        }
        await loadInspector(tab: .content)
    }

    var currentContentFilter: String {
        guard let table = selectedTable else { return "" }
        return contentFilters[table.id] ?? ""
    }

    var currentFilterRows: [FilterRow] {
        guard let table = selectedTable else { return [] }
        return contentFilterRows[table.id] ?? []
    }

    func setFilterRows(_ rows: [FilterRow]) {
        guard let table = selectedTable else { return }
        contentFilterRows[table.id] = rows
    }

    /// 应用结构化 filter rows → 编译成 WHERE → 跑查询
    func applyFilterRows(kind: DatabaseKind) async {
        guard let table = selectedTable else { return }
        let rows = contentFilterRows[table.id] ?? []
        let where_ = FilterSQLBuilder.build(rows: rows, kind: kind)
        await applyContentFilter(where_)
    }

    /// 应用 / 清除当前表的 WHERE 过滤；重置到第 1 页 + 重查总行数
    func applyContentFilter(_ filter: String) async {
        guard let table = selectedTable else { return }
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        contentFilters[table.id] = trimmed
        contentPage[table.id] = 0
        contentRowCount.removeValue(forKey: table.id)
        contentRowCountTimedOut.remove(table.id)
        // 清掉这张表所有 content 缓存（不同 filter 的都丢）
        for key in inspectorResults.keys where key.hasPrefix("\(table.id):content:") {
            inspectorResults.removeValue(forKey: key)
            inspectorErrors.removeValue(forKey: key)
        }
        await loadInspector(tab: .content)
    }
}
