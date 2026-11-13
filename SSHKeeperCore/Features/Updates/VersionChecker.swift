import Foundation

/// 版本检查：比较 + 远端拉取。所有方法 static / 无状态。
public enum VersionChecker {

    /// 比较两个语义化版本字符串：按 `.` 分段比 Int；短的补 0；
    /// 任一段非数字（如 `1.0.0-beta`）→ fallback `localizedStandardCompare`。
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").map { Int($0) ?? -1 }
        let bParts = b.split(separator: ".").map { Int($0) ?? -1 }
        // 任一段非数字 → fallback
        if aParts.contains(-1) || bParts.contains(-1) {
            return a.localizedStandardCompare(b)
        }
        let maxLen = max(aParts.count, bParts.count)
        for i in 0..<maxLen {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    /// remote 比 local 更新返回 true。
    public static func isNewer(remote: String, than local: String) -> Bool {
        compare(remote, local) == .orderedDescending
    }

    /// 从 URL 拉 version.json 并解析。
    /// 网络 / 状态码 / 解析失败都抛错；调用方决定如何展示。
    public static func fetch(url: URL = UpdateConfig.manifestURL) async throws -> VersionInfo {
        var request = URLRequest(url: url)
        request.timeoutInterval = UpdateConfig.fetchTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VersionCheckError.httpStatus(http.statusCode)
        }
        return try VersionInfo.parse(data)
    }
}

public enum VersionCheckError: Error, LocalizedError {
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "更新服务器返回错误（HTTP \(code)）"
        }
    }
}
