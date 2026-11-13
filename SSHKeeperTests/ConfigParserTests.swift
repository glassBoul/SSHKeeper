import XCTest
@testable import SSHKeeperCore

final class ConfigParserTests: XCTestCase {
    func testParsesBasicHostBlocks() throws {
        let input = """
        Host bastion
            HostName bastion.example.com
            User ops
            Port 2222
            IdentityFile ~/.ssh/bastion_ed25519
        """
        let parsed = ConfigParser.parseString(input)
        XCTAssertEqual(parsed.hosts.count, 1)
        let host = parsed.hosts[0]
        XCTAssertEqual(host.alias, "bastion")
        XCTAssertEqual(host.hostname, "bastion.example.com")
        XCTAssertEqual(host.user, "ops")
        XCTAssertEqual(host.port, 2222)
        XCTAssertEqual(host.identityFile, "~/.ssh/bastion_ed25519")
        XCTAssertEqual(host.source, .imported)
    }

    func testHostWithMultipleAliasesProducesMultipleEntries() {
        let input = """
        Host web1 web2
            HostName 10.0.0.1
            User deploy
        """
        let parsed = ConfigParser.parseString(input)
        XCTAssertEqual(parsed.hosts.count, 2)
        XCTAssertEqual(Set(parsed.hosts.map(\.alias)), ["web1", "web2"])
        for host in parsed.hosts {
            XCTAssertEqual(host.hostname, "10.0.0.1")
            XCTAssertEqual(host.user, "deploy")
        }
    }

    func testWildcardHostBlockIsSkipped() {
        let input = """
        Host *
            ServerAliveInterval 60
        Host real
            HostName real.example.com
        """
        let parsed = ConfigParser.parseString(input)
        XCTAssertEqual(parsed.hosts.map(\.alias), ["real"])
    }

    func testMatchBlockIsSkippedAndRecorded() {
        let input = """
        Host real
            HostName real.example.com
        Match host db.*
            User dba
        Match exec hostname-check
            ForwardAgent yes
        """
        let parsed = ConfigParser.parseString(input)
        XCTAssertEqual(parsed.hosts.count, 1)
        XCTAssertEqual(parsed.hosts[0].user, nil)
        // Match 块本身的字段不被吸收到 host，但它们应该被列入 skipped 让 UI 提示
        XCTAssertEqual(parsed.skippedMatchBlocks.count, 2)
        XCTAssertEqual(parsed.skippedMatchBlocks.map(\.rawArgument), ["host db.*", "exec hostname-check"])
    }

    func testCommentsStripped() {
        let input = """
        # leading comment
        Host x  # trailing comment on host line
            HostName x.example.com  # comment after value
        """
        let parsed = ConfigParser.parseString(input)
        XCTAssertEqual(parsed.hosts.count, 1)
        XCTAssertEqual(parsed.hosts[0].hostname, "x.example.com")
    }

    func testExtraOptionsCollected() {
        let input = """
        Host x
            HostName x.example.com
            ForwardAgent yes
            StrictHostKeyChecking no
        """
        let parsed = ConfigParser.parseString(input)
        let host = parsed.hosts[0]
        XCTAssertEqual(host.extraOptions["forwardagent"], "yes")
        XCTAssertEqual(host.extraOptions["stricthostkeychecking"], "no")
    }

    func testKeywordCaseInsensitive() {
        let input = """
        host x
            hostname x.example.com
            PORT 33
        """
        let parsed = ConfigParser.parseString(input)
        XCTAssertEqual(parsed.hosts[0].hostname, "x.example.com")
        XCTAssertEqual(parsed.hosts[0].port, 33)
    }

    func testTokenizerHandlesEqualsAndQuotes() {
        XCTAssertEqual(ConfigParser.tokenize("Port=22"), ["Port", "22"])
        XCTAssertEqual(ConfigParser.tokenize("HostName \"x with space\""), ["HostName", "x with space"])
    }

    func testIncludeDirectiveCaptured() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let included = tempDir.appendingPathComponent("included.conf")
        try "Host included\n    HostName inc.example.com\n".write(to: included, atomically: true, encoding: .utf8)

        let main = tempDir.appendingPathComponent("config")
        try "Include included.conf\nHost top\n    HostName top.example.com\n".write(to: main, atomically: true, encoding: .utf8)

        let parsed = try ConfigParser.parse(fileURL: main)
        XCTAssertEqual(Set(parsed.hosts.map(\.alias)), ["top", "included"])
        XCTAssertEqual(parsed.includeDirectives.count, 1)
        XCTAssertEqual(parsed.includeDirectives[0].rawArgument, "included.conf")
        XCTAssertEqual(parsed.includeDirectives[0].resolvedFiles, [included.path])
    }

    func testFixtureFileEndToEnd() throws {
        let url = Bundle(for: Self.self).url(forResource: "sample_config", withExtension: "txt")!
        let parsed = try ConfigParser.parse(fileURL: url)
        let aliases = Set(parsed.hosts.map(\.alias))
        XCTAssertEqual(aliases, ["bastion", "web1", "web2", "single-with-extras"])
        let bastion = parsed.hosts.first { $0.alias == "bastion" }!
        XCTAssertEqual(bastion.port, 2222)
        let extras = parsed.hosts.first { $0.alias == "single-with-extras" }!
        XCTAssertEqual(extras.extraOptions["forwardagent"], "yes")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHKeeperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
