import XCTest
@testable import SSHKeeperCore

final class VersionInfoTests: XCTestCase {
    func testParseFullJSON() throws {
        let json = """
        {
          "latest": "1.0.1",
          "downloadUrl": "https://sshkeeper.feilian.cc/SSHKeeper-1.0.1.dmg",
          "releaseNotes": "- 修了 X\\n- 加了 Y"
        }
        """.data(using: .utf8)!
        let info = try VersionInfo.parse(json)
        XCTAssertEqual(info.latest, "1.0.1")
        XCTAssertEqual(info.downloadUrl.absoluteString, "https://sshkeeper.feilian.cc/SSHKeeper-1.0.1.dmg")
        XCTAssertEqual(info.releaseNotes, "- 修了 X\n- 加了 Y")
    }

    func testParseRejectsMissingLatest() {
        let json = """
        { "downloadUrl": "https://x/y.dmg", "releaseNotes": "" }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try VersionInfo.parse(json))
    }

    func testParseRejectsMissingDownloadUrl() {
        let json = """
        { "latest": "1.0.1", "releaseNotes": "" }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try VersionInfo.parse(json))
    }

    func testParseRejectsMissingReleaseNotes() {
        let json = """
        { "latest": "1.0.1", "downloadUrl": "https://x/y.dmg" }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try VersionInfo.parse(json))
    }

    func testParseRejectsInvalidDownloadUrl() {
        let json = """
        { "latest": "1.0.1", "downloadUrl": "not a url ::", "releaseNotes": "" }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try VersionInfo.parse(json))
    }

    func testParseRejectsNonObject() {
        let json = "[\"a\", \"b\"]".data(using: .utf8)!
        XCTAssertThrowsError(try VersionInfo.parse(json))
    }

    func testParseIgnoresExtraFields() throws {
        let json = """
        {
          "latest": "1.0.1",
          "downloadUrl": "https://x/y.dmg",
          "releaseNotes": "ok",
          "publishedAt": "2026-05-21T10:00:00Z",
          "minimum": "1.0.0"
        }
        """.data(using: .utf8)!
        let info = try VersionInfo.parse(json)
        XCTAssertEqual(info.latest, "1.0.1")
    }
}
