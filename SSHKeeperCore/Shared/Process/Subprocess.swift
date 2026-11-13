import Foundation

public struct SubprocessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var isSuccess: Bool { exitCode == 0 }
}

public enum SubprocessError: Error {
    case launchFailed(String)
}

public enum Subprocess {
    /// Run an executable and capture stdout/stderr/exit code. Optionally pipe `stdin`.
    ///
    /// stdout 与 stderr 用 readabilityHandler 在后台并发收集 —— 避免老写法（先把
    /// stdout 读到 EOF 再读 stderr）在子进程往 stderr 写满 PIPE_BUF (~64KB) 时
    /// 死锁：stderr 写阻塞 → 子进程不退出 → stdout 永远等不到 EOF。
    @discardableResult
    public static func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        stdin: String? = nil
    ) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe?
        if stdin != nil {
            inPipe = Pipe()
            process.standardInput = inPipe
        } else {
            inPipe = nil
            process.standardInput = FileHandle.nullDevice
        }

        let collector = OutputCollector()
        collector.attach(pipe: outPipe, channel: .stdout)
        collector.attach(pipe: errPipe, channel: .stderr)

        do {
            try process.run()
        } catch {
            collector.detach()
            throw SubprocessError.launchFailed(error.localizedDescription)
        }

        if let stdin, let inPipe {
            if let data = stdin.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(data)
            }
            try? inPipe.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        // 子进程已退出，但 readabilityHandler 还可能在排队写最后一段；
        // 等两条 channel 都收到 EOF (availableData == empty) 才安全读 buffer。
        collector.waitForEOF()

        let (outData, errData) = collector.snapshot()
        return SubprocessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

private final class OutputCollector: @unchecked Sendable {
    enum Channel { case stdout, stderr }

    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private let group = DispatchGroup()
    private var attachedHandles: [FileHandle] = []

    func attach(pipe: Pipe, channel: Channel) {
        let handle = pipe.fileHandleForReading
        lock.lock()
        attachedHandles.append(handle)
        lock.unlock()
        group.enter()
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF：解除 handler，避免被反复回调；只 leave 一次。
                handle.readabilityHandler = nil
                self.group.leave()
                return
            }
            self.lock.lock()
            switch channel {
            case .stdout: self.stdoutData.append(chunk)
            case .stderr: self.stderrData.append(chunk)
            }
            self.lock.unlock()
        }
    }

    /// 启动失败时调用，确保 handler 被清理、计数器归零。
    func detach() {
        lock.lock()
        let handles = attachedHandles
        attachedHandles = []
        lock.unlock()
        for handle in handles {
            if handle.readabilityHandler != nil {
                handle.readabilityHandler = nil
                group.leave()
            }
        }
    }

    func waitForEOF() {
        group.wait()
    }

    func snapshot() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdoutData, stderrData)
    }
}
