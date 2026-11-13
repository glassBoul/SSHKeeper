import Foundation
import NIOPosix

/// 跨 MySQL / Postgres client 共享的 NIO event loop group。
///
/// 旧实现里两个 client 各持有 `numberOfThreads: 1` 的私有 ELG，意味着：
/// - 多个数据库窗口同时跑查询会在同一个线程上排队
/// - App 退出时没人 shutdown，NIO 线程作为系统资源轻微泄漏
///
/// 共用一组 4 线程足够支撑常见多窗口场景，且 App 退出时 `shutdown()` 收尾。
public enum DatabaseEventLoopGroup {
    public static let shared: MultiThreadedEventLoopGroup = {
        MultiThreadedEventLoopGroup(numberOfThreads: 4)
    }()

    /// App 退出钩子使用：尝试在 timeout 内 graceful shutdown。
    /// 仍有活跃连接时会等连接关闭；超时返回让 OS 兜底回收。
    public static func shutdown(timeout: TimeInterval = 3) {
        let semaphore = DispatchSemaphore(value: 0)
        shared.shutdownGracefully(queue: .global()) { _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }
}
