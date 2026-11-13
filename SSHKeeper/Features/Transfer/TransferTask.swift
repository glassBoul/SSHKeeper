import Foundation

/// 单个传输任务的状态。
enum TransferStatus: Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed       // 详情在 task.failureMessage
    case cancelled

    var isRunning: Bool { self == .running }
    var isTerminal: Bool {
        self == .succeeded || self == .failed || self == .cancelled
    }
}

/// 一次"上传操作"对应一个 TransferTask：用户一次拖拽 / 一次 ⌘⇧U 选文件 = 一个 task。
/// task 内部按 `localItems` 顺序串行调 scp，每个 item 完成后增加 transferredBytes。
struct TransferTask: Identifiable, Equatable, Sendable {
    let id: UUID
    let alias: String
    /// 用户提交的所有本地项（含文件和顶层目录；目录由 scp -r 递归）。
    let localItems: [URL]
    let remoteDir: String
    /// enqueue 时算出来的预算（含目录递归 stat）。
    let totalBytes: Int64
    /// 当前已传字节（== 已完成 item 的 size 累加）。
    var transferredBytes: Int64
    /// 正在传的具体顶层 item；nil = 还没开始 / 已结束。
    var currentItem: URL?
    /// scp 报告的当前**子文件**相对路径（目录递归时）。单文件时 = 文件名。
    var currentSubItem: String?
    /// scp 报告的瞬时速度（bytes/sec）；nil = 暂未拿到。
    var currentSpeedBytesPerSec: Int64?
    var status: TransferStatus
    let createdAt: Date
    var endedAt: Date?
    /// 失败时 scp 的 stderr 末 N 行。
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        alias: String,
        localItems: [URL],
        remoteDir: String,
        totalBytes: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.alias = alias
        self.localItems = localItems
        self.remoteDir = remoteDir
        self.totalBytes = totalBytes
        self.transferredBytes = 0
        self.currentItem = nil
        self.currentSubItem = nil
        self.currentSpeedBytesPerSec = nil
        self.status = .pending
        self.createdAt = createdAt
        self.endedAt = nil
        self.failureMessage = nil
    }

    /// scp 失败时把原始 stderr 翻译成更人话的中文摘要；其他情况返回原文。
    var localizedFailureMessage: String? {
        guard let raw = failureMessage else { return nil }
        if raw.contains("Host key verification failed") {
            return "主机密钥校验失败（known_hosts 未信任）。请先用终端 ssh 一次接受指纹。"
        }
        if raw.contains("Permission denied") {
            return "权限拒绝。检查密码、密钥或目标目录写权限。"
        }
        if raw.contains("No such file or directory") {
            return "远端目录不存在：\(remoteDir)"
        }
        if raw.contains("Connection refused") || raw.contains("Connection timed out") {
            return "连接被拒 / 超时。检查主机是否可达。"
        }
        return raw
    }
}
