import SwiftUI

/// FocusedValues 注入 UpdateCoordinator，让 Commands 能拿到当前 scene 的实例。
struct FocusedUpdateCoordinatorKey: FocusedValueKey {
    typealias Value = UpdateCoordinator
}

extension FocusedValues {
    var updateCoordinator: UpdateCoordinator? {
        get { self[FocusedUpdateCoordinatorKey.self] }
        set { self[FocusedUpdateCoordinatorKey.self] = newValue }
    }
}

/// App menu 的"检查更新…"，放在"关于 SSHKeeper"下方（macOS 标准位置）。
struct UpdateCommands: Commands {
    @FocusedValue(\.updateCoordinator) private var coordinator: UpdateCoordinator?

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                guard let coordinator else { return }
                Task { await coordinator.checkManually() }
            }
            .disabled(coordinator == nil)
        }
    }
}
