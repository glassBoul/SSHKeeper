import Foundation

extension Array {
    /// 越界安全访问，找不到返回 nil。在 ResultGrid 行/列处理与 TableInspectorPane
    /// 的 filter row binding 里被多处使用，集中放一份避免重复定义。
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
