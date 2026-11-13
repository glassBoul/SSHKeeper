import XCTest
@testable import SSHKeeperCore

@MainActor
final class HostStoreTests: XCTestCase {
    func testUpsertWritesConfAndMetadataInHappyPath() throws {
        let (store, sidecar, paths) = try makeStore()
        let host = SSHHost(
            alias: "prod1",
            hostname: "10.0.0.1",
            port: 22,
            user: "ops",
            source: .appManaged
        )
        try store.upsert(host)

        // conf 文件含我们写入的 alias
        let conf = try String(contentsOf: paths.managedConf, encoding: .utf8)
        XCTAssertTrue(conf.contains("Host prod1"))
        // 内存里也有
        XCTAssertEqual(store.hosts.first?.alias, "prod1")
        // metadata 已落盘（mutate 同步 + flushNowSync 同步）
        let payload = try SidecarStore(fileURL: paths.metadata).load()
        XCTAssertEqual(payload.hostMetadata.count, 1)
        _ = sidecar
    }

    func testUpsertRollsBackBothMemoryAndDiskWhenMetadataFails() throws {
        let (store, _, paths) = try makeFailingStore()

        // 先写一份初始 conf 内容（有一个旧 host），以便验证回滚到这份内容。
        let initialBody = "# initial\nHost original\n    HostName 1.1.1.1\n"
        try FileManager.default.createDirectory(
            at: paths.managedConf.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try initialBody.write(to: paths.managedConf, atomically: true, encoding: .utf8)
        store.load()

        let newHost = SSHHost(
            alias: "willFail",
            hostname: "2.2.2.2",
            port: 22,
            user: nil,
            source: .appManaged
        )

        XCTAssertThrowsError(try store.upsert(newHost)) { error in
            guard case HostStoreError.transactionFailed = error else {
                return XCTFail("应该是 transactionFailed，实际 \(error)")
            }
        }

        // conf 必须回滚到初始内容
        let confAfter = try String(contentsOf: paths.managedConf, encoding: .utf8)
        XCTAssertEqual(confAfter, initialBody, "metadata 失败时 conf 必须回滚")
        // hosts 内存也必须回滚 —— willFail 不应该出现
        XCTAssertFalse(store.hosts.contains(where: { $0.alias == "willFail" }))
    }

    func testUpsertRollsBackToNoFileWhenConfDidNotExist() throws {
        let (store, _, paths) = try makeFailingStore()
        // 起始没有 managed conf 文件
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.managedConf.path))

        let host = SSHHost(alias: "ghost", hostname: "x", port: 22, source: .appManaged)
        XCTAssertThrowsError(try store.upsert(host))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.managedConf.path),
            "调用前没有 conf，metadata 失败回滚后也不应留下 conf 文件"
        )
        XCTAssertTrue(store.hosts.isEmpty)
    }

    func testRemoveGroupRollsBackOnMetadataFailure() throws {
        let (store, _, _) = try makeFailingStore()
        // 直接造一个不会触发 conf 写的路径：upsertGroup 不写 conf，只 metadata。
        let group = HostGroup(name: "G")

        XCTAssertThrowsError(try store.upsertGroup(group)) { error in
            guard case HostStoreError.transactionFailed = error else {
                return XCTFail("应该是 transactionFailed，实际 \(error)")
            }
        }
        XCTAssertTrue(store.groups.isEmpty, "metadata 写盘失败时 groups 必须回滚")
    }

    func testTouchDoesNotThrowEvenIfFlushWillFail() throws {
        let (store, _, paths) = try makeFailingStore()

        // 准备一个 host 让 touch 有目标
        let initialBody = "# init\nHost a\n    HostName 1.1.1.1\n"
        try FileManager.default.createDirectory(
            at: paths.managedConf.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try initialBody.write(to: paths.managedConf, atomically: true, encoding: .utf8)
        store.load()

        // touch 走异步 debounce 路径，磁盘失败不会影响调用方
        XCTAssertNoThrow(try store.touch(alias: "a"))
        XCTAssertNotNil(store.hosts.first(where: { $0.alias == "a" })?.lastUsedAt)
    }

    // MARK: - Helpers

    private struct Paths {
        let userConf: URL
        let managedConf: URL
        let metadata: URL
    }

    private func makeStore() throws -> (HostStore, SidecarController, Paths) {
        let dir = try makeTempDirectory()
        let paths = Paths(
            userConf: dir.appendingPathComponent("user-config"),
            managedConf: dir.appendingPathComponent("config.d/sshkeeper.conf"),
            metadata: dir.appendingPathComponent("metadata.json")
        )
        let sidecar = SidecarController(
            store: SidecarStore(fileURL: paths.metadata),
            debounceMillis: 10
        )
        let store = HostStore(
            userConfigURL: paths.userConf,
            managedConfigURL: paths.managedConf,
            sidecar: sidecar
        )
        return (store, sidecar, paths)
    }

    /// 构造一个 metadata 父目录设为 0o500 的 store —— 任何 metadata 落盘都会失败，
    /// 便于测试事务回滚路径。conf 路径正常（写得进去）以模拟"conf 写成功 → metadata 失败 → 回滚 conf"。
    private func makeFailingStore() throws -> (HostStore, SidecarController, Paths) {
        let dir = try makeTempDirectory()
        let lockedDir = dir.appendingPathComponent("locked-meta", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: lockedDir.path
        )
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: lockedDir.path
            )
        }

        let paths = Paths(
            userConf: dir.appendingPathComponent("user-config"),
            managedConf: dir.appendingPathComponent("config.d/sshkeeper.conf"),
            metadata: lockedDir.appendingPathComponent("metadata.json")
        )
        let sidecar = SidecarController(
            store: SidecarStore(fileURL: paths.metadata),
            debounceMillis: 10
        )
        let store = HostStore(
            userConfigURL: paths.userConf,
            managedConfigURL: paths.managedConf,
            sidecar: sidecar
        )
        return (store, sidecar, paths)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
