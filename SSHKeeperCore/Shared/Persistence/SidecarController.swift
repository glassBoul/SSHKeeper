import Foundation
import Observation

public enum SidecarControllerError: Error {
    case flushTimeout
    case flushFailed(String)

    public var localizedDescription: String {
        switch self {
        case .flushTimeout: return "metadata.json 写入超时"
        case .flushFailed(let reason): return "metadata.json 写入失败：\(reason)"
        }
    }
}

/// 共享的 metadata.json 内存视图。三个 Store（Host / Panel / Database）通过它
/// 串行化 read-modify-write，避免各自独立 load → mutate → save 互相覆写。
///
/// 设计要点：
/// - 内存视图永远在 main actor，UI 与 Store 同步可见。
/// - 落盘 debounce（默认 150ms），把高频写（如 lastUsedAt 的 touch）合并成一次磁盘 I/O。
/// - 实际写盘走专属 actor，绝不阻塞主线程；多次落盘也按调用顺序串行执行，
///   保证最后一次 mutate 一定胜出。
/// - App 退出时调用 `flushNowSync()` 阻塞等到 pending 写完成，避免丢失未刷的数据。
/// - `mutateAndFlush` 是事务路径：内存改动 + 同步落盘原子化，失败回滚内存。
@Observable
@MainActor
public final class SidecarController {
    public private(set) var payload: SidecarPayload
    public private(set) var lastFlushError: String?

    private let executor: FlushExecutor
    private let debounceNanos: UInt64
    private var pendingFlush: Task<Void, Never>?

    public init(
        store: SidecarStore = SidecarStore(fileURL: SidecarStore.defaultLocation()),
        debounceMillis: UInt64 = 150
    ) {
        self.executor = FlushExecutor(store: store)
        self.debounceNanos = debounceMillis * 1_000_000
        do {
            self.payload = try store.load()
        } catch {
            self.payload = SidecarPayload()
            self.lastFlushError = "metadata.json 读取失败：\(error.localizedDescription)"
        }
    }

    /// 改内存视图。同步生效，磁盘落盘 debounce 后异步执行。失败由 `lastFlushError` 暴露。
    public func mutate(_ block: (inout SidecarPayload) -> Void) {
        block(&payload)
        scheduleFlush()
    }

    /// 事务式 mutate：改内存 + 同步等待落盘。失败时回滚内存到 mutate 前并 throw。
    /// 用于 HostStore.persist 这类"必须保证 metadata 与外部状态一致"的场景。
    public func mutateAndFlush(
        timeout: TimeInterval = 5,
        _ block: (inout SidecarPayload) -> Void
    ) throws {
        let snapshot = payload
        block(&payload)
        do {
            try flushNowSync(timeout: timeout)
        } catch {
            payload = snapshot
            throw error
        }
    }

    /// 阻塞等待当前 payload 落盘。失败抛出 `SidecarControllerError`。
    /// 同时同步更新 `lastFlushError`，让 UI banner 与事务调用方都能感知。
    public func flushNowSync(timeout: TimeInterval = 5) throws {
        pendingFlush?.cancel()
        let snapshot = payload
        let executor = self.executor
        let semaphore = DispatchSemaphore(value: 0)
        let holder = ErrorHolder()
        Task.detached(priority: .userInitiated) {
            do {
                try await executor.save(snapshot)
            } catch {
                holder.set(error)
            }
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            lastFlushError = SidecarControllerError.flushTimeout.localizedDescription
            throw SidecarControllerError.flushTimeout
        }
        if let error = holder.get() {
            let wrapped = SidecarControllerError.flushFailed(error.localizedDescription)
            lastFlushError = wrapped.localizedDescription
            throw wrapped
        }
        lastFlushError = nil
    }

    private func scheduleFlush() {
        pendingFlush?.cancel()
        let debounce = self.debounceNanos
        let executor = self.executor
        // Task 默认继承 MainActor 上下文；sleep 与 cancel 检查在 main，
        // executor.save 在 actor 里执行实际磁盘 I/O。
        pendingFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: debounce)
            if Task.isCancelled { return }
            guard let self else { return }
            let snapshot = self.payload
            do {
                try await executor.save(snapshot)
                self.lastFlushError = nil
            } catch {
                self.lastFlushError = "metadata.json 写入失败：\(error.localizedDescription)"
            }
        }
    }
}

/// detached task 与发起线程间传 error 的容器。semaphore.signal/wait 形成 happens-before，
/// 但 Swift 6 严格并发要求显式 Sendable，所以包成 final class + lock。
private final class ErrorHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

/// 写盘 actor：保证多次落盘串行，避免两个并发的 atomic replace 顺序错乱
/// 让旧 snapshot 覆盖新 snapshot。
private actor FlushExecutor {
    private let store: SidecarStore

    init(store: SidecarStore) {
        self.store = store
    }

    func save(_ payload: SidecarPayload) throws {
        try store.save(payload)
    }
}
