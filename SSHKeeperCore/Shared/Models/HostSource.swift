import Foundation

public enum HostSource: String, Codable, Sendable, CaseIterable {
    case appManaged
    case imported
}
