import Foundation
import Darwin

public enum SSHTunnelError: Error, LocalizedError {
    case localPortAllocationFailed(String)
    case sshLaunchFailed(String)
    case timeout(stderr: String)
    case sshExitedEarly(stderr: String)

    public var errorDescription: String? {
        switch self {
        case .localPortAllocationFailed(let m): "本地端口分配失败：\(m)"
        case .sshLaunchFailed(let m): "启动 ssh 进程失败：\(m)"
        case .timeout(let s):
            "SSH 隧道 10s 内未就绪。可能是认证失败或网络不通。\nssh stderr:\n\(s.isEmpty ? "(空)" : s)"
        case .sshExitedEarly(let s):
            "ssh 提前退出。\nssh stderr:\n\(s.isEmpty ? "(空)" : s)"
        }
    }
}

/// 通过本机 OpenSSH 二进制建立到目标主机的本地端口转发隧道。复用 `~/.ssh/config`
/// 里的 Host 配置（认证方式、私钥、ProxyJump 等），相当于 `ssh -N -L lport:targetHost:targetPort alias`。
///
/// 设计取舍：
/// - 用 OpenSSH 子进程而非 SwiftNIOSSH，省去复刻 ssh-agent / 私钥密码 / Match block 等行为
/// - 每个 DatabaseClient 实例独占一条 tunnel；不做 tunnel 复用，避免 lifecycle 复杂
/// - waitForPort 用 TCP probe（ssh -L 在认证完成前不 bind 本地端口，能可靠判定就绪）
public actor SSHTunnel {
    public let sshHostAlias: String
    public let targetHost: String
    public let targetPort: Int
    public private(set) var localPort: Int?

    private var process: Process?
    private var stderrPipe: Pipe?

    public init(sshHostAlias: String, targetHost: String, targetPort: Int) {
        self.sshHostAlias = sshHostAlias
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    public func start(timeoutSeconds: Double = 10) async throws {
        let port = try Self.findFreeLocalPort()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-N",                                         // 不在远端执行命令
            "-T",                                         // 不分配 pty
            "-o", "ExitOnForwardFailure=yes",             // 转发失败即退出
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=2",
            "-o", "ConnectTimeout=10",
            "-L", "127.0.0.1:\(port):\(targetHost):\(targetPort)",
            sshHostAlias
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            throw SSHTunnelError.sshLaunchFailed(error.localizedDescription)
        }
        self.process = proc
        self.stderrPipe = errPipe

        // 轮询本地端口可连接 — ssh 会在认证 + 转发都就绪后才 bind。
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !proc.isRunning {
                let stderr = readStderrAvailable()
                throw SSHTunnelError.sshExitedEarly(stderr: stderr)
            }
            if Self.probeConnect(port: port) {
                self.localPort = port
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let stderr = readStderrAvailable()
        proc.terminate()
        self.process = nil
        throw SSHTunnelError.timeout(stderr: stderr)
    }

    public func stop() {
        if let proc = process, proc.isRunning {
            proc.terminate()
            // 给 ssh 一点时间清理；超过 1s 强杀
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
        process = nil
        stderrPipe = nil
        localPort = nil
    }

    private func readStderrAvailable() -> String {
        guard let pipe = stderrPipe else { return "" }
        let data = pipe.fileHandleForReading.availableData
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Helpers

    /// 让内核分配一个空闲端口（bind 0 → getsockname → close）。
    /// 关闭后到 ssh 重新 bind 之间存在 ~ms 级竞态窗口；macOS 单机基本不会撞上。
    static func findFreeLocalPort() throws -> Int {
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else {
            throw SSHTunnelError.localPortAllocationFailed("socket() 返回 \(errno)")
        }
        defer { Darwin.close(s) }

        // SO_REUSEADDR 不是必须，只在快速重启场景下避免 TIME_WAIT 占用
        var reuse: Int32 = 1
        _ = Darwin.setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0  // kernel 选

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(s, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw SSHTunnelError.localPortAllocationFailed("bind() 失败 errno=\(errno)")
        }

        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(s, sockaddrPtr, &len)
            }
        }
        guard nameResult == 0 else {
            throw SSHTunnelError.localPortAllocationFailed("getsockname() 失败 errno=\(errno)")
        }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    static func probeConnect(port: Int) -> Bool {
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { Darwin.close(s) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        let r = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(s, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }
}
