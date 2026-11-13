import Foundation
import Observation
import SSHKeeperCore

enum DatabaseWorkspaceError: LocalizedError {
    case tooManyTabs(limit: Int)

    var errorDescription: String? {
        switch self {
        case .tooManyTabs(let limit):
            "已打开的数据库标签数达到上限（\(limit)），请先关掉一些再开新的。"
        }
    }
}

/// 跨窗口共享的「数据库工作台」状态。
///
/// 一个 App 进程只有一个工作台窗口，但工作台里可以同时打开多个 DB session
/// （顶部 tab 切换）。这个类在 App 级 @State 里持有，所以即便工作台窗口被
/// 关闭再重开，它仍然存活 — 但 `disconnectAll` 会在窗口 onDisappear 时被调，
/// 关掉所有连接并清空 sessions（避免 NIO 连接泄漏）。
@Observable
@MainActor
final class DatabaseWorkspace {
    /// 每个 DB 连接都吃一条 NIO channel + 服务端连接 + 内存里 inspector 缓存，
    /// 太多并存的 session 不仅占资源还让用户找不到 tab。20 是经验上限。
    static let maxTabs = 20

    /// 已打开的 sessions，顺序 = tab 显示顺序。
    private(set) var sessions: [DatabaseSession] = []

    /// 当前激活的 session（用 database.id 作为 key —— UUID 全局唯一，方便 tab 选中）。
    var activeSessionID: UUID?

    var activeSession: DatabaseSession? {
        guard let id = activeSessionID else { return nil }
        return sessions.first { $0.database.id == id }
    }

    /// 打开一个 DB。若已在 tab 列表里 → 直接激活；否则新建 session + 连接 + 激活。
    /// 超过 maxTabs 抛 `DatabaseWorkspaceError.tooManyTabs`。
    /// 调用方需保证 `databaseStore.database(id:)` 不为 nil 且 Keychain 有密码（UI 端已 disable 按钮兜底）。
    func open(databaseID: UUID, in store: DatabaseStore) async throws {
        if sessions.contains(where: { $0.database.id == databaseID }) {
            activeSessionID = databaseID
            return
        }
        if sessions.count >= Self.maxTabs {
            throw DatabaseWorkspaceError.tooManyTabs(limit: Self.maxTabs)
        }
        guard let database = store.database(id: databaseID) else { return }
        let alias = "db:\(database.id.uuidString)"
        guard let password = PasswordKeychain.read(alias: alias) else { return }
        let session = DatabaseSession(database: database, password: password)
        sessions.append(session)
        activeSessionID = databaseID
        await session.connect()
    }

    /// 关掉某个 tab。disconnect 走 detached Task，避免 NIO connection deinit
    /// precondition 把 App 拉崩。
    func close(databaseID: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.database.id == databaseID }) else { return }
        let removed = sessions.remove(at: idx)
        if activeSessionID == databaseID {
            // 优先选 idx 位置上的（剩下的第 idx 个），否则前一个；都没有则 nil
            if idx < sessions.count {
                activeSessionID = sessions[idx].database.id
            } else if let last = sessions.last {
                activeSessionID = last.database.id
            } else {
                activeSessionID = nil
            }
        }
        Task.detached(priority: .background) {
            await removed.disconnect()
        }
    }

    func setActive(_ databaseID: UUID) {
        guard sessions.contains(where: { $0.database.id == databaseID }) else { return }
        activeSessionID = databaseID
    }

    /// 工作台窗口关闭时调。并行等待所有 session disconnect — 5 个连接不再是 5×单连接耗时。
    /// 每个 session 是独立 NIO 连接，没有共享可变状态，并行安全。
    func disconnectAll() async {
        let toClose = sessions
        sessions.removeAll()
        activeSessionID = nil
        await withTaskGroup(of: Void.self) { group in
            for session in toClose {
                group.addTask { await session.disconnect() }
            }
        }
    }
}
