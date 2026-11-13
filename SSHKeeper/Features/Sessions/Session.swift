import Foundation

enum SessionStatus: Equatable {
    case running
    case exited(Int32?)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

enum SplitDirection: String, Equatable {
    case horizontal  // panes stacked top/bottom
    case vertical    // panes side by side (left/right)
}

struct Pane: Identifiable, Equatable {
    let id: UUID
    let alias: String
    var title: String
    var status: SessionStatus

    init(alias: String, title: String? = nil) {
        self.id = UUID()
        self.alias = alias
        self.title = title ?? alias
        self.status = .running
    }
}

struct Session: Identifiable, Equatable {
    let id = UUID()
    var panes: [Pane]
    var split: SplitDirection?
    var activePaneID: UUID?
    let openedAt: Date

    init(alias: String, openedAt: Date = Date()) {
        let pane = Pane(alias: alias)
        self.panes = [pane]
        self.split = nil
        self.activePaneID = pane.id
        self.openedAt = openedAt
    }

    var primaryAlias: String { panes.first?.alias ?? "" }

    var displayTitle: String {
        if let activeID = activePaneID,
           let pane = panes.first(where: { $0.id == activeID }) {
            return pane.title
        }
        return panes.first?.title ?? ""
    }

    var anyRunning: Bool {
        panes.contains { $0.status.isRunning }
    }
}
