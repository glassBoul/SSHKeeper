import Foundation

extension MySQLDatabaseClient {
    public func addColumn(_ table: DatabaseObject, column: ColumnDefinition, after: String?) async throws {
        let qualified = qualifiedName(table)
        var sql = "ALTER TABLE \(qualified) ADD COLUMN \(columnSpec(column))"
        if let after {
            if after.isEmpty {
                sql += " FIRST"
            } else {
                sql += " AFTER \(SQLIdentifier.mysql(after))"
            }
        }
        _ = try await runQuery(sql)
    }

    public func dropColumn(_ table: DatabaseObject, columnName: String) async throws {
        let qualified = qualifiedName(table)
        let sql = "ALTER TABLE \(qualified) DROP COLUMN \(SQLIdentifier.mysql(columnName))"
        _ = try await runQuery(sql)
    }

    public func modifyColumn(_ table: DatabaseObject, oldName: String, column: ColumnDefinition) async throws {
        let qualified = qualifiedName(table)
        let sql: String
        if oldName != column.name {
            // 重命名 + 改属性
            sql = "ALTER TABLE \(qualified) CHANGE \(SQLIdentifier.mysql(oldName)) \(columnSpec(column))"
        } else {
            sql = "ALTER TABLE \(qualified) MODIFY COLUMN \(columnSpec(column))"
        }
        _ = try await runQuery(sql)
    }

    public func addIndex(_ table: DatabaseObject, index: IndexDefinition) async throws {
        guard !index.columns.isEmpty else {
            throw DatabaseClientError.invalidConfiguration("索引必须至少包含一个字段")
        }
        let qualified = qualifiedName(table)
        let cols = index.columns.map { SQLIdentifier.mysql($0) }.joined(separator: ", ")
        let kw: String
        switch index.category {
        case .primary:
            // 加主键单独走
            _ = try await runQuery("ALTER TABLE \(qualified) ADD PRIMARY KEY (\(cols))")
            return
        case .unique: kw = "UNIQUE INDEX"
        case .normal: kw = "INDEX"
        case .fulltext: kw = "FULLTEXT INDEX"
        case .spatial: kw = "SPATIAL INDEX"
        }
        var sql = "ALTER TABLE \(qualified) ADD \(kw) \(SQLIdentifier.mysql(index.name)) (\(cols))"
        if let method = index.method, !method.isEmpty,
           index.category == .normal || index.category == .unique {
            sql += " USING \(method)"
        }
        if let comment = index.comment, !comment.isEmpty {
            sql += " COMMENT '\(SQLEscape.mysql(comment))'"
        }
        _ = try await runQuery(sql)
    }

    public func dropIndex(_ table: DatabaseObject, indexName: String) async throws {
        let qualified = qualifiedName(table)
        if indexName == "PRIMARY" {
            _ = try await runQuery("ALTER TABLE \(qualified) DROP PRIMARY KEY")
        } else {
            _ = try await runQuery("ALTER TABLE \(qualified) DROP INDEX \(SQLIdentifier.mysql(indexName))")
        }
    }

    public func createTable(
        database: String,
        name: String,
        columns: [ColumnDefinition],
        primaryKeys: [String]
    ) async throws {
        guard !columns.isEmpty else {
            throw DatabaseClientError.invalidConfiguration("至少要有一个字段")
        }
        let qualified = "\(SQLIdentifier.mysql(database)).\(SQLIdentifier.mysql(name))"
        var lines: [String] = columns.map { columnSpec($0) }
        if !primaryKeys.isEmpty {
            let pks = primaryKeys.map { SQLIdentifier.mysql($0) }.joined(separator: ", ")
            lines.append("PRIMARY KEY (\(pks))")
        }
        let body = lines.joined(separator: ",\n  ")
        let sql = "CREATE TABLE \(qualified) (\n  \(body)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci"
        _ = try await runQuery(sql)
    }

    public func dropTable(_ table: DatabaseObject) async throws {
        let qualified = qualifiedName(table)
        _ = try await runQuery("DROP TABLE \(qualified)")
    }

    public func truncateTable(_ table: DatabaseObject) async throws {
        let qualified = qualifiedName(table)
        _ = try await runQuery("TRUNCATE TABLE \(qualified)")
    }

    public func deleteAllRows(_ table: DatabaseObject) async throws {
        let qualified = qualifiedName(table)
        _ = try await runQuery("DELETE FROM \(qualified)")
    }

    public func renameTable(_ table: DatabaseObject, to newName: String) async throws {
        let db = table.parent ?? currentDatabaseName
        let oldQ = "\(SQLIdentifier.mysql(db)).\(SQLIdentifier.mysql(table.name))"
        let newQ = "\(SQLIdentifier.mysql(db)).\(SQLIdentifier.mysql(newName))"
        _ = try await runQuery("RENAME TABLE \(oldQ) TO \(newQ)")
    }

    public func duplicateTable(_ table: DatabaseObject, newName: String, includeData: Bool) async throws {
        let db = table.parent ?? currentDatabaseName
        let oldQ = "\(SQLIdentifier.mysql(db)).\(SQLIdentifier.mysql(table.name))"
        let newQ = "\(SQLIdentifier.mysql(db)).\(SQLIdentifier.mysql(newName))"
        // CREATE TABLE ... LIKE 一次复制全部结构（含索引、外键、AUTO_INCREMENT 重置）
        _ = try await runQuery("CREATE TABLE \(newQ) LIKE \(oldQ)")
        if includeData {
            _ = try await runQuery("INSERT INTO \(newQ) SELECT * FROM \(oldQ)")
        }
    }

    public func updateRow(
        _ table: DatabaseObject,
        primaryKey: [String: String],
        column: String,
        value: String?
    ) async throws {
        guard !primaryKey.isEmpty else {
            throw DatabaseClientError.invalidConfiguration("无主键，无法定位行；请通过 SQL 编辑器 UPDATE")
        }
        let qualified = qualifiedName(table)
        var bindings: [QueryValue] = []
        bindings.append(value.map { .string($0) } ?? .null)
        let sortedKeys = primaryKey.keys.sorted()
        for k in sortedKeys { bindings.append(.string(primaryKey[k]!)) }
        let whereExpr = sortedKeys.map { "\(SQLIdentifier.mysql($0)) = ?" }.joined(separator: " AND ")
        // 为安全起见加 LIMIT 1，避免 PK 取错时误改大量行
        _ = try await runQuery(
            "UPDATE \(qualified) SET \(SQLIdentifier.mysql(column)) = ? WHERE \(whereExpr) LIMIT 1",
            bindings: bindings
        )
    }

    public func insertRow(_ table: DatabaseObject, values: [String: String?]) async throws {
        let (sql, bindings) = try Self.insertSQL(qualified: qualifiedName(table), values: values)
        _ = try await runQuery(sql, bindings: bindings)
    }

    public func deleteRow(_ table: DatabaseObject, primaryKey: [String: String]) async throws {
        let (sql, bindings) = try Self.deleteSQL(
            qualified: qualifiedName(table),
            primaryKey: primaryKey
        )
        _ = try await runQuery(sql, bindings: bindings)
    }

    /// 纯字符串构建，可独立测试。`qualified` 由调用方算好（含库名前缀 + 反引号转义）。
    static func insertSQL(
        qualified: String,
        values: [String: String?]
    ) throws -> (sql: String, bindings: [QueryValue]) {
        guard !values.isEmpty else {
            throw DatabaseClientError.invalidConfiguration("至少要提供一列的值")
        }
        let keys = values.keys.sorted()  // 稳定顺序便于测试
        let cols = keys.map { SQLIdentifier.mysql($0) }.joined(separator: ", ")
        let placeholders = keys.map { _ in "?" }.joined(separator: ", ")
        let bindings: [QueryValue] = keys.map { values[$0]!.map { .string($0) } ?? .null }
        return ("INSERT INTO \(qualified) (\(cols)) VALUES (\(placeholders))", bindings)
    }

    static func deleteSQL(
        qualified: String,
        primaryKey: [String: String]
    ) throws -> (sql: String, bindings: [QueryValue]) {
        guard !primaryKey.isEmpty else {
            throw DatabaseClientError.invalidConfiguration("无主键，无法定位行；请通过 SQL 编辑器 DELETE")
        }
        let sortedKeys = primaryKey.keys.sorted()
        let whereExpr = sortedKeys
            .map { "\(SQLIdentifier.mysql($0)) = ?" }
            .joined(separator: " AND ")
        let bindings: [QueryValue] = sortedKeys.map { .string(primaryKey[$0]!) }
        return ("DELETE FROM \(qualified) WHERE \(whereExpr) LIMIT 1", bindings)
    }

    public func updateTableMetadata(_ table: DatabaseObject, changes: TableMetadataChanges) async throws {
        guard changes.hasChanges else { return }
        let db = table.parent ?? currentDatabaseName
        let qualified = "\(SQLIdentifier.mysql(db)).\(SQLIdentifier.mysql(table.name))"

        var statements: [(sql: String, bindings: [QueryValue])] = []
        if let engine = changes.newEngine {
            statements.append(("ALTER TABLE \(qualified) ENGINE=\(engine)", []))
        }
        if let charset = changes.newCharset {
            // CONVERT TO CHARACTER SET 会同时改所有列的字符集；如果只想改默认 charset
            // 可用 DEFAULT CHARSET=...，但 collation 必须配套，所以这里直接整张表 convert。
            if let collation = changes.newCollation {
                statements.append(("ALTER TABLE \(qualified) CONVERT TO CHARACTER SET \(charset) COLLATE \(collation)", []))
            } else {
                statements.append(("ALTER TABLE \(qualified) CONVERT TO CHARACTER SET \(charset)", []))
            }
        } else if let collation = changes.newCollation {
            // 单独改 collation（charset 不变）
            statements.append(("ALTER TABLE \(qualified) COLLATE \(collation)", []))
        }
        if let comment = changes.newComment {
            statements.append(("ALTER TABLE \(qualified) COMMENT = ?", [.string(comment)]))
        }

        for stmt in statements {
            _ = try await runQuery(stmt.sql, bindings: stmt.bindings)
        }
    }
}
