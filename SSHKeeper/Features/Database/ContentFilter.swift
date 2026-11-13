import Foundation
import SSHKeeperCore

enum FilterOp: String, CaseIterable, Identifiable {
    case equals = "="
    case notEquals = "≠"
    case like = "LIKE"
    case notLike = "NOT LIKE"
    case contains
    case doesNotContain = "does not contain"
    case startsWith = "starts with"
    case doesNotStartWith = "does not start with"
    case endsWith = "ends with"
    case doesNotEndWith = "does not end with"
    case regexp = "matches RegExp"
    case notRegexp = "does not match RegExp"
    case inList = "IN"
    case notInOrNull = "NOT IN __ OR NULL"
    case between = "BETWEEN"
    case isNull = "IS NULL"
    case isNotNull = "IS NOT NULL"
    case isEmpty = "is empty"
    case isNotEmpty = "is not empty"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// 是否需要值输入
    var needsValue: Bool {
        switch self {
        case .isNull, .isNotNull, .isEmpty, .isNotEmpty: return false
        default: return true
        }
    }

    /// BETWEEN 需要两个值
    var needsSecondValue: Bool { self == .between }

    var valuePlaceholder: String {
        switch self {
        case .like, .notLike: return "支持 % 通配符"
        case .inList, .notInOrNull: return "逗号分隔，如 a, b, c"
        case .between: return "起始值"
        case .regexp, .notRegexp: return "正则表达式"
        default: return "值"
        }
    }
}

struct FilterRow: Identifiable, Equatable {
    let id = UUID()
    var enabled: Bool = true
    var column: String = ""
    var op: FilterOp = .equals
    var value: String = ""
    var value2: String = ""

    /// 这一行是否能产生有效的 SQL（启用 + 字段非空 + 必填值都填了）
    var isExecutable: Bool {
        guard enabled, !column.isEmpty else { return false }
        if op.needsValue && value.isEmpty { return false }
        if op.needsSecondValue && value2.isEmpty { return false }
        return true
    }
}

enum FilterSQLBuilder {
    /// 把多行筛选条件合并成 WHERE 表达式（不带 WHERE 关键字）。
    /// 启用且条件完整的行用 AND 连接。
    static func build(rows: [FilterRow], kind: DatabaseKind) -> String {
        let active = rows.filter { $0.isExecutable }
        let parts = active.compactMap { row -> String? in
            singleRowSQL(row, kind: kind)
        }
        return parts.joined(separator: " AND ")
    }

    private static func singleRowSQL(_ row: FilterRow, kind: DatabaseKind) -> String? {
        let col = quoteIdent(row.column, kind: kind)
        let v = escape(row.value, kind: kind)
        let v2 = escape(row.value2, kind: kind)

        switch row.op {
        case .equals:
            return "\(col) = '\(v)'"
        case .notEquals:
            return "\(col) <> '\(v)'"
        case .like:
            return "\(col) LIKE '\(v)'"
        case .notLike:
            return "\(col) NOT LIKE '\(v)'"
        case .contains:
            return "\(col) LIKE '%\(v)%'"
        case .doesNotContain:
            return "\(col) NOT LIKE '%\(v)%'"
        case .startsWith:
            return "\(col) LIKE '\(v)%'"
        case .doesNotStartWith:
            return "\(col) NOT LIKE '\(v)%'"
        case .endsWith:
            return "\(col) LIKE '%\(v)'"
        case .doesNotEndWith:
            return "\(col) NOT LIKE '%\(v)'"
        case .regexp:
            return kind == .mysql ? "\(col) REGEXP '\(v)'" : "\(col) ~ '\(v)'"
        case .notRegexp:
            return kind == .mysql ? "\(col) NOT REGEXP '\(v)'" : "\(col) !~ '\(v)'"
        case .inList:
            let list = inListValues(row.value, kind: kind)
            guard !list.isEmpty else { return nil }
            return "\(col) IN (\(list))"
        case .notInOrNull:
            let list = inListValues(row.value, kind: kind)
            guard !list.isEmpty else { return nil }
            return "(\(col) NOT IN (\(list)) OR \(col) IS NULL)"
        case .between:
            return "\(col) BETWEEN '\(v)' AND '\(v2)'"
        case .isNull:
            return "\(col) IS NULL"
        case .isNotNull:
            return "\(col) IS NOT NULL"
        case .isEmpty:
            return "(\(col) = '' OR \(col) IS NULL)"
        case .isNotEmpty:
            return "(\(col) <> '' AND \(col) IS NOT NULL)"
        }
    }

    private static func quoteIdent(_ name: String, kind: DatabaseKind) -> String {
        switch kind {
        case .mysql: return SQLIdentifier.mysql(name)
        case .postgres: return SQLIdentifier.postgres(name)
        }
    }

    private static func escape(_ s: String, kind: DatabaseKind) -> String {
        switch kind {
        case .mysql: return SQLEscape.mysql(s)
        case .postgres: return SQLEscape.postgres(s)
        }
    }

    private static func inListValues(_ raw: String, kind: DatabaseKind) -> String {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "'\(escape($0, kind: kind))'" }
            .joined(separator: ", ")
    }
}
