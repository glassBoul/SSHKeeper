import Foundation

public struct QueryResult: Sendable, Equatable {
    public let columns: [String]
    public let rows: [[String?]]
    public let rowsAffected: Int?
    public let executionTime: TimeInterval
    /// 客户端层硬截断（如 SELECT * FROM 大表）防 OOM 后置 true。
    /// UI 应该提示用户"还有更多行未显示，请加 LIMIT"。
    public let isTruncated: Bool

    public init(
        columns: [String] = [],
        rows: [[String?]] = [],
        rowsAffected: Int? = nil,
        executionTime: TimeInterval = 0,
        isTruncated: Bool = false
    ) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.executionTime = executionTime
        self.isTruncated = isTruncated
    }

    public var isEmpty: Bool { rows.isEmpty }
}

public struct DatabaseObject: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable {
        case database, schema, table, view
    }
    public let id: String
    public let name: String
    public let kind: Kind
    public let parent: String?

    public init(id: String, name: String, kind: Kind, parent: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parent = parent
    }
}
