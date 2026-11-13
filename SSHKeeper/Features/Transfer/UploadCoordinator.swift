import SwiftUI
import AppKit
import Observation

/// 三入口（拖拽 / ⌘⇧U / 未来扩展）的收口。
/// 状态机：idle → showingSheet(alias, items, remoteDir) → 上传 → idle。
/// 由 MainView 注入 environment，SSHTerminalView 的拖拽 / UploadCommands 的 ⌘⇧U 都调它。
@Observable
@MainActor
final class UploadCoordinator {
    private let engine: TransferEngine
    /// 当前要弹的 sheet 内容；nil = 不弹。
    var pendingPrompt: Prompt?

    struct Prompt: Identifiable, Equatable {
        let id = UUID()
        let alias: String
        let items: [URL]
        var remoteDir: String
    }

    init(engine: TransferEngine) {
        self.engine = engine
    }

    /// 拖拽入口：alias + 已抽出的 fileURLs。
    func beginUpload(alias: String, items: [URL]) {
        guard !items.isEmpty else { return }
        let initialPath = UploadDestinationMemory.get(alias: alias)
        pendingPrompt = Prompt(alias: alias, items: items, remoteDir: initialPath)
    }

    /// ⌘⇧U 入口：弹 NSOpenPanel 选文件后走 beginUpload。
    /// alias 由 caller 提供（active session 的 active pane alias）。
    func beginUploadForActiveSession(alias: String?) {
        guard let alias else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要上传的文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        beginUpload(alias: alias, items: urls)
    }

    /// Sheet 内"上传"按钮：把当前 prompt 入队 TransferEngine。
    func submitPendingPrompt() {
        guard let prompt = pendingPrompt else { return }
        let trimmedDir = prompt.remoteDir.trimmingCharacters(in: .whitespaces)
        guard !trimmedDir.isEmpty else { return }
        UploadDestinationMemory.set(alias: prompt.alias, path: trimmedDir)
        let total = TransferEngine.totalBytes(of: prompt.items)
        engine.enqueue(items: prompt.items, to: prompt.alias, remoteDir: trimmedDir, totalBytes: total)
        pendingPrompt = nil
    }

    /// Sheet 内"取消"按钮 / Esc。
    func cancelPendingPrompt() {
        pendingPrompt = nil
    }
}
