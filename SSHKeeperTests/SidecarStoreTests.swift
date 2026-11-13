import XCTest
@testable import SSHKeeperCore

final class SidecarStoreTests: XCTestCase {
    func testLoadFromMissingFileReturnsEmpty() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SidecarStore(fileURL: dir.appendingPathComponent("metadata.json"))
        let payload = try store.load()
        XCTAssertEqual(payload.schemaVersion, 3)
        XCTAssertTrue(payload.groups.isEmpty)
        XCTAssertTrue(payload.hostMetadata.isEmpty)
        XCTAssertTrue(payload.panels.isEmpty)
        XCTAssertTrue(payload.databases.isEmpty)
    }

    func testLoadV1FilePopulatesEmptyPanels() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("metadata.json")
        let v1Json = """
        {
          "schemaVersion": 1,
          "groups": [],
          "hostMetadata": {}
        }
        """
        try v1Json.write(to: url, atomically: true, encoding: .utf8)
        let store = SidecarStore(fileURL: url)
        let payload = try store.load()
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertTrue(payload.panels.isEmpty)
    }

    func testRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SidecarStore(fileURL: dir.appendingPathComponent("metadata.json"))
        let group = HostGroup(name: "生产")
        let payload = SidecarPayload(
            groups: [group],
            hostMetadata: [
                "myserver": HostMetadata(
                    groupID: group.id,
                    tags: ["web", "primary"],
                    colorHex: "#ff0000",
                    lastUsedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ]
        )
        try store.save(payload)
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.groups.first?.name, "生产")
        XCTAssertEqual(reloaded.hostMetadata["myserver"]?.tags, ["web", "primary"])
        XCTAssertEqual(reloaded.hostMetadata["myserver"]?.colorHex, "#ff0000")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHKeeperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
