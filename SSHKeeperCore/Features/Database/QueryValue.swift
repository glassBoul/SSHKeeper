import Foundation

/// 跨数据库的参数化绑定值。各 client 把这个枚举翻译到自己的原生绑定类型
/// （MySQL → `MySQLData`，Postgres → `PostgresBindings`）。比 `escape() + 字符串
/// 拼接` 安全：彻底消除 SQL 注入面，且数值/二进制不再被当字符串塞回去。
public enum QueryValue: Sendable, Equatable {
    case null
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case data(Data)
}

extension QueryValue {
    /// 把 SQL 中的 `?` 占位（MySQL 风格）按出现顺序换成 `$1, $2, ...`（Postgres 风格）。
    /// 简单状态机：尊重 `'...'`, `"..."`, `` `...` `` 内的 `?`（不替换）；不处理反斜杠
    /// 转义引号（标准 SQL 用 `''` 表示引号内单引号，状态机会自然 toggle 通过）。
    public static func mysqlPlaceholdersToPostgres(_ sql: String) -> String {
        var out = ""
        out.reserveCapacity(sql.count + 8)
        var index = 1
        var quoteChar: Character?
        for c in sql {
            if let qc = quoteChar {
                out.append(c)
                if c == qc { quoteChar = nil }
            } else if c == "'" || c == "\"" || c == "`" {
                quoteChar = c
                out.append(c)
            } else if c == "?" {
                out.append("$\(index)")
                index += 1
            } else {
                out.append(c)
            }
        }
        return out
    }
}
