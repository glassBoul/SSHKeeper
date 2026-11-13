import Foundation

/// 按 SSH alias 持久化最近一次的远端上传目录，写 UserDefaults。
/// 首次使用某 alias 返回 "~/"；用户提交上传后写回。
enum UploadDestinationMemory {
    /// UserDefaults key：版本后缀，方便未来 schema 演进。
    private static let storageKey = "uploadDestinationByAlias.v1"

    static func get(alias: String) -> String {
        let map = (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
        return map[alias] ?? "~/"
    }

    static func set(alias: String, path: String) {
        var map = (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
        map[alias] = path
        UserDefaults.standard.set(map, forKey: storageKey)
    }
}
