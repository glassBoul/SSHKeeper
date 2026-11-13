import Foundation

public enum IndexCategory: String, Codable, Sendable, CaseIterable {
    case primary
    case unique
    case normal
    case fulltext
    case spatial

    public var displayName: String {
        switch self {
        case .primary: "主键"
        case .unique: "UNIQUE"
        case .normal: "普通"
        case .fulltext: "FULLTEXT"
        case .spatial: "SPATIAL"
        }
    }
}

public struct IndexDefinition: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var category: IndexCategory
    public var columns: [String]
    public var method: String?       // BTREE / HASH（MySQL）/ btree / gin（PG）
    public var comment: String?

    public init(
        name: String,
        category: IndexCategory = .normal,
        columns: [String],
        method: String? = nil,
        comment: String? = nil
    ) {
        self.name = name
        self.category = category
        self.columns = columns
        self.method = method
        self.comment = comment
    }
}
