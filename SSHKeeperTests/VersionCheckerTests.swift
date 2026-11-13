import XCTest
@testable import SSHKeeperCore

final class VersionCheckerTests: XCTestCase {

    // MARK: compare

    func testCompareEqual() {
        XCTAssertEqual(VersionChecker.compare("1.0.0", "1.0.0"), .orderedSame)
    }

    func testCompareMinorAscending() {
        XCTAssertEqual(VersionChecker.compare("1.0.0", "1.0.1"), .orderedAscending)
    }

    func testCompareMajorDescending() {
        XCTAssertEqual(VersionChecker.compare("2.0.0", "1.99.99"), .orderedDescending)
    }

    func testCompareDoubleDigitPatch() {
        // 1.0.10 > 1.0.2 数字比较，不是字典序
        XCTAssertEqual(VersionChecker.compare("1.0.10", "1.0.2"), .orderedDescending)
    }

    func testComparePadShorter() {
        // 1.0 == 1.0.0（短的补 0）
        XCTAssertEqual(VersionChecker.compare("1.0", "1.0.0"), .orderedSame)
    }

    func testComparePadShorterAscending() {
        // 1.0 < 1.0.1
        XCTAssertEqual(VersionChecker.compare("1.0", "1.0.1"), .orderedAscending)
    }

    func testCompareNonNumericFallback() {
        // 任一段非数字 → fallback localizedStandardCompare；至少不等
        XCTAssertNotEqual(VersionChecker.compare("1.0.0-beta", "1.0.0"), .orderedSame)
    }

    // MARK: isNewer

    func testIsNewerTrue() {
        XCTAssertTrue(VersionChecker.isNewer(remote: "1.0.1", than: "1.0.0"))
    }

    func testIsNewerFalseWhenSame() {
        XCTAssertFalse(VersionChecker.isNewer(remote: "1.0.0", than: "1.0.0"))
    }

    func testIsNewerFalseWhenOlder() {
        XCTAssertFalse(VersionChecker.isNewer(remote: "0.9.9", than: "1.0.0"))
    }
}
