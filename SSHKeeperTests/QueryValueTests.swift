import XCTest
@testable import SSHKeeperCore

final class QueryValueTests: XCTestCase {
    func testRewriteSimpleQuestionMarks() {
        let sql = "UPDATE t SET c = ? WHERE id = ?"
        XCTAssertEqual(
            QueryValue.mysqlPlaceholdersToPostgres(sql),
            "UPDATE t SET c = $1 WHERE id = $2"
        )
    }

    func testRewriteIgnoresQuestionMarksInsideStringLiteral() {
        // 单引号内的 ? 是字面量（譬如 LIKE '%?%'），不应该被换成 $N
        let sql = "SELECT * FROM t WHERE x = ? AND y = '?' AND z = ?"
        XCTAssertEqual(
            QueryValue.mysqlPlaceholdersToPostgres(sql),
            "SELECT * FROM t WHERE x = $1 AND y = '?' AND z = $2"
        )
    }

    func testRewriteIgnoresQuestionMarksInsideDoubleQuotes() {
        let sql = "SELECT * FROM \"weird?col\" WHERE a = ?"
        XCTAssertEqual(
            QueryValue.mysqlPlaceholdersToPostgres(sql),
            "SELECT * FROM \"weird?col\" WHERE a = $1"
        )
    }

    func testRewriteIgnoresQuestionMarksInsideBackticks() {
        let sql = "SELECT * FROM `weird?col` WHERE a = ?"
        XCTAssertEqual(
            QueryValue.mysqlPlaceholdersToPostgres(sql),
            "SELECT * FROM `weird?col` WHERE a = $1"
        )
    }

    func testRewriteHandlesDoubledQuoteEscapeInsideString() {
        // SQL 标准用 '' 表示字符串内的单引号；toggle 状态机自然过——闭合后仍是 string 状态外
        let sql = "UPDATE t SET c = ? WHERE name = 'O''Brien' AND id = ?"
        XCTAssertEqual(
            QueryValue.mysqlPlaceholdersToPostgres(sql),
            "UPDATE t SET c = $1 WHERE name = 'O''Brien' AND id = $2"
        )
    }

    func testRewriteWithoutPlaceholdersIsIdentity() {
        let sql = "SELECT 1"
        XCTAssertEqual(QueryValue.mysqlPlaceholdersToPostgres(sql), "SELECT 1")
    }

    func testQueryValueEquality() {
        XCTAssertEqual(QueryValue.string("hi"), QueryValue.string("hi"))
        XCTAssertNotEqual(QueryValue.string("hi"), QueryValue.string("hj"))
        XCTAssertEqual(QueryValue.null, QueryValue.null)
        XCTAssertNotEqual(QueryValue.null, QueryValue.string(""))
    }
}
