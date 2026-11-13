import Foundation
import SSHKeeperCore

/// 单次 scp 子进程调用：一次只传一个 local item（文件或目录，目录靠 -r 递归）。
/// 不持有 UI 状态；由 TransferEngine 串行调度。
///
/// 实现要点：
///   1. `/usr/bin/script -q /dev/null scp ...`：script 给 scp 分配 pty，让它打 progress meter；
///      output 都汇到 stdout。
///   2. scp -r 传目录时 progress meter 是**每个子文件单独**的（pct 会从 100 跳回 0）。
///      我们按文件名切换检测 boundary，把上一文件的"估算总大小"累加进 `completedFilesBytes`。
///      估算 = max(实际看到的最大 bytes, 用 pct 反推的 total)。
///   3. 单文件内部 bytes 单调（防 scp 输出抖动）；跨文件 boundary 主动 reset。
///   4. 上报给上层：(本次 scp 累计已传字节, 当前子文件名, 速度 bytes/s)。
final class ScpProcess: @unchecked Sendable {
    /// 子进程异步结果。
    enum RunOutcome {
        case success
        case failure(message: String)
        case cancelled
    }

    /// 实时进度回调载荷。
    struct ProgressUpdate: Sendable {
        let absoluteBytes: Int64        // 本次 scp 调用累计已传字节（含所有子文件）
        let currentSubItem: String      // 当前正在传的子文件名（相对路径或 scp 截断后的展示名）
        let speedBytesPerSec: Int64?    // scp 报告的瞬时速度；nil = 当前帧没解析出
    }

    private let process = Process()
    private let stdoutPipe = Pipe()
    private var outputBuffer = Data()
    private let outputLock = NSLock()
    private var didCancel = false

    /// 进度解析状态。readabilityHandler 在 NSConcreteFileHandle 的 fileHandleDelegate queue 上串行回调，
    /// 同一时刻只有一个 handler 实例在跑，所以这些字段不加锁也安全。
    private var lastFilename: String?
    private var completedFilesBytes: Int64 = 0
    private var currentFileBytes: Int64 = 0
    private var currentFileEstimatedTotal: Int64 = 0
    private var lastSpeed: Int64?

    /// 启动 scp 进程。回调可能在任意线程；调用方负责 hop 到 MainActor。
    func start(
        alias: String,
        localItem: URL,
        remoteDir: String,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void,
        onCompletion: @escaping @Sendable (RunOutcome) -> Void
    ) {
        process.launchPath = "/usr/bin/script"
        process.arguments = ["-q", "/dev/null", "/usr/bin/scp"]
            + Self.scpArgs(localItem: localItem, alias: alias, remoteDir: remoteDir)

        let env = Self.makeEnvironment(alias: alias)
        process.environment = env

        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self else { return }
            self.outputLock.lock()
            self.outputBuffer.append(data)
            self.outputLock.unlock()
            guard let chunkStr = String(data: data, encoding: .utf8) else { return }
            let events = Self.parseProgressEvents(chunkStr)
            for ev in events {
                self.applyEvent(ev)
            }
            if let name = self.lastFilename, !events.isEmpty {
                onProgress(ProgressUpdate(
                    absoluteBytes: self.completedFilesBytes + self.currentFileBytes,
                    currentSubItem: name,
                    speedBytesPerSec: self.lastSpeed
                ))
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            let remaining = self.stdoutPipe.fileHandleForReading.availableData
            if !remaining.isEmpty {
                self.outputLock.lock()
                self.outputBuffer.append(remaining)
                self.outputLock.unlock()
            }
            let outcome: RunOutcome
            if self.didCancel {
                outcome = .cancelled
            } else if proc.terminationStatus == 0 {
                outcome = .success
            } else {
                outcome = .failure(message: self.tailOutput(lines: 5))
            }
            onCompletion(outcome)
        }

        do {
            try process.run()
        } catch {
            onCompletion(.failure(message: error.localizedDescription))
        }
    }

    /// 内部：吸收一条 progress event，维护单调性 + 跨文件累加。
    private func applyEvent(_ ev: ProgressEvent) {
        if ev.filename != lastFilename {
            if lastFilename != nil {
                // 上一文件切走时，累加它的估算总大小（max 实际看到的 / pct 反推的）
                let estimated = max(currentFileBytes, currentFileEstimatedTotal)
                completedFilesBytes += estimated
            }
            lastFilename = ev.filename
            currentFileBytes = 0
            currentFileEstimatedTotal = 0
        }
        if let b = ev.bytesInCurrentFile, b > currentFileBytes {
            currentFileBytes = b
        }
        // pct >= 5% 才用反推 total（小百分比反推噪音太大）
        if ev.percent >= 5, let b = ev.bytesInCurrentFile {
            let est = Int64(Double(b) / (Double(ev.percent) / 100.0))
            if est > currentFileEstimatedTotal {
                currentFileEstimatedTotal = est
            }
        }
        if let s = ev.bytesPerSecond {
            lastSpeed = s
        }
    }

    /// 用户取消：SIGTERM；terminationHandler 会带 cancelled outcome 回调。
    func cancel() {
        didCancel = true
        if process.isRunning {
            process.terminate()
        }
    }

    /// scp argv（不含 `-q`：要让 scp 输出 progress meter）。
    /// ControlMaster/ControlPath 显式关闭，避免复用 terminal 的主连接；
    /// ServerAlive 防 NAT/服务端把传输间隙的连接关掉。
    static func scpArgs(localItem: URL, alias: String, remoteDir: String) -> [String] {
        return [
            "-r",
            "-p",
            "-O",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=15",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=4",
            "--",
            localItem.path,
            "\(alias):\(remoteDir)/"
        ]
    }

    /// 环境变量：仅当 Keychain 有该 alias 的密码时才注入 askpass env。
    static func makeEnvironment(alias: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if PasswordKeychain.has(alias: alias),
           let appExecutable = Bundle.main.executablePath {
            env["SSH_ASKPASS"] = appExecutable
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            env[AskpassMain.triggerEnvVar] = "1"
            env[AskpassMain.aliasEnvVar] = alias
        }
        return env
    }

    /// 单条 progress 解析结果。
    struct ProgressEvent: Equatable {
        let filename: String
        let bytesInCurrentFile: Int64?   // 可能解析不出（scp 输出格式异常时）
        let percent: Int
        let bytesPerSecond: Int64?
    }

    /// 解析 scp progress meter chunk。scp 用 `\r` 在同一行刷新，按 `\r`/`\n` 切。
    /// 一行结构（典型）：`<filename>    <pct>%   <size><unit>   <speed><unit>/s   <eta>`
    /// 例：`subdir/file.bin                  25%  12.5MB   5.2MB/s   00:30`
    /// 解析策略：先用 `<\d+>%` 作为锚点，再在 pct 后续 tail 中按 size/speed 正则各取一次。
    static func parseProgressEvents(_ chunk: String) -> [ProgressEvent] {
        let segments = chunk.split(omittingEmptySubsequences: true) { $0 == "\r" || $0 == "\n" }
        guard let pctRegex = try? NSRegularExpression(pattern: #"^(.+?)\s+(\d{1,3})%(.*)$"#),
              let sizeRegex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*([KMGT]?B)\b(?!/s)"#, options: .caseInsensitive),
              let speedRegex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*([KMGT]?B)/s"#, options: .caseInsensitive) else {
            return []
        }
        var events: [ProgressEvent] = []
        for seg in segments {
            let line = String(seg).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let nsRange = NSRange(line.startIndex..., in: line)
            guard let m = pctRegex.firstMatch(in: line, range: nsRange),
                  let fnR = Range(m.range(at: 1), in: line),
                  let pctR = Range(m.range(at: 2), in: line),
                  let tailR = Range(m.range(at: 3), in: line),
                  let pct = Int(line[pctR]) else { continue }
            let filename = line[fnR].trimmingCharacters(in: .whitespaces)
            let tail = String(line[tailR])

            let bytesInCurrentFile = Self.firstMatch(sizeRegex, in: tail)
                .flatMap { Self.bytesFromUnit(num: $0.num, unit: $0.unit) }
            let speed = Self.firstMatch(speedRegex, in: tail)
                .flatMap { Self.bytesFromUnit(num: $0.num, unit: $0.unit) }

            events.append(ProgressEvent(
                filename: filename,
                bytesInCurrentFile: bytesInCurrentFile,
                percent: pct,
                bytesPerSecond: speed
            ))
        }
        return events
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> (num: Double, unit: String)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range),
              let numR = Range(m.range(at: 1), in: text),
              let unitR = Range(m.range(at: 2), in: text),
              let num = Double(text[numR]) else { return nil }
        return (num, String(text[unitR]))
    }

    private static func bytesFromUnit(num: Double, unit: String) -> Int64? {
        let mult: Double
        switch unit.uppercased() {
        case "B":  mult = 1
        case "KB": mult = 1024
        case "MB": mult = 1024 * 1024
        case "GB": mult = 1024 * 1024 * 1024
        case "TB": mult = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64(num * mult)
    }

    /// 失败消息：末 N 行非 progress 行。
    private func tailOutput(lines: Int) -> String {
        outputLock.lock()
        defer { outputLock.unlock() }
        let text = String(data: outputBuffer, encoding: .utf8) ?? ""
        let allLines = text.split(omittingEmptySubsequences: true) { $0 == "\r" || $0 == "\n" }
        let nonProgress = allLines.filter { line in
            let hasPct = line.contains("%")
            let hasSpeed = line.contains("KB/s") || line.contains("MB/s") || line.contains("B/s")
            return !(hasPct && hasSpeed)
        }
        let suffix = nonProgress.suffix(lines)
        return suffix.joined(separator: "\n")
    }
}
