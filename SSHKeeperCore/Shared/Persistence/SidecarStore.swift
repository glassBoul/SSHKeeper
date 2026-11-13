import Foundation

public struct HostMetadata: Codable, Sendable, Equatable {
    public var groupID: UUID?
    public var tags: [String]
    public var colorHex: String?
    public var lastUsedAt: Date?

    public init(
        groupID: UUID? = nil,
        tags: [String] = [],
        colorHex: String? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.groupID = groupID
        self.tags = tags
        self.colorHex = colorHex
        self.lastUsedAt = lastUsedAt
    }
}

public struct SidecarPayload: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var groups: [HostGroup]
    public var hostMetadata: [String: HostMetadata]
    public var panels: [Panel]
    public var databases: [Database]

    public init(
        schemaVersion: Int = 3,
        groups: [HostGroup] = [],
        hostMetadata: [String: HostMetadata] = [:],
        panels: [Panel] = [],
        databases: [Database] = []
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.hostMetadata = hostMetadata
        self.panels = panels
        self.databases = databases
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, groups, hostMetadata, panels, databases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        groups = (try? c.decode([HostGroup].self, forKey: .groups)) ?? []
        hostMetadata = (try? c.decode([String: HostMetadata].self, forKey: .hostMetadata)) ?? [:]
        panels = (try? c.decode([Panel].self, forKey: .panels)) ?? []
        databases = (try? c.decode([Database].self, forKey: .databases)) ?? []
    }
}

public enum SidecarStoreError: Error {
    case readFailed(String)
    case writeFailed(String)
}

public struct SidecarStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultLocation(bundleIdentifier: String = "com.sshkeeper.app") -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("SSHKeeper", isDirectory: true)
            .appendingPathComponent("metadata.json")
    }

    public func load() throws -> SidecarPayload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SidecarPayload()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SidecarStoreError.readFailed(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SidecarPayload.self, from: data)
        } catch {
            throw SidecarStoreError.readFailed(error.localizedDescription)
        }
    }

    public func save(_ payload: SidecarPayload) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(payload)
            let tempURL = directory.appendingPathComponent(".metadata.\(UUID().uuidString).tmp")
            try data.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            throw SidecarStoreError.writeFailed(error.localizedDescription)
        }
    }
}
