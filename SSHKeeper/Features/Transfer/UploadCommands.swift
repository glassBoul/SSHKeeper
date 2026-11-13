import SwiftUI

/// 给 App.body.commands { } 注册的 ⌘⇧U 上传命令。
/// 通过 focusedSceneValue 拿当前窗口的 SessionEngine + UploadCoordinator。
struct FocusedUploadCoordinatorKey: FocusedValueKey {
    typealias Value = UploadCoordinator
}

extension FocusedValues {
    var uploadCoordinator: UploadCoordinator? {
        get { self[FocusedUploadCoordinatorKey.self] }
        set { self[FocusedUploadCoordinatorKey.self] = newValue }
    }
}

struct UploadCommands: Commands {
    @FocusedValue(\.sessionEngine) private var sessionEngine: SessionEngine?
    @FocusedValue(\.uploadCoordinator) private var coordinator: UploadCoordinator?

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("上传文件到当前主机…") {
                let alias = activeAlias()
                coordinator?.beginUploadForActiveSession(alias: alias)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(activeAlias() == nil || coordinator == nil)
        }
    }

    /// active session 的 active pane 的 alias；找不到返回 nil → 命令 disabled。
    private func activeAlias() -> String? {
        guard let session = sessionEngine?.activeSession,
              let paneID = session.activePaneID,
              let pane = session.panes.first(where: { $0.id == paneID }) else {
            return nil
        }
        return pane.alias
    }
}
