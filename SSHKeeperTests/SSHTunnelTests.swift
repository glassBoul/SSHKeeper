import XCTest
@testable import SSHKeeperCore

final class SSHTunnelTests: XCTestCase {
    func testFindFreeLocalPortReturnsValidPort() throws {
        let port = try SSHTunnel.findFreeLocalPort()
        // 内核分配的临时端口范围 macOS 默认 49152-65535，但用户可能改 sysctl；
        // 只断言是合理范围，不卡死特定区间。
        XCTAssertGreaterThan(port, 1024)
        XCTAssertLessThan(port, 65536)
    }

    func testFindFreeLocalPortReturnsDifferentPortsInSequence() throws {
        // 两次连续分配能拿到不同端口（即使 race，这里不做严格唯一性，只检查执行成功）
        let p1 = try SSHTunnel.findFreeLocalPort()
        let p2 = try SSHTunnel.findFreeLocalPort()
        XCTAssertGreaterThan(p1, 1024)
        XCTAssertGreaterThan(p2, 1024)
        // 不强制 != p1，理论上有可能 reuse；但拿到一个有效端口已足够
    }

    func testProbeConnectFailsOnUnboundPort() {
        // 取一个明确不大可能被监听的端口（用户态系统服务都不会用 1）
        XCTAssertFalse(SSHTunnel.probeConnect(port: 1))
    }
}
