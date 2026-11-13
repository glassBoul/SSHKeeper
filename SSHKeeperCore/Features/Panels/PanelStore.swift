import Foundation
import Observation

@Observable
@MainActor
public final class PanelStore {
    public private(set) var panels: [Panel] = []
    public private(set) var lastError: String?

    private let sidecar: SidecarController

    public init(sidecar: SidecarController) {
        self.sidecar = sidecar
    }

    public func load() {
        self.panels = sidecar.payload.panels
        self.lastError = nil
    }

    public func upsert(_ panel: Panel) throws {
        if let index = panels.firstIndex(where: { $0.id == panel.id }) {
            panels[index] = panel
        } else {
            panels.append(panel)
        }
        persist()
    }

    public func remove(id: UUID) throws {
        panels.removeAll { $0.id == id }
        persist()
    }

    public func touch(id: UUID, at date: Date = Date()) throws {
        guard let index = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[index].lastUsedAt = date
        persist()
    }

    public func panel(id: UUID) -> Panel? {
        panels.first(where: { $0.id == id })
    }

    private func persist() {
        let snapshot = panels
        sidecar.mutate { payload in
            payload.panels = snapshot
        }
    }
}
