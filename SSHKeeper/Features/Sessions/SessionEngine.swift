import Foundation
import Observation

@Observable
@MainActor
final class SessionEngine {
    private(set) var sessions: [Session] = []
    var activeSessionID: UUID?

    @discardableResult
    func openSession(alias: String) -> Session {
        let session = Session(alias: alias)
        sessions.append(session)
        activeSessionID = session.id
        return session
    }

    func closeSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        if activeSessionID == id {
            activeSessionID = sessions.last?.id
        }
    }

    /// Splits the active session by adding a second pane connected to the same alias.
    /// MVP cap: at most 2 panes per session.
    func splitActiveSession(_ direction: SplitDirection) {
        guard let id = activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[index].panes.count < 2 else { return }
        let newPane = Pane(alias: sessions[index].primaryAlias)
        sessions[index].panes.append(newPane)
        sessions[index].split = direction
        sessions[index].activePaneID = newPane.id
    }

    func closePane(sessionID: UUID, paneID: UUID) {
        guard let sIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[sIndex].panes.removeAll { $0.id == paneID }
        if sessions[sIndex].panes.isEmpty {
            closeSession(id: sessionID)
            return
        }
        if sessions[sIndex].panes.count == 1 {
            sessions[sIndex].split = nil
        }
        if sessions[sIndex].activePaneID == paneID {
            sessions[sIndex].activePaneID = sessions[sIndex].panes.first?.id
        }
    }

    func setActivePane(sessionID: UUID, paneID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].activePaneID = paneID
    }

    func updatePaneTitle(sessionID: UUID, paneID: UUID, title: String) {
        guard let sIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        guard let pIndex = sessions[sIndex].panes.firstIndex(where: { $0.id == paneID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[sIndex].panes[pIndex].title = trimmed.isEmpty ? sessions[sIndex].panes[pIndex].alias : trimmed
    }

    func markPaneExited(sessionID: UUID, paneID: UUID, code: Int32?) {
        guard let sIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        guard let pIndex = sessions[sIndex].panes.firstIndex(where: { $0.id == paneID }) else { return }
        sessions[sIndex].panes[pIndex].status = .exited(code)
    }

    func session(for id: UUID) -> Session? {
        sessions.first(where: { $0.id == id })
    }

    var activeSession: Session? {
        guard let id = activeSessionID else { return nil }
        return session(for: id)
    }
}
