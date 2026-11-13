import XCTest
@testable import SSHKeeperCore

final class CSVExporterTests: XCTestCase {
    private func make(_ columns: [String], _ rows: [[String?]]) -> QueryResult {
        QueryResult(columns: columns, rows: rows, rowsAffected: rows.count, executionTime: 0, isTruncated: false)
    }

    func testHeaderAndSimpleRow() {
        let r = make(["id", "name"], [["1", "alice"]])
        let s = String(data: CSVExporter.encode(r, includeBOM: false), encoding: .utf8)!
        XCTAssertEqual(s, "id,name\r\n1,alice\r\n")
    }

    func testQuotedFieldsForCommaQuoteNewline() {
        let r = make(["c"], [
            ["a,b"],
            ["a\"b"],
            ["a\nb"],
            ["a\rb"]
        ])
        let s = String(data: CSVExporter.encode(r, includeBOM: false), encoding: .utf8)!
        XCTAssertEqual(s, "c\r\n\"a,b\"\r\n\"a\"\"b\"\r\n\"a\nb\"\r\n\"a\rb\"\r\n")
    }

    func testNilSerializedAsEmpty() {
        let r = make(["a", "b"], [["x", nil], [nil, "y"]])
        let s = String(data: CSVExporter.encode(r, includeBOM: false), encoding: .utf8)!
        XCTAssertEqual(s, "a,b\r\nx,\r\n,y\r\n")
    }

    func testBOMByDefault() {
        let r = make(["a"], [["1"]])
        let bytes = CSVExporter.encode(r)
        XCTAssertEqual(Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    func testHeaderWithSpecialChars() {
        // 列名也得遵循同样的转义规则（用户起的列别名可能含空格/逗号）
        let r = make(["a,b", "x\"y"], [["1", "2"]])
        let s = String(data: CSVExporter.encode(r, includeBOM: false), encoding: .utf8)!
        XCTAssertEqual(s, "\"a,b\",\"x\"\"y\"\r\n1,2\r\n")
    }

    func testRoundTripChineseWithBOM() {
        let r = make(["姓名"], [["张三"]])
        let bytes = CSVExporter.encode(r)
        // 跳过 BOM 后 UTF-8 解码无丢失
        let body = String(data: bytes.dropFirst(3), encoding: .utf8)
        XCTAssertEqual(body, "姓名\r\n张三\r\n")
    }

    func testEmptyResultStillHasHeader() {
        let r = make(["a", "b", "c"], [])
        let s = String(data: CSVExporter.encode(r, includeBOM: false), encoding: .utf8)!
        XCTAssertEqual(s, "a,b,c\r\n")
    }
}
