import Foundation
import Observation

/// 全局传输队列。串行跑：同时只有一个 task 处于 .running。
/// 每个 task 内部按 localItems 顺序串行 scp 一个 item。
@Observable
@MainActor
final class TransferEngine {
    /// 所有 task（pending / running / 已完成 / 失败 / 取消），按 createdAt 升序。
    private(set) var tasks: [TransferTask] = []

    /// 是否有 running task；UI 工具栏按钮的微进度条 / badge 用。
    var activeCount: Int { tasks.filter { $0.status.isRunning }.count }

    /// 进行中 task 的总进度 [0, 1]；用于工具栏按钮底部微进度条。
    /// 没有进行中任务时返回 nil。
    var aggregateProgress: Double? {
        let runners = tasks.filter { $0.status.isRunning }
        guard !runners.isEmpty else { return nil }
        let total = runners.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done = runners.reduce(Int64(0)) { $0 + $1.transferredBytes }
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    /// 当前正在跑的 task（如果有）。
    private var currentProcess: ScpProcess?

    /// 入队一次上传。立即返回，后台串行处理。
    /// items 已知道每个 size（由调用方在 enqueue 前 stat 算 totalBytes）。
    @discardableResult
    func enqueue(items: [URL], to alias: String, remoteDir: String, totalBytes: Int64) -> TransferTask {
        let task = TransferTask(
            alias: alias,
            localItems: items,
            remoteDir: remoteDir,
            totalBytes: totalBytes
        )
        tasks.append(task)
        kickRunLoop()
        return task
    }

    /// 取消一个 task：
    /// - pending → 直接转 cancelled
    /// - running → SIGTERM scp，currentProcess 的 terminationHandler 会拉回 cancelled
    /// - 已终态 → no-op
    func cancel(_ taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        switch tasks[idx].status {
        case .pending:
            tasks[idx].status = .cancelled
            tasks[idx].endedAt = Date()
        case .running:
            currentProcess?.cancel()
            // 状态由 runItem 的 outcome 回调写入
        case .succeeded, .failed, .cancelled:
            return
        }
    }

    /// 重试：把失败 / 取消的 task 重置为 pending，重新入串行队列。
    func retry(_ taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[idx].status == .failed || tasks[idx].status == .cancelled else { return }
        tasks[idx].status = .pending
        tasks[idx].transferredBytes = 0
        tasks[idx].currentItem = nil
        tasks[idx].currentSubItem = nil
        tasks[idx].currentSpeedBytesPerSec = nil
        tasks[idx].endedAt = nil
        tasks[idx].failureMessage = nil
        kickRunLoop()
    }

    /// 删除一个终态 task。
    func remove(_ taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[idx].status.isTerminal else { return }
        tasks.remove(at: idx)
    }

    /// 清掉所有终态 task。
    func clearCompleted() {
        tasks.removeAll { $0.status.isTerminal }
    }

    // MARK: - 内部串行调度

    private func kickRunLoop() {
        // 已有 running task → 串行约束 → 不动
        if tasks.contains(where: { $0.status.isRunning }) { return }
        // 找下一个 pending
        guard let nextIdx = tasks.firstIndex(where: { $0.status == .pending }) else { return }
        tasks[nextIdx].status = .running
        let taskID = tasks[nextIdx].id
        // 启动第 0 个 item
        runItem(taskID: taskID, itemIdx: 0)
    }

    private func runItem(taskID: UUID, itemIdx: Int) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let task = tasks[idx]
        guard itemIdx < task.localItems.count else {
            // 所有 item 都传完了 → succeeded
            tasks[idx].status = .succeeded
            tasks[idx].endedAt = Date()
            tasks[idx].currentItem = nil
            currentProcess = nil
            kickRunLoop()
            return
        }

        let item = task.localItems[itemIdx]
        // 当前 item 启动前的累计字节数（== 前序 item 已完成的字节数累加）
        let baseBytes = tasks[idx].transferredBytes
        // 当前 item 的总大小（目录递归算）；用于把 progress 百分比换算成字节
        let itemSize = Self.bytesOf(item)
        tasks[idx].currentItem = item

        let proc = ScpProcess()
        currentProcess = proc
        proc.start(
            alias: task.alias,
            localItem: item,
            remoteDir: task.remoteDir,
            onProgress: { [weak self] update in
                Task { @MainActor in
                    self?.applyProgress(
                        taskID: taskID,
                        baseBytes: baseBytes,
                        itemSize: itemSize,
                        update: update
                    )
                }
            },
            onCompletion: { [weak self] outcome in
                Task { @MainActor in
                    self?.handleItemOutcome(
                        taskID: taskID,
                        itemIdx: itemIdx,
                        item: item,
                        baseBytes: baseBytes,
                        itemSize: itemSize,
                        outcome: outcome
                    )
                }
            }
        )
    }

    /// 实时进度：update.absoluteBytes = 本次 scp 调用累计已传字节数（ScpProcess 内已做跨文件单调累加）。
    /// 覆盖式更新 transferredBytes。clamp 到 itemSize 防超出 100%；同时写入 subItem / speed 字段。
    private func applyProgress(taskID: UUID, baseBytes: Int64, itemSize: Int64, update: ScpProcess.ProgressUpdate) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[idx].status == .running else { return }
        let clamped = max(0, min(itemSize, update.absoluteBytes))
        tasks[idx].transferredBytes = baseBytes + clamped
        tasks[idx].currentSubItem = update.currentSubItem
        if let speed = update.speedBytesPerSec {
            tasks[idx].currentSpeedBytesPerSec = speed
        }
    }

    private func handleItemOutcome(
        taskID: UUID,
        itemIdx: Int,
        item: URL,
        baseBytes: Int64,
        itemSize: Int64,
        outcome: ScpProcess.RunOutcome
    ) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        // 每个 item 结束都清掉 sub/speed —— 下一 item 启动时由 ScpProcess 的第一帧再填
        tasks[idx].currentSubItem = nil
        tasks[idx].currentSpeedBytesPerSec = nil
        switch outcome {
        case .success:
            // 兜底拨到 100%：progress 可能没刷到最后一帧
            tasks[idx].transferredBytes = baseBytes + itemSize
            runItem(taskID: taskID, itemIdx: itemIdx + 1)
        case .failure(let message):
            tasks[idx].status = .failed
            tasks[idx].failureMessage = message
            tasks[idx].endedAt = Date()
            tasks[idx].currentItem = nil
            currentProcess = nil
            kickRunLoop()
        case .cancelled:
            tasks[idx].status = .cancelled
            tasks[idx].endedAt = Date()
            tasks[idx].currentItem = nil
            currentProcess = nil
            kickRunLoop()
        }
    }

    // MARK: - 工具

    /// 文件大小 / 目录递归大小。Bool 取的是 allocatedSize。
    /// 失败返回 0，进度可能略微不准但不阻塞流程。
    static func bytesOf(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? 0
        }
        // 目录：递归累加
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                   let size = values.totalFileAllocatedSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    /// 一组 URL 的总字节数 = 每个 bytesOf 之和。enqueue 前调用。
    static func totalBytes(of urls: [URL]) -> Int64 {
        urls.reduce(0) { $0 + bytesOf($1) }
    }
}
