import SwiftUI
import AppKit
import SSHKeeperCore

/// 关掉最后一个窗口时让 App 留着（Mac 惯例：邮件 / 备忘录 都这样），
/// 用户可以从菜单栏图标或 dock 重新呼出主窗口。
@MainActor
final class SSHKeeperAppDelegate: NSObject, NSApplicationDelegate {
    weak var sidecar: SidecarController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点 dock 图标 / 双击 App 时，如果没窗口就开主窗口
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前同步落盘 pending 的 sidecar 写入；正常情况下 debounce 已写完，
        // 极端情况下（用户连续操作后立即 cmd+Q）这里兜底，避免丢失最近 mutate。
        // 退出路径无处展示错误，吞掉异常即可：lastFlushError 已被 controller 内部记录。
        try? sidecar?.flushNowSync()
        // 关闭 NIO 共享线程池，把数据库连接的 channel 全部清理。
        // 给 3s 让活跃 query 自然结束，超时后 OS 兜底回收。
        DatabaseEventLoopGroup.shutdown()
    }
}

struct SSHKeeperApp: App {
    @NSApplicationDelegateAdaptor(SSHKeeperAppDelegate.self) private var appDelegate

    @State private var sidecar: SidecarController
    @State private var store: HostStore
    @State private var sessionEngine: SessionEngine = SessionEngine()
    @State private var transferEngine: TransferEngine = TransferEngine()
    @State private var uploadCoordinator: UploadCoordinator
    @State private var updateCoordinator: UpdateCoordinator = UpdateCoordinator()
    @State private var panelStore: PanelStore
    @State private var databaseStore: DatabaseStore
    @State private var databaseWorkspace: DatabaseWorkspace = DatabaseWorkspace()
    @State private var panelWorkspace: PanelWorkspace = PanelWorkspace()

    init() {
        // 共享同一个 SidecarController，三个 Store 通过它串行化对 metadata.json
        // 的 read-modify-write，避免互相覆盖。
        let shared = SidecarController()
        _sidecar = State(initialValue: shared)
        _store = State(initialValue: HostStore(sidecar: shared))
        _panelStore = State(initialValue: PanelStore(sidecar: shared))
        _databaseStore = State(initialValue: DatabaseStore(sidecar: shared))
        let initialEngine = TransferEngine()
        _transferEngine = State(initialValue: initialEngine)
        _uploadCoordinator = State(initialValue: UploadCoordinator(engine: initialEngine))
    }

    var body: some Scene {
        WindowGroup("SSHKeeper") {
            MainView()
                .environment(store)
                .environment(sessionEngine)
                .environment(panelStore)
                .environment(databaseStore)
                .environment(databaseWorkspace)
                .environment(panelWorkspace)
                .environment(sidecar)
                .environment(transferEngine)
                .environment(uploadCoordinator)
                .environment(updateCoordinator)
                .focusedSceneValue(\.sessionEngine, sessionEngine)
                .focusedSceneValue(\.uploadCoordinator, uploadCoordinator)
                .focusedSceneValue(\.updateCoordinator, updateCoordinator)
                .task {
                    appDelegate.sidecar = sidecar
                    store.load()
                    panelStore.load()
                    databaseStore.load()
                    Task { await updateCoordinator.checkOnLaunch() }
                }
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            SessionCommands()
            UploadCommands()
            UpdateCommands()
        }

        // 单一「面板工作台」窗口：所有面板都在这个窗口的 tab 里，切 tab 时 WKWebView 不重建。
        Window("面板工作台", id: "panel-workspace") {
            PanelWorkspaceView()
                .environment(panelStore)
                .environment(panelWorkspace)
        }

        // 单一「数据库工作台」窗口：所有 DB 都在这个窗口的 tab 里。
        // 必须用 `Window`（singleton）而不是 `WindowGroup`（每次 open 会再开新窗口）。
        Window("数据库工作台", id: "db-workspace") {
            DatabaseWorkspaceView()
                .environment(databaseStore)
                .environment(databaseWorkspace)
        }

        MenuBarExtra("SSHKeeper", systemImage: "terminal") {
            MenuBarExtraView(store: store, engine: sessionEngine)
        }
        .menuBarExtraStyle(.window)
    }
}
