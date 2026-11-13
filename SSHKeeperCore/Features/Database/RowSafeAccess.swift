import Foundation

/// 行解析的越界保护：很多 information_schema / SHOW 查询的列数会随版本变；用 `[safeRow: i]`
/// 而非 `[i]` 避免单条版本差异 panic 整个 inspector。
extension Array where Element == String? {
    subscript(safeRow index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
