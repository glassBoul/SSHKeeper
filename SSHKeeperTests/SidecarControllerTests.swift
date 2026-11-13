import XCTest
@testable import SSHKeeperCore

@MainActor
final class SidecarControllerTests: XCTestCase {
    func testMutateUpdatesPayloadImmediately() throws {
        let (controller, _) = try makeController(debounceMillis: 30)
        controller.mutate { $0.groups = [HostGroup(name: "G")] }
        XCTAssertEqual(controller.payload.groups.first?.name, "G")
    }

    func testFlushNowSyncWritesToDisk() throws {
        let (controller, store) = try makeController(debounceMillis: 200)
        controller.mutate { $0.groups = [HostGroup(name: "生产")] }
        // 不等 debounce，立即同步刷盘
        try controller.flushNowSync()
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.groups.first?.name, "生产")
    }

    func testHighFrequencyMutationsCoalesceAndLastValueWins() async throws {
        let (controller, store) = try makeController(debounceMillis: 30)
        for index in 1...20 {
            controller.mutate { $0.hostMetadata = ["alias": HostMetadata(tags: ["v\(index)"])] }
        }
        try controller.flushNowSync()
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.hostMetadata["alias"]?.tags, ["v20"])
    }

    func testThreeStoreFieldsCoexistAfterFlush() throws {
        // 这条用例对应 review 里"三个 store 各写各字段互相覆盖"的根隐患：
        // 任一 mutate 不应丢掉其他 store 此前写入的字段。
        let (controller, store) = try makeController(debounceMillis: 30)

        let group = HostGroup(name: "G")
        controller.mutate { $0.groups = [group] }

        let panel = Panel(name: "P", url: "https://example.com", username: "admin")
        controller.mutate { $0.panels = [panel] }

        let database = Database(
            name: "D",
            kind: .postgres,
            host: "localhost",
            defaultDatabase: "test",
            username: "postgres"
        )
        controller.mutate { $0.databases = [database] }

        try controller.flushNowSync()

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.groups.first?.name, "G", "host 写入的 group 不应被后续 panel/database 写覆盖")
        XCTAssertEqual(reloaded.panels.first?.name, "P", "panel 写入不应被 database 写覆盖")
        XCTAssertEqual(reloaded.databases.first?.name, "D")
    }

    func testWriteFailureThrowsAndSurfacesInLastFlushError() throws {
        let lockedURL = try makeWriteFailingMetadataURL()
        defer { try? unlockParent(of: lockedURL) }

        let store = SidecarStore(fileURL: lockedURL)
        let controller = SidecarController(store: store, debounceMillis: 10)
        controller.mutate { $0.groups = [HostGroup(name: "X")] }
        XCTAssertThrowsError(try controller.flushNowSync()) { error in
            guard case SidecarControllerError.flushFailed = error else {
                return XCTFail("期望 flushFailed，得到 \(error)")
            }
        }
        XCTAssertNotNil(controller.lastFlushError, "写盘失败必须暴露给 UI，不能静默吞掉")
    }

    func testMutateAndFlushRollsBackOnFailure() throws {
        // 事务路径：写盘失败时内存视图必须回到 mutate 前的状态，
        // 否则 UI 会显示用户"以为已保存"的数据。
        let lockedURL = try makeWriteFailingMetadataURL()
        defer { try? unlockParent(of: lockedURL) }

        let store = SidecarStore(fileURL: lockedURL)
        let controller = SidecarController(store: store, debounceMillis: 10)

        let originalGroups = controller.payload.groups
        XCTAssertThrowsError(
            try controller.mutateAndFlush { payload in
                payload.groups = [HostGroup(name: "shouldRollBack")]
            }
        )
        XCTAssertEqual(controller.payload.groups, originalGroups, "落盘失败后内存必须回滚")
    }

    func testReadFailureSurfacesAndStartsWithEmptyPayload() throws {
        // 写一段非法 JSON，看 init 是否优雅 fallback 到空 payload + 上报错误。
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("metadata.json")
        try "{ not valid json".write(to: url, atomically: true, encoding: .utf8)

        let store = SidecarStore(fileURL: url)
        let controller = SidecarController(store: store, debounceMillis: 10)
        XCTAssertTrue(controller.payload.groups.isEmpty)
        XCTAssertTrue(controller.payload.panels.isEmpty)
        XCTAssertNotNil(controller.lastFlushError)
    }

    func testDebouncedFlushEventuallyLandsWithoutFlushNow() async throws {
        // 仅靠 debounce 也应该写到盘上，无需调用方主动 flushNowSync。
        let (controller, store) = try makeController(debounceMillis: 20)
        controller.mutate { $0.groups = [HostGroup(name: "auto")] }

        // 等到 debounce + 写盘完成。给一个相对宽松的预期时间。
        try await Task.sleep(nanoseconds: 300_000_000)

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.groups.first?.name, "auto")
    }

    // MARK: - Helpers

    private func makeController(debounceMillis: UInt64) throws -> (SidecarController, SidecarStore) {
        let dir = try makeTempDirectory()
        // 注意：返回 controller 后调用方负责，不在 helper 内 cleanup —— 这些 test 文件量小，
        // OS 临时目录策略足以兜底；如果未来需要严格 cleanup 可以在 tearDown 收集。
        let store = SidecarStore(fileURL: dir.appendingPathComponent("metadata.json"))
        let controller = SidecarController(store: store, debounceMillis: debounceMillis)
        return (controller, store)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHKeeperControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 构造一个父目录设为 0o500（只读+可执行）的 metadata 路径，
    /// 让 SidecarStore.save 在 atomic temp file 阶段就 fail。
    /// 比"父目录冲突"更可靠 —— APFS 的 replaceItemAt 在某些场景下能把目录替成文件。
    private func makeWriteFailingMetadataURL() throws -> URL {
        let dir = try makeTempDirectory()
        let lockedDir = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: lockedDir.path
        )
        return lockedDir.appendingPathComponent("metadata.json")
    }

    private func unlockParent(of url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path
        )
    }
}
