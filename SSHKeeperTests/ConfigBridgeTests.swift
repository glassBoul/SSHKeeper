import XCTest
@testable import SSHKeeperCore

final class ConfigBridgeTests: XCTestCase {
    func testRenderProducesExpectedFormat() {
        let bridge = ConfigBridge(fileURL: URL(fileURLWithPath: "/tmp/x"))
        let host = SSHHost(
            alias: "myserver",
            hostname: "10.0.0.5",
            port: 2200,
            user: "ubuntu",
            identityFile: "~/.ssh/id_ed25519",
            proxyJump: "bastion",
            extraOptions: ["forwardagent": "yes"],
            source: .appManaged
        )
        let output = bridge.render(hosts: [host])
        XCTAssertTrue(output.contains("Host myserver"))
        XCTAssertTrue(output.contains("    HostName 10.0.0.5"))
        XCTAssertTrue(output.contains("    Port 2200"))
        XCTAssertTrue(output.contains("    User ubuntu"))
        XCTAssertTrue(output.contains("    IdentityFile ~/.ssh/id_ed25519"))
        XCTAssertTrue(output.contains("    ProxyJump bastion"))
        XCTAssertTrue(output.contains("    ForwardAgent yes"))
        XCTAssertTrue(output.contains("Managed by SSHKeeper"))
    }

    func testImportedHostsAreNotRendered() {
        let bridge = ConfigBridge(fileURL: URL(fileURLWithPath: "/tmp/x"))
        let imported = SSHHost(alias: "imported", hostname: "i.example.com", source: .imported)
        let managed = SSHHost(alias: "managed", hostname: "m.example.com", source: .appManaged)
        let output = bridge.render(hosts: [imported, managed])
        XCTAssertFalse(output.contains("Host imported"))
        XCTAssertTrue(output.contains("Host managed"))
    }

    func testWriteCreatesFileWithRestrictedPermissions() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let target = tempDir.appendingPathComponent("config.d/sshkeeper.conf")
        let bridge = ConfigBridge(fileURL: target)
        try bridge.write(hosts: [
            SSHHost(alias: "a", hostname: "a.example.com", source: .appManaged)
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(perms, 0o600)
    }

    func testWriteIsIdempotent() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let target = tempDir.appendingPathComponent("sshkeeper.conf")
        let bridge = ConfigBridge(fileURL: target)
        let host = SSHHost(alias: "a", hostname: "a.example.com", source: .appManaged)
        try bridge.write(hosts: [host])
        let first = try String(contentsOf: target, encoding: .utf8)
        try bridge.write(hosts: [host])
        let second = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(first, second)
    }

    func testRoundTripThroughParser() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let target = tempDir.appendingPathComponent("rt.conf")
        let bridge = ConfigBridge(fileURL: target)
        let original = SSHHost(
            alias: "rt",
            hostname: "rt.example.com",
            port: 2200,
            user: "u",
            identityFile: "~/.ssh/x",
            proxyJump: "j",
            extraOptions: ["forwardagent": "yes"],
            source: .appManaged
        )
        try bridge.write(hosts: [original])

        let parsed = try ConfigParser.parse(fileURL: target)
        XCTAssertEqual(parsed.hosts.count, 1)
        let back = parsed.hosts[0]
        XCTAssertEqual(back.alias, original.alias)
        XCTAssertEqual(back.hostname, original.hostname)
        XCTAssertEqual(back.port, original.port)
        XCTAssertEqual(back.user, original.user)
        XCTAssertEqual(back.identityFile, original.identityFile)
        XCTAssertEqual(back.proxyJump, original.proxyJump)
        XCTAssertEqual(back.extraOptions["forwardagent"], "yes")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHKeeperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
