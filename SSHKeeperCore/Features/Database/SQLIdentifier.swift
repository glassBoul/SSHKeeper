import Foundation

/// SQL 标识符（库名 / 表名 / 字段名）正确加引用。
/// 单引号字符串值用 `SQLEscape` 处理；这两个函数专管引用 *标识符*。
public enum SQLIdentifier {
    /// MySQL：用反引号包，把内容里的反引号 doubled
    public static func mysql(_ ident: String) -> String {
        let escaped = ident.replacingOccurrences(of: "`", with: "``")
        return "`\(escaped)`"
    }

    /// Postgres：用双引号包，把内容里的双引号 doubled
    public static func postgres(_ ident: String) -> String {
        let escaped = ident.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

/// SQL 字符串字面量内容转义（不含外层引号；调用方自己拼 `'...'`）。
///
/// 之前各处独立写的 `escape` 函数仅替换 `'` → `''`，但 MySQL 默认
/// `NO_BACKSLASH_ESCAPES = false`，反斜杠是转义字符。漏掉它意味着用户输入
/// 含 `\` 的字符串会破坏 SQL 解析甚至构成注入。这里集中处理。
public enum SQLEscape {
    /// MySQL 字符串字面量内容转义。
    /// 处理 `'`、`\`、以及 `\0` `\n` `\r` `\Z` 这些 MySQL 客户端协议关心的控制字符。
    public static func mysql(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count + 8)
        for ch in value {
            switch ch {
            case "'": out.append("''")
            case "\\": out.append("\\\\")
            case "\0": out.append("\\0")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\u{1A}": out.append("\\Z")  // Ctrl-Z；MySQL 在 Windows 客户端把它当 EOF
            default: out.append(ch)
            }
        }
        return out
    }

    /// PostgreSQL 字符串字面量内容转义。
    /// 假设 `standard_conforming_strings = on`（PG 9.1+ 默认），此时 `\` 是普通字符
    /// 不需要转义。如果你的服务器关闭了这个选项，应改用 `E'...'` 形式并扩展转义规则。
    public static func postgres(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
