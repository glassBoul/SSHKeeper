import Foundation

public enum PanelKind: String, Codable, Sendable, CaseIterable {
    case baota        // 宝塔面板
    case onePanel     // 1Panel
    case aaPanel
    case generic      // 通用 username/password 表单

    public var displayName: String {
        switch self {
        case .baota: "宝塔面板"
        case .onePanel: "1Panel"
        case .aaPanel: "aaPanel"
        case .generic: "通用面板"
        }
    }
}

public struct Panel: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var url: String
    public var username: String
    public var kind: PanelKind
    public var groupID: UUID?
    public var tags: [String]
    public var colorHex: String?
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        url: String,
        username: String,
        kind: PanelKind = .baota,
        groupID: UUID? = nil,
        tags: [String] = [],
        colorHex: String? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.kind = kind
        self.groupID = groupID
        self.tags = tags
        self.colorHex = colorHex
        self.lastUsedAt = lastUsedAt
    }
}
