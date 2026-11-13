import SwiftUI

struct FocusedSessionEngineKey: FocusedValueKey {
    typealias Value = SessionEngine
}

extension FocusedValues {
    var sessionEngine: SessionEngine? {
        get { self[FocusedSessionEngineKey.self] }
        set { self[FocusedSessionEngineKey.self] = newValue }
    }
}

struct SessionCommands: Commands {
    @FocusedValue(\.sessionEngine) private var engine: SessionEngine?

    var body: some Commands {
        CommandMenu("会话") {
            Button("纵向分屏") {
                engine?.splitActiveSession(.vertical)
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!canSplit)

            Button("横向分屏") {
                engine?.splitActiveSession(.horizontal)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!canSplit)

            Divider()

            Button("关闭当前 pane") {
                guard let engine,
                      let session = engine.activeSession,
                      let paneID = session.activePaneID else { return }
                engine.closePane(sessionID: session.id, paneID: paneID)
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(engine?.activeSession == nil)

            Button("关闭标签") {
                guard let engine, let id = engine.activeSessionID else { return }
                engine.closeSession(id: id)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(engine?.activeSessionID == nil)
        }
    }

    private var canSplit: Bool {
        guard let session = engine?.activeSession else { return false }
        return session.panes.count < 2
    }
}
