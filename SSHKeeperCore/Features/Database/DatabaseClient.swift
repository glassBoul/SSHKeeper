import Foundation

public enum DatabaseClientError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case queryFailed(String)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "尚未连接"
        case .connectionFailed(let m): "连接失败：\(m)"
        case .queryFailed(let m): "查询失败：\(m)"
        case .invalidConfiguration(let m): "配置错误：\(m)"
        }
    }
}

/// 客户端层硬截断阈值。两个实现都尊重它，超过这个行数后 stop 收集并把
/// `QueryResult.isTruncated` 标 true。
/// 设这么大主要是防 `SELECT *` 不带 LIMIT 把整张大表拖回客户端拖死 App。
public let maxClientResultRows = 100_000

public protocol DatabaseClient: AnyObject, Sendable {
    func connect() async throws
    func close() async
    func runQuery(_ sql: String) async throws -> QueryResult

    /// 参数化执行：SQL 中用 `?` 作占位（MySQL 风格），Postgres 实现内部翻译为 `$1, $2, ...`。
    /// 调用者（如 updateRow）以此消除字符串拼接 + escape 的注入面。
    func runQuery(_ sql: String, bindings: [QueryValue]) async throws -> QueryResult
    func listDatabases() async throws -> [String]
    func listTables(in database: String?) async throws -> [DatabaseObject]
    func switchDatabase(_ name: String) async throws

    // 表 inspector 用的 5 类查询
    func tableStructure(_ table: DatabaseObject) async throws -> QueryResult
    /// `whereClause` 是用户原样输入的 WHERE 表达式（不带 WHERE 关键字），空字符串 = 不过滤
    func tableContents(_ table: DatabaseObject, limit: Int, offset: Int, whereClause: String) async throws -> QueryResult
    func tableForeignKeys(_ table: DatabaseObject) async throws -> QueryResult
    func tableTriggers(_ table: DatabaseObject) async throws -> QueryResult
    func tableInfo(_ table: DatabaseObject) async throws -> QueryResult
    func countRows(_ table: DatabaseObject, whereClause: String) async throws -> Int?

    /// 富格式的表元信息（用于「表信息」面板）
    func tableInfoDetailed(_ table: DatabaseObject) async throws -> TableInfoDetail

    /// 提交表元信息修改（仅 MySQL 实现；Postgres 抛 invalidConfiguration）
    func updateTableMetadata(_ table: DatabaseObject, changes: TableMetadataChanges) async throws

    /// 取所有字段定义（用于结构编辑面板）
    func tableColumnDefinitions(_ table: DatabaseObject) async throws -> [ColumnDefinition]

    /// 增字段。`after` 为 nil 表示加在末尾，"" 表示加在最前。
    func addColumn(_ table: DatabaseObject, column: ColumnDefinition, after: String?) async throws

    /// 删字段
    func dropColumn(_ table: DatabaseObject, columnName: String) async throws

    /// 改字段（含重命名）。`oldName` 跟 `column.name` 不同则一并 RENAME。
    func modifyColumn(_ table: DatabaseObject, oldName: String, column: ColumnDefinition) async throws

    // MARK: - Indexes

    func tableIndexDefinitions(_ table: DatabaseObject) async throws -> [IndexDefinition]
    func addIndex(_ table: DatabaseObject, index: IndexDefinition) async throws
    func dropIndex(_ table: DatabaseObject, indexName: String) async throws

    // MARK: - Table CRUD

    /// 在指定库创建表。primaryKeys 为空则不加 PRIMARY KEY 约束。
    func createTable(
        database: String,
        name: String,
        columns: [ColumnDefinition],
        primaryKeys: [String]
    ) async throws

    func dropTable(_ table: DatabaseObject) async throws

    /// 清空表：删除所有数据并重置自增 ID。
    /// MySQL: `TRUNCATE TABLE …`（InnoDB 默认重置 AUTO_INCREMENT）。
    /// PG: `TRUNCATE TABLE … RESTART IDENTITY`。
    /// 不主动 CASCADE — 被外键引用时会抛错，避免连带删除其它表数据。
    func truncateTable(_ table: DatabaseObject) async throws

    /// 删除表所有数据但保留自增 ID（`DELETE FROM …`）。
    /// MySQL: AUTO_INCREMENT 计数不重置；PG: sequence 当前值不动。
    /// 受外键约束限制；需要 CASCADE 请走 SQL 编辑器。
    func deleteAllRows(_ table: DatabaseObject) async throws

    func renameTable(_ table: DatabaseObject, to newName: String) async throws

    /// 复制表。`includeData`：true 同时拷数据；false 只拷结构。
    func duplicateTable(_ table: DatabaseObject, newName: String, includeData: Bool) async throws

    /// 更新一行的某个字段。`primaryKey` 是这行的主键值（多列主键全列出）。
    /// `value` 为 nil 表示设为 NULL。
    func updateRow(
        _ table: DatabaseObject,
        primaryKey: [String: String],
        column: String,
        value: String?
    ) async throws

    /// 插入一行。`values` 的 key 为列名，值用 `String?` 表达（nil = NULL）。
    /// AUTO_INCREMENT / 想走 DEFAULT 的列应不出现在 `values` 中 —— SQL 不写该列，
    /// 由 DB 兜默认值或自增。
    func insertRow(_ table: DatabaseObject, values: [String: String?]) async throws

    /// 按主键删除一行。无主键直接 throw（沿用 updateRow 的硬约束）。
    /// MySQL 内部加 LIMIT 1 防 PK 错选误删大量行；PG 不支持 LIMIT，靠 PK 唯一性保证。
    func deleteRow(_ table: DatabaseObject, primaryKey: [String: String]) async throws
}

public enum DatabaseClientFactory {
    public static func make(database: Database, password: String) -> DatabaseClient {
        switch database.kind {
        case .postgres:
            return PostgresDatabaseClient(database: database, password: password)
        case .mysql:
            return MySQLDatabaseClient(database: database, password: password)
        }
    }
}
