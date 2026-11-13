import Foundation

public struct SSHHost: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var alias: String
    public var hostname: String
    public var port: Int
    public var user: String?
    public var identityFile: String?
    public var proxyJump: String?
    public var extraOptions: [String: String]

    public var groupID: UUID?
    public var tags: [String]
    public var colorHex: String?
    public var lastUsedAt: Date?
    public var source: HostSource

    public init(
        id: UUID = UUID(),
        alias: String,
        hostname: String,
        port: Int = 22,
        user: String? = nil,
        identityFile: String? = nil,
        proxyJump: String? = nil,
        extraOptions: [String: String] = [:],
        groupID: UUID? = nil,
        tags: [String] = [],
        colorHex: String? = nil,
        lastUsedAt: Date? = nil,
        source: HostSource = .appManaged
    ) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.extraOptions = extraOptions
        self.groupID = groupID
        self.tags = tags
        self.colorHex = colorHex
        self.lastUsedAt = lastUsedAt
        self.source = source
    }
}
