import Foundation
import Observation

public enum PanelWorkspaceError: LocalizedError {
    case tooManyTabs(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .tooManyTabs(let limit):
            "已打开的面板标签数达到上限（\(limit)），请先关掉一些再开新的。"
        }
    }
}

/// 跨窗口共享的「面板工作台」状态。
///
/// 与 DatabaseWorkspace 不同，面板没有独立的 session 对象 —— WKWebView 由
/// `PanelLoginContainer` 的内部 View 树持有。所以这里只存 `panelIDs` 顺序列表，
/// PanelWorkspaceView 用 ZStack 同时挂载所有 ID 对应的 container，opacity 切换可见。
/// 关闭某个 tab → 从列表移除 → ZStack 对应 View 析构 → WKWebView 释放。
@Observable
@MainActor
public final class PanelWorkspace {
    /// 面板用 ZStack 全部挂载 → 每个 tab 一个常驻 WKWebView（数十 MB / 个）。
    /// 比 DB 内存敏感得多，上限砍到 12。
    public static let maxTabs = 12

    /// 已打开的面板 ID，顺序即 tab 显示顺序。
    public private(set) var panelIDs: [UUID] = []

    /// 当前激活的面板。
    public var activePanelID: UUID?

    public init() {}

    public func contains(_ panelID: UUID) -> Bool {
        panelIDs.contains(panelID)
    }

    /// 打开面板。已在列表里 → 仅激活；否则追加 + 激活。
    /// 超过 maxTabs 抛 `PanelWorkspaceError.tooManyTabs`。
    public func open(panelID: UUID) throws {
        if panelIDs.contains(panelID) {
            activePanelID = panelID
            return
        }
        if panelIDs.count >= Self.maxTabs {
            throw PanelWorkspaceError.tooManyTabs(limit: Self.maxTabs)
        }
        panelIDs.append(panelID)
        activePanelID = panelID
    }

    /// 关掉某个 tab。激活态会迁到相邻 tab；空则 nil。
    public func close(panelID: UUID) {
        guard let idx = panelIDs.firstIndex(of: panelID) else { return }
        panelIDs.remove(at: idx)
        if activePanelID == panelID {
            if idx < panelIDs.count {
                activePanelID = panelIDs[idx]
            } else if let last = panelIDs.last {
                activePanelID = last
            } else {
                activePanelID = nil
            }
        }
    }

    public func setActive(_ panelID: UUID) {
        guard panelIDs.contains(panelID) else { return }
        activePanelID = panelID
    }

    /// 工作台窗口关闭时调。直接清空 — WKWebView 由 View 树析构释放，无需额外动作。
    /// 不清空的话再次打开会鬼复活之前的 tab 并重新登录，与用户「关了就关了」预期不符。
    public func closeAll() {
        panelIDs.removeAll()
        activePanelID = nil
    }
}
