import Foundation

public struct KeyRef: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var path: String
    public var publicKeyPath: String?
    public var type: KeyType
    public var bitLength: Int?
    public var fingerprint: String?
    public var comment: String?
    public var hasPassphrase: Bool
    public var inKeychain: Bool

    public init(
        id: UUID = UUID(),
        path: String,
        publicKeyPath: String? = nil,
        type: KeyType = .unknown,
        bitLength: Int? = nil,
        fingerprint: String? = nil,
        comment: String? = nil,
        hasPassphrase: Bool = false,
        inKeychain: Bool = false
    ) {
        self.id = id
        self.path = path
        self.publicKeyPath = publicKeyPath
        self.type = type
        self.bitLength = bitLength
        self.fingerprint = fingerprint
        self.comment = comment
        self.hasPassphrase = hasPassphrase
        self.inKeychain = inKeychain
    }
}
