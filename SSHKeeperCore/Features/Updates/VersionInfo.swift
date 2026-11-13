import Foundation

/// 版本元信息，从远端 version.json 解析得到。
/// 字段必须全部存在；多余字段忽略以便未来扩展（minimum / publishedAt / sha256）。
public struct VersionInfo: Codable, Sendable, Equatable {
    public let latest: String
    public let downloadUrl: URL
    public let releaseNotes: String

    public init(latest: String, downloadUrl: URL, releaseNotes: String) {
        self.latest = latest
        self.downloadUrl = downloadUrl
        self.releaseNotes = releaseNotes
    }

    /// 解析 JSON 数据。失败 throw `VersionInfoError` 或 Codable 原生错误。
    public static func parse(_ data: Data) throws -> VersionInfo {
        let decoder = JSONDecoder()
        return try decoder.decode(VersionInfo.self, from: data)
    }
}

public enum VersionInfoError: Error, LocalizedError {
    case invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return "更新信息格式异常: \(msg)"
        }
    }
}
