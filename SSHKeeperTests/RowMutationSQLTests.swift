import XCTest
@testable import SSHKeeperCore

final class RowMutationSQLTests: XCTestCase {

    // MARK: - MySQL insertSQL

    func testMySQLInsertMultipleColumnsSortsKeys() throws {
        let (sql, bindings) = try MySQLDatabaseClient.insertSQL(
            qualified: "`db`.`t`",
            values: ["b": "2", "a": "1"]
        )
        XCTAssertEqual(sql, "INSERT INTO `db`.`t` (`a`, `b`) VALUES (?, ?)")
        XCTAssertEqual(bindings, [.string("1"), .string("2")])
    }

    func testMySQLInsertSingleNullKeepsPlaceholder() throws {
        let (sql, bindings) = try MySQLDatabaseClient.insertSQL(
            qualified: "`db`.`t`",
            values: ["note": nil]
        )
        XCTAssertEqual(sql, "INSERT INTO `db`.`t` (`note`) VALUES (?)")
        XCTAssertEqual(bindings, [.null])
    }

    func testMySQLInsertEmptyValuesThrows() {
        XCTAssertThrowsError(
            try MySQLDatabaseClient.insertSQL(qualified: "`db`.`t`", values: [:])
        ) { error in
            guard case DatabaseClientError.invalidConfiguration = error else {
                XCTFail("expected .invalidConfiguration, got \(error)")
                return
            }
        }
    }

    func testMySQLInsertEscapesBacktickInColumnName() throws {
        let (sql, _) = try MySQLDatabaseClient.insertSQL(
            qualified: "`db`.`t`",
            values: ["a`b": "x"]
        )
        XCTAssertEqual(sql, "INSERT INTO `db`.`t` (`a``b`) VALUES (?)")
    }

    // MARK: - MySQL deleteSQL

    func testMySQLDeleteSinglePKHasLimitOne() throws {
        let (sql, bindings) = try MySQLDatabaseClient.deleteSQL(
            qualified: "`db`.`t`",
            primaryKey: ["id": "4123"]
        )
        XCTAssertEqual(sql, "DELETE FROM `db`.`t` WHERE `id` = ? LIMIT 1")
        XCTAssertEqual(bindings, [.string("4123")])
    }

    func testMySQLDeleteCompositePKSortedStable() throws {
        let (sql, bindings) = try MySQLDatabaseClient.deleteSQL(
            qualified: "`db`.`t`",
            primaryKey: ["b": "2", "a": "1"]
        )
        XCTAssertEqual(sql, "DELETE FROM `db`.`t` WHERE `a` = ? AND `b` = ? LIMIT 1")
        XCTAssertEqual(bindings, [.string("1"), .string("2")])
    }

    func testMySQLDeleteEmptyPKThrows() {
        XCTAssertThrowsError(
            try MySQLDatabaseClient.deleteSQL(qualified: "`db`.`t`", primaryKey: [:])
        ) { error in
            guard case DatabaseClientError.invalidConfiguration = error else {
                XCTFail("expected .invalidConfiguration, got \(error)")
                return
            }
        }
    }

    // MARK: - Postgres insertSQL

    func testPostgresInsertMultipleColumnsSortsKeys() throws {
        let (sql, bindings) = try PostgresDatabaseClient.insertSQL(
            qualified: "\"public\".\"t\"",
            values: ["b": "2", "a": "1"]
        )
        XCTAssertEqual(sql, "INSERT INTO \"public\".\"t\" (\"a\", \"b\") VALUES (?, ?)")
        XCTAssertEqual(bindings, [.string("1"), .string("2")])
    }

    func testPostgresInsertSingleNullKeepsPlaceholder() throws {
        let (sql, bindings) = try PostgresDatabaseClient.insertSQL(
            qualified: "\"public\".\"t\"",
            values: ["note": nil]
        )
        XCTAssertEqual(sql, "INSERT INTO \"public\".\"t\" (\"note\") VALUES (?)")
        XCTAssertEqual(bindings, [.null])
    }

    func testPostgresInsertEmptyValuesThrows() {
        XCTAssertThrowsError(
            try PostgresDatabaseClient.insertSQL(qualified: "\"public\".\"t\"", values: [:])
        ) { error in
            guard case DatabaseClientError.invalidConfiguration = error else {
                XCTFail("expected .invalidConfiguration, got \(error)")
                return
            }
        }
    }

    func testPostgresInsertEscapesDoubleQuoteInColumnName() throws {
        let (sql, _) = try PostgresDatabaseClient.insertSQL(
            qualified: "\"public\".\"t\"",
            values: ["a\"b": "x"]
        )
        XCTAssertEqual(sql, "INSERT INTO \"public\".\"t\" (\"a\"\"b\") VALUES (?)")
    }

    // MARK: - Postgres deleteSQL

    func testPostgresDeleteSinglePKHasNoLimit() throws {
        let (sql, bindings) = try PostgresDatabaseClient.deleteSQL(
            qualified: "\"public\".\"t\"",
            primaryKey: ["id": "4123"]
        )
        XCTAssertEqual(sql, "DELETE FROM \"public\".\"t\" WHERE \"id\" = ?")
        XCTAssertEqual(bindings, [.string("4123")])
    }

    func testPostgresDeleteCompositePKSortedStable() throws {
        let (sql, bindings) = try PostgresDatabaseClient.deleteSQL(
            qualified: "\"public\".\"t\"",
            primaryKey: ["b": "2", "a": "1"]
        )
        XCTAssertEqual(sql, "DELETE FROM \"public\".\"t\" WHERE \"a\" = ? AND \"b\" = ?")
        XCTAssertEqual(bindings, [.string("1"), .string("2")])
    }

    func testPostgresDeleteEmptyPKThrows() {
        XCTAssertThrowsError(
            try PostgresDatabaseClient.deleteSQL(qualified: "\"public\".\"t\"", primaryKey: [:])
        ) { error in
            guard case DatabaseClientError.invalidConfiguration = error else {
                XCTFail("expected .invalidConfiguration, got \(error)")
                return
            }
        }
    }
}
