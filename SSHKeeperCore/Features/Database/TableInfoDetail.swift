import Foundation

/// 富格式的表元信息（用于 inspector 「表信息」标签）。
/// MySQL 字段最齐；Postgres 只填能拿到的，其他为 nil。
public struct TableInfoDetail: Sendable, Equatable {
    public var tableName: String
    public var schema: String?

    // 顶部：类型 / 编码 / 排序规则
    public var engine: String?
    public var charset: String?
    public var collation: String?

    // 中部：统计
    public var rowCount: Int?
    public var rowFormat: String?
    public var avgRowLength: Int?
    public var autoIncrement: Int?
    public var dataSize: Int?
    public var maxDataSize: Int?
    public var indexSize: Int?
    public var freeDataSize: Int?

    // 时间
    public var createdAt: String?
    public var updatedAt: String?

    // 注释 + DDL
    public var comment: String?
    public var createSyntax: String?

    public init(
        tableName: String,
        schema: String? = nil,
        engine: String? = nil,
        charset: String? = nil,
        collation: String? = nil,
        rowCount: Int? = nil,
        rowFormat: String? = nil,
        avgRowLength: Int? = nil,
        autoIncrement: Int? = nil,
        dataSize: Int? = nil,
        maxDataSize: Int? = nil,
        indexSize: Int? = nil,
        freeDataSize: Int? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        comment: String? = nil,
        createSyntax: String? = nil
    ) {
        self.tableName = tableName
        self.schema = schema
        self.engine = engine
        self.charset = charset
        self.collation = collation
        self.rowCount = rowCount
        self.rowFormat = rowFormat
        self.avgRowLength = avgRowLength
        self.autoIncrement = autoIncrement
        self.dataSize = dataSize
        self.maxDataSize = maxDataSize
        self.indexSize = indexSize
        self.freeDataSize = freeDataSize
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.comment = comment
        self.createSyntax = createSyntax
    }
}

/// MySQL 表元信息修改集合。每个字段 nil 表示不改。
public struct TableMetadataChanges: Sendable {
    public var newEngine: String?
    public var newCharset: String?
    public var newCollation: String?
    public var newComment: String?

    public var hasChanges: Bool {
        newEngine != nil || newCharset != nil || newCollation != nil || newComment != nil
    }

    public init(
        newEngine: String? = nil,
        newCharset: String? = nil,
        newCollation: String? = nil,
        newComment: String? = nil
    ) {
        self.newEngine = newEngine
        self.newCharset = newCharset
        self.newCollation = newCollation
        self.newComment = newComment
    }
}
