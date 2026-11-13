import Foundation
import Observation

@Observable
@MainActor
public final class DatabaseStore {
    public private(set) var databases: [Database] = []
    public private(set) var lastError: String?

    private let sidecar: SidecarController

    public init(sidecar: SidecarController) {
        self.sidecar = sidecar
    }

    public func load() {
        self.databases = sidecar.payload.databases
        self.lastError = nil
    }

    public func upsert(_ database: Database) throws {
        if let index = databases.firstIndex(where: { $0.id == database.id }) {
            databases[index] = database
        } else {
            databases.append(database)
        }
        persist()
    }

    public func remove(id: UUID) throws {
        databases.removeAll { $0.id == id }
        persist()
    }

    public func touch(id: UUID, at date: Date = Date()) throws {
        guard let index = databases.firstIndex(where: { $0.id == id }) else { return }
        databases[index].lastUsedAt = date
        persist()
    }

    public func database(id: UUID) -> Database? {
        databases.first(where: { $0.id == id })
    }

    private func persist() {
        let snapshot = databases
        sidecar.mutate { payload in
            payload.databases = snapshot
        }
    }
}
