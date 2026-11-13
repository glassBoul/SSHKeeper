import XCTest
@testable import SSHKeeperCore

final class SQLEscapeTests: XCTestCase {
    func testMySQLDoublesSingleQuote() {
        XCTAssertEqual(SQLEscape.mysql("O'Brien"), "O''Brien")
    }

    func testMySQLEscapesBackslash() {
        // 这是改动的核心：之前只 escape '，遗漏 \ 会让 'a\' 变成"未闭合字符串 + 注入"
        XCTAssertEqual(SQLEscape.mysql("a\\b"), "a\\\\b")
        XCTAssertEqual(SQLEscape.mysql("a\\"), "a\\\\")
    }

    func testMySQLEscapesControlBytes() {
        XCTAssertEqual(SQLEscape.mysql("a\u{0}b"), "a\\0b")
        XCTAssertEqual(SQLEscape.mysql("a\nb"), "a\\nb")
        XCTAssertEqual(SQLEscape.mysql("a\rb"), "a\\rb")
        XCTAssertEqual(SQLEscape.mysql("a\u{1A}b"), "a\\Zb")
    }

    func testMySQLPassesThroughOrdinaryAscii() {
        XCTAssertEqual(SQLEscape.mysql("hello world 123"), "hello world 123")
    }

    func testMySQLPreservesUnicodeAndDoubleQuote() {
        // 双引号在 MySQL 单引号字符串里不需要转义；保持原样
        XCTAssertEqual(SQLEscape.mysql("中文 \"quoted\""), "中文 \"quoted\"")
    }

    func testPostgresDoublesSingleQuoteOnly() {
        // PG 在 standard_conforming_strings=on 下 \ 是普通字符，不能转义
        XCTAssertEqual(SQLEscape.postgres("O'Brien"), "O''Brien")
        XCTAssertEqual(SQLEscape.postgres("a\\b"), "a\\b")
    }

    func testPotentialInjectionVectorsAreNeutralized() {
        // 模拟一个注入尝试：value 是 "x'); DROP TABLE u;--"
        let malicious = "x'); DROP TABLE u;--"
        let mysqlSafe = SQLEscape.mysql(malicious)
        // 单引号被 doubled 后，无法跳出字符串字面量
        XCTAssertEqual(mysqlSafe, "x''); DROP TABLE u;--")
        // 反斜杠也无法用作"吃掉"下一字符的 trick
        let backslashTrick = "a\\' OR 1=1; --"
        XCTAssertEqual(SQLEscape.mysql(backslashTrick), "a\\\\'' OR 1=1; --")
    }
}
