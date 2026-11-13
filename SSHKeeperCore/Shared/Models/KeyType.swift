import Foundation

public enum KeyType: String, Codable, Sendable, CaseIterable {
    case ed25519
    case rsa
    case ecdsa
    case dsa
    case unknown

    public var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .rsa: "RSA"
        case .ecdsa: "ECDSA"
        case .dsa: "DSA"
        case .unknown: "Unknown"
        }
    }
}
