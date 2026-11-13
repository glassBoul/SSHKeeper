import Foundation

public enum DatabaseKind: String, Codable, Sendable, CaseIterable {
    case mysql
    case postgres

    public var displayName: String {
        switch self {
        case .mysql: "MySQL"
        case .postgres: "PostgreSQL"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .mysql: 3306
        case .postgres: 5432
        }
    }
}

public enum DatabaseTLSMode: String, Codable, Sendable, CaseIterable {
    case disable
    case prefer
    case require

    public var displayName: String {
        switch self {
        case .disable: "关闭"
        case .prefer: "可选"
        case .require: "强制"
        }
    }
}

public struct Database: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: DatabaseKind
    public var host: String
    public var port: Int
    public var defaultDatabase: String
    public var username: String
    public var tlsMode: DatabaseTLSMode
    public var allowSelfSignedTLS: Bool
    public var groupID: UUID?
    public var tags: [String]
    public var colorHex: String?
    public var lastUsedAt: Date?

    /// 通过 SSH 隧道转发：值为 ~/.ssh/config 里的 Host alias（也即 SSHKeeper 里的主机名）。
    /// nil / "" → 直连。开启后 client.connect() 会先启 `ssh -N -L lport:host:port alias`
    /// 再让 NIO 连本地 127.0.0.1:lport。host/port 仍存原始目标地址（从 SSH server 视角解析）。
    public var sshHostAlias: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: DatabaseKind = .postgres,
        host: String,
        port: Int? = nil,
        defaultDatabase: String,
        username: String,
        tlsMode: DatabaseTLSMode = .disable,
        allowSelfSignedTLS: Bool = true,
        groupID: UUID? = nil,
        tags: [String] = [],
        colorHex: String? = nil,
        lastUsedAt: Date? = nil,
        sshHostAlias: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.defaultDatabase = defaultDatabase
        self.username = username
        self.tlsMode = tlsMode
        self.allowSelfSignedTLS = allowSelfSignedTLS
        self.groupID = groupID
        self.tags = tags
        self.colorHex = colorHex
        self.lastUsedAt = lastUsedAt
        self.sshHostAlias = sshHostAlias
    }
}
