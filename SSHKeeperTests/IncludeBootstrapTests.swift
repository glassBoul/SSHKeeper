import XCTest
@testable import SSHKeeperCore

final class IncludeBootstrapTests: XCTestCase {
    func testDetectsExistingDirectInclude() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        try "Include config.d/*.conf\nHost x\n".write(to: configURL, atomically: true, encoding: .utf8)
        let bootstrap = IncludeBootstrap(configFileURL: configURL)
        XCTAssertTrue(bootstrap.isAlreadyIncluded())
    }

    func testDetectsExistingTildeInclude() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        try "Include ~/.ssh/config.d/*.conf\n".write(to: configURL, atomically: true, encoding: .utf8)
        let bootstrap = IncludeBootstrap(configFileURL: configURL)
        XCTAssertTrue(bootstrap.isAlreadyIncluded())
    }

    func testReturnsFalseWhenNoIncludePresent() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        try "Host foo\n    HostName f.example.com\n".write(to: configURL, atomically: true, encoding: .utf8)
        let bootstrap = IncludeBootstrap(configFileURL: configURL)
        XCTAssertFalse(bootstrap.isAlreadyIncluded())
    }

    func testReturnsFalseWhenConfigMissing() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("missing")
        let bootstrap = IncludeBootstrap(configFileURL: configURL)
        XCTAssertFalse(bootstrap.isAlreadyIncluded())
    }

    func testInjectionPrependsIncludeAndBacksUp() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        let original = "Host foo\n    HostName f.example.com\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        let bootstrap = IncludeBootstrap(configFileURL: configURL)
        let backup = try bootstrap.injectInclude()

        let updated = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("Include config.d/*.conf"))
        XCTAssertTrue(updated.contains("Host foo"))
        XCTAssertTrue(updated.range(of: "Include")!.lowerBound < updated.range(of: "Host foo")!.lowerBound)

        XCTAssertNotNil(backup)
        let backupContents = try String(contentsOf: backup!, encoding: .utf8)
        XCTAssertEqual(backupContents, original)
    }

    func testInjectionWithNoExistingFileSkipsBackup() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")

        let bootstrap = IncludeBootstrap(configFileURL: configURL)
        let backup = try bootstrap.injectInclude()
        XCTAssertNil(backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
        let updated = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("Include config.d/*.conf"))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHKeeperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
