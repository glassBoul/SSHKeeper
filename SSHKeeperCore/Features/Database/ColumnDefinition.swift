import Foundation

/// 一列的完整定义。增/删/改字段用同一个结构。
public struct ColumnDefinition: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var dataType: String        // 完整类型：VARCHAR(255) / INT / BIGINT / TEXT / JSON / DATETIME(6) ...
    public var nullable: Bool
    public var defaultValue: String?   // 原始 SQL 表达式（NULL / 'foo' / CURRENT_TIMESTAMP / NULL 表示无默认值）
    public var isPrimaryKey: Bool
    public var isAutoIncrement: Bool
    public var comment: String?
    public var collation: String?      // 仅字符类型才有意义；nil 表示用表默认

    public init(
        name: String,
        dataType: String,
        nullable: Bool = true,
        defaultValue: String? = nil,
        isPrimaryKey: Bool = false,
        isAutoIncrement: Bool = false,
        comment: String? = nil,
        collation: String? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.nullable = nullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.isAutoIncrement = isAutoIncrement
        self.comment = comment
        self.collation = collation
    }
}

/// MySQL 常见类型，UI 下拉用。可手输自定义。
public enum MySQLColumnType {
    public static let common: [String] = [
        "INT", "BIGINT", "SMALLINT", "TINYINT", "MEDIUMINT",
        "DECIMAL(10,2)", "FLOAT", "DOUBLE",
        "VARCHAR(255)", "CHAR(36)", "TEXT", "MEDIUMTEXT", "LONGTEXT",
        "DATE", "DATETIME", "TIMESTAMP", "TIME", "YEAR",
        "JSON", "BLOB", "MEDIUMBLOB", "LONGBLOB",
        "BOOLEAN", "ENUM('a','b','c')", "BIT(1)"
    ]
}
