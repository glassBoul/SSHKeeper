import AppKit
import Foundation

enum SQLTokenKind {
    case keyword, builtin, string, number, comment
}

struct SQLToken {
    let kind: SQLTokenKind
    let range: NSRange
}

enum SQLHighlighter {
    /// SQL 关键字（大小写不敏感匹配）
    static let keywords: Set<String> = [
        "ADD", "ALL", "ALTER", "AND", "AS", "ASC", "AT", "AUTHORIZATION",
        "BEGIN", "BETWEEN", "BY",
        "CASE", "CAST", "CHECK", "COLUMN", "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT",
        "DATABASE", "DECLARE", "DEFAULT", "DELETE", "DESC", "DESCRIBE", "DISTINCT", "DROP",
        "ELSE", "END", "EXCEPT", "EXISTS", "EXPLAIN",
        "FALSE", "FETCH", "FOR", "FOREIGN", "FROM", "FULL", "FUNCTION",
        "GRANT", "GROUP", "HAVING",
        "IF", "IN", "INDEX", "INNER", "INSERT", "INTERSECT", "INTO", "IS",
        "JOIN",
        "KEY",
        "LEFT", "LIKE", "LIMIT", "LOCK",
        "MERGE",
        "NATURAL", "NOT", "NULL",
        "OFFSET", "ON", "OR", "ORDER", "OUTER",
        "PRIMARY", "PROCEDURE",
        "REFERENCES", "RETURNING", "REVOKE", "RIGHT", "ROLLBACK", "ROW",
        "SAVEPOINT", "SCHEMA", "SELECT", "SET", "SHOW",
        "TABLE", "THEN", "TO", "TRANSACTION", "TRIGGER", "TRUE", "TRUNCATE",
        "UNION", "UNIQUE", "UPDATE", "USE", "USING",
        "VALUES", "VIEW",
        "WHEN", "WHERE", "WITH"
    ]

    /// 内建函数 / 类型名（弱关键字，单独配色）
    static let builtins: Set<String> = [
        "BIGINT", "BIT", "BLOB", "BOOL", "BOOLEAN", "CHAR", "CHARACTER", "DATE", "DATETIME",
        "DECIMAL", "DOUBLE", "ENUM", "FLOAT", "INT", "INT8", "INT4", "INT2", "INTEGER", "JSON",
        "JSONB", "LONGTEXT", "MEDIUMTEXT", "NUMERIC", "REAL", "SERIAL", "SMALLINT", "TEXT",
        "TIME", "TIMESTAMP", "TIMESTAMPTZ", "TINYINT", "UUID", "VARBINARY", "VARCHAR", "XML",
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "GREATEST", "LEAST",
        "NOW", "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "EXTRACT", "DATE_TRUNC",
        "LOWER", "UPPER", "LENGTH", "TRIM", "SUBSTRING", "SUBSTR", "CONCAT", "REPLACE",
        "ROUND", "FLOOR", "CEIL", "ABS"
    ]

    static func apply(to storage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        // 重置默认样式
        storage.setAttributes(defaultAttributes, range: fullRange)

        // tokenize 并染色
        for token in SQLTokenizer.tokenize(storage.string) {
            storage.addAttributes(attributes(for: token.kind), range: token.range)
        }
    }

    static var defaultAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
    }

    private static func attributes(for kind: SQLTokenKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .keyword:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.systemPink
            ]
        case .builtin:
            return [
                .foregroundColor: NSColor.systemTeal
            ]
        case .string:
            return [
                .foregroundColor: NSColor.systemGreen
            ]
        case .number:
            return [
                .foregroundColor: NSColor.systemPurple
            ]
        case .comment:
            return [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFontManager.shared.convert(
                    NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    toHaveTrait: .italicFontMask
                )
            ]
        }
    }
}

enum SQLTokenizer {
    static func tokenize(_ text: String) -> [SQLToken] {
        let nsStr = text as NSString
        let n = nsStr.length
        guard n > 0 else { return [] }

        var tokens: [SQLToken] = []
        var i = 0

        while i < n {
            let c = nsStr.character(at: i)

            // 空白
            if isWhitespace(c) { i += 1; continue }

            // 单行注释 -- ...
            if c == 0x2D, i + 1 < n, nsStr.character(at: i + 1) == 0x2D {
                let start = i
                while i < n && nsStr.character(at: i) != 0x0A { i += 1 }
                tokens.append(SQLToken(kind: .comment, range: NSRange(location: start, length: i - start)))
                continue
            }
            // MySQL 风格 # 注释
            if c == 0x23 {
                let start = i
                while i < n && nsStr.character(at: i) != 0x0A { i += 1 }
                tokens.append(SQLToken(kind: .comment, range: NSRange(location: start, length: i - start)))
                continue
            }
            // 块注释 /* ... */
            if c == 0x2F, i + 1 < n, nsStr.character(at: i + 1) == 0x2A {
                let start = i
                i += 2
                while i + 1 < n && !(nsStr.character(at: i) == 0x2A && nsStr.character(at: i + 1) == 0x2F) {
                    i += 1
                }
                if i + 1 < n { i += 2 } else { i = n }
                tokens.append(SQLToken(kind: .comment, range: NSRange(location: start, length: i - start)))
                continue
            }

            // 字符串：' 或 "
            if c == 0x27 || c == 0x22 {
                let quote = c
                let start = i
                i += 1
                while i < n {
                    let ch = nsStr.character(at: i)
                    if ch == 0x5C, i + 1 < n {  // \ escape
                        i += 2
                        continue
                    }
                    if ch == quote {
                        if i + 1 < n && nsStr.character(at: i + 1) == quote {
                            i += 2  // SQL 双引号转义
                            continue
                        }
                        i += 1
                        break
                    }
                    i += 1
                }
                tokens.append(SQLToken(kind: .string, range: NSRange(location: start, length: i - start)))
                continue
            }

            // 数字
            if isDigit(c) {
                let start = i
                while i < n {
                    let ch = nsStr.character(at: i)
                    if isDigit(ch) || ch == 0x2E || ch == 0x65 || ch == 0x45 { i += 1 }
                    else { break }
                }
                tokens.append(SQLToken(kind: .number, range: NSRange(location: start, length: i - start)))
                continue
            }

            // 标识符 / 关键字
            if isIdentStart(c) {
                let start = i
                while i < n && isIdentPart(nsStr.character(at: i)) { i += 1 }
                let range = NSRange(location: start, length: i - start)
                let word = nsStr.substring(with: range).uppercased()
                if SQLHighlighter.keywords.contains(word) {
                    tokens.append(SQLToken(kind: .keyword, range: range))
                } else if SQLHighlighter.builtins.contains(word) {
                    tokens.append(SQLToken(kind: .builtin, range: range))
                }
                continue
            }

            i += 1
        }

        return tokens
    }

    private static func isWhitespace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    private static func isDigit(_ c: unichar) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    private static func isIdentStart(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }

    private static func isIdentPart(_ c: unichar) -> Bool {
        isIdentStart(c) || isDigit(c)
    }
}
