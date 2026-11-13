import Foundation

/// RFC 4180 风格的 CSV 序列化。规则：
/// - 含 `,` `"` `\n` `\r` 的字段用 `"..."` 包裹
/// - 包裹内的 `"` 用 `""` 双写转义
/// - 行分隔用 CRLF（兼容 Excel）
/// - nil 值序列化为空字段
/// - 默认带 UTF-8 BOM（Excel 才能自动识别中文 / 多字节字符）
public enum CSVExporter {
    public static func encode(_ result: QueryResult, includeBOM: Bool = true) -> Data {
        var out = Data()
        if includeBOM {
            out.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        out.append(Data(formatHeader(result.columns).utf8))
        for row in result.rows {
            out.append(Data(formatRow(row).utf8))
        }
        return out
    }

    public static func write(_ result: QueryResult, to url: URL, includeBOM: Bool = true) throws {
        try encode(result, includeBOM: includeBOM).write(to: url, options: .atomic)
    }

    static func formatHeader(_ columns: [String]) -> String {
        columns.map(field).joined(separator: ",") + "\r\n"
    }

    static func formatRow(_ row: [String?]) -> String {
        row.map(field).joined(separator: ",") + "\r\n"
    }

    private static func field(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func field(_ s: String?) -> String {
        guard let s else { return "" }
        return field(s)
    }
}
