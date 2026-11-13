import Foundation
import NIOCore
import MySQLNIO

extension MySQLDatabaseClient {
    public func listTables(in database: String?) async throws -> [DatabaseObject] {
        let dbName = database ?? currentDatabaseName
        // 旧实现走 information_schema.TABLES，busy server 上会锁元数据；SHOW FULL TABLES
        // 走 storage engine 直接读，更快。第一列是表名，第二列是 'BASE TABLE' / 'VIEW'。
        let result = try await runQuery("SHOW FULL TABLES FROM \(SQLIdentifier.mysql(dbName))")
        return result.rows.compactMap { row -> DatabaseObject? in
            guard row.indices.contains(0), let name = row[0] else { return nil }
            let typeStr = (row.indices.contains(1) ? row[1] : nil) ?? ""
            let kind: DatabaseObject.Kind = typeStr.uppercased().contains("VIEW") ? .view : .table
            return DatabaseObject(id: name, name: name, kind: kind, parent: dbName)
        }
    }

    public func tableStructure(_ table: DatabaseObject) async throws -> QueryResult {
        let db = table.parent ?? currentDatabaseName
        let sql = """
        SELECT
          COLUMN_NAME AS '字段',
          COLUMN_TYPE AS '类型',
          IS_NULLABLE AS '可空',
          COLUMN_DEFAULT AS '默认值',
          COLUMN_KEY AS '键',
          EXTRA AS '附加',
          COLUMN_COMMENT AS '注释'
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        ORDER BY ORDINAL_POSITION
        """
        return try await runQuery(sql, bindings: [.string(db), .string(table.name)])
    }

    public func tableContents(_ table: DatabaseObject, limit: Int, offset: Int, whereClause: String) async throws -> QueryResult {
        let db = table.parent ?? currentDatabaseName
        var sql = "SELECT * FROM \(SQLIdentifier.mysql(db)).\(SQLIdentifier.mysql(table.name))"
        let trimmed = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sql += " WHERE \(trimmed)"
        }
        sql += " LIMIT \(limit) OFFSET \(offset)"
        return try await runQuery(sql)
    }

    public func countRows(_ table: DatabaseObject, whereClause: String) async throws -> Int? {
        let db = table.parent ?? currentDatabaseName
        var sql = "SELECT COUNT(*) FROM \(SQLIdentifier.mysql(db)).\(SQLIdentifier.mysql(table.name))"
        let trimmed = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sql += " WHERE \(trimmed)"
        }
        let result = try await runQuery(sql)
        guard let value = result.rows.first?.first ?? nil else { return nil }
        return Int(value)
    }

    public func tableForeignKeys(_ table: DatabaseObject) async throws -> QueryResult {
        let db = table.parent ?? currentDatabaseName
        let sql = """
        SELECT
          k.CONSTRAINT_NAME AS '约束名',
          k.COLUMN_NAME AS '本表字段',
          k.REFERENCED_TABLE_SCHEMA AS '目标库',
          k.REFERENCED_TABLE_NAME AS '目标表',
          k.REFERENCED_COLUMN_NAME AS '目标字段',
          r.UPDATE_RULE AS '更新',
          r.DELETE_RULE AS '删除'
        FROM information_schema.KEY_COLUMN_USAGE k
        LEFT JOIN information_schema.REFERENTIAL_CONSTRAINTS r
          ON r.CONSTRAINT_SCHEMA = k.TABLE_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
        WHERE k.TABLE_SCHEMA = ?
          AND k.TABLE_NAME = ?
          AND k.REFERENCED_TABLE_NAME IS NOT NULL
        ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
        """
        return try await runQuery(sql, bindings: [.string(db), .string(table.name)])
    }

    public func tableTriggers(_ table: DatabaseObject) async throws -> QueryResult {
        let db = table.parent ?? currentDatabaseName
        let sql = """
        SELECT
          TRIGGER_NAME AS '名称',
          EVENT_MANIPULATION AS '事件',
          ACTION_TIMING AS '时机',
          ACTION_ORIENTATION AS '粒度',
          ACTION_STATEMENT AS '动作'
        FROM information_schema.TRIGGERS
        WHERE EVENT_OBJECT_SCHEMA = ?
          AND EVENT_OBJECT_TABLE = ?
        ORDER BY TRIGGER_NAME
        """
        return try await runQuery(sql, bindings: [.string(db), .string(table.name)])
    }

    public func tableInfo(_ table: DatabaseObject) async throws -> QueryResult {
        let db = table.parent ?? currentDatabaseName
        let sql = """
        SELECT
          CONCAT(?, '.', ?) AS '表',
          ENGINE AS '引擎',
          ROW_FORMAT AS '行格式',
          TABLE_ROWS AS '估算行数',
          AVG_ROW_LENGTH AS '平均行长',
          DATA_LENGTH AS '数据大小',
          INDEX_LENGTH AS '索引大小',
          DATA_FREE AS '剩余空间',
          AUTO_INCREMENT AS '下一自增',
          TABLE_COLLATION AS '排序规则',
          CREATE_TIME AS '创建时间',
          UPDATE_TIME AS '更新时间',
          TABLE_COMMENT AS '注释'
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        """
        return try await runQuery(
            sql,
            bindings: [.string(db), .string(table.name), .string(db), .string(table.name)]
        )
    }

    public func tableInfoDetailed(_ table: DatabaseObject) async throws -> TableInfoDetail {
        let db = table.parent ?? currentDatabaseName

        // 1. 基础元信息
        let metaSQL = """
        SELECT
          ENGINE, ROW_FORMAT, TABLE_ROWS, AVG_ROW_LENGTH,
          DATA_LENGTH, MAX_DATA_LENGTH, INDEX_LENGTH, DATA_FREE,
          AUTO_INCREMENT, TABLE_COLLATION, CREATE_TIME, UPDATE_TIME,
          TABLE_COMMENT
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        """
        let metaResult = try await runQuery(metaSQL, bindings: [.string(db), .string(table.name)])
        guard let row = metaResult.rows.first else {
            return TableInfoDetail(tableName: table.name, schema: db)
        }
        let collation = row[safeRow: 9]
        let charset = collation?.split(separator: "_").first.map(String.init)

        // 2. SHOW CREATE TABLE 取 DDL
        let createSQL = "SHOW CREATE TABLE \(SQLIdentifier.mysql(db)).\(SQLIdentifier.mysql(table.name))"
        let createResult = try await runQuery(createSQL)
        // 返回两列：Table, Create Table
        let createSyntax = createResult.rows.first?[safeRow: 1]

        return TableInfoDetail(
            tableName: table.name,
            schema: db,
            engine: row[safeRow: 0],
            charset: charset,
            collation: collation,
            rowCount: row[safeRow: 2].flatMap(Int.init),
            rowFormat: row[safeRow: 1],
            avgRowLength: row[safeRow: 3].flatMap(Int.init),
            autoIncrement: row[safeRow: 8].flatMap(Int.init),
            dataSize: row[safeRow: 4].flatMap(Int.init),
            maxDataSize: row[safeRow: 5].flatMap(Int.init),
            indexSize: row[safeRow: 6].flatMap(Int.init),
            freeDataSize: row[safeRow: 7].flatMap(Int.init),
            createdAt: row[safeRow: 10],
            updatedAt: row[safeRow: 11],
            comment: row[safeRow: 12],
            createSyntax: createSyntax
        )
    }

    public func tableColumnDefinitions(_ table: DatabaseObject) async throws -> [ColumnDefinition] {
        let db = table.parent ?? currentDatabaseName
        let sql = """
        SELECT
          COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT,
          COLUMN_KEY, EXTRA, COLUMN_COMMENT, COLLATION_NAME
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        ORDER BY ORDINAL_POSITION
        """
        let result = try await runQuery(sql, bindings: [.string(db), .string(table.name)])
        return result.rows.compactMap { row -> ColumnDefinition? in
            guard let name = row[safeRow: 0], !name.isEmpty else { return nil }
            return ColumnDefinition(
                name: name,
                dataType: row[safeRow: 1] ?? "",
                nullable: (row[safeRow: 2] ?? "YES").uppercased() == "YES",
                defaultValue: row[safeRow: 3],
                isPrimaryKey: (row[safeRow: 4] ?? "") == "PRI",
                isAutoIncrement: (row[safeRow: 5] ?? "").lowercased().contains("auto_increment"),
                comment: row[safeRow: 6],
                collation: row[safeRow: 7]
            )
        }
    }

    public func tableIndexDefinitions(_ table: DatabaseObject) async throws -> [IndexDefinition] {
        let db = table.parent ?? currentDatabaseName
        let sql = """
        SELECT INDEX_NAME, NON_UNIQUE, INDEX_TYPE, COLUMN_NAME, SEQ_IN_INDEX, INDEX_COMMENT
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        ORDER BY INDEX_NAME, SEQ_IN_INDEX
        """
        let result = try await runQuery(sql, bindings: [.string(db), .string(table.name)])
        // 按 INDEX_NAME 聚合
        var grouped: [String: (rows: [[String?]], firstRow: [String?])] = [:]
        var order: [String] = []
        for row in result.rows {
            guard let n = row.first ?? nil else { continue }
            if grouped[n] == nil {
                grouped[n] = (rows: [row], firstRow: row)
                order.append(n)
            } else {
                grouped[n]!.rows.append(row)
            }
        }
        return order.compactMap { name -> IndexDefinition? in
            guard let bundle = grouped[name] else { return nil }
            let nonUnique = bundle.firstRow[safeRow: 1] ?? "1"
            let indexType = bundle.firstRow[safeRow: 2] ?? "BTREE"
            let comment = bundle.firstRow[safeRow: 5]

            // category 判定：
            //  - PRIMARY 直接是主键
            //  - NON_UNIQUE = 0 → UNIQUE
            //  - INDEX_TYPE = FULLTEXT / SPATIAL → 对应类
            //  - 否则普通
            let category: IndexCategory
            if name == "PRIMARY" {
                category = .primary
            } else if indexType.uppercased() == "FULLTEXT" {
                category = .fulltext
            } else if indexType.uppercased() == "SPATIAL" {
                category = .spatial
            } else if nonUnique == "0" {
                category = .unique
            } else {
                category = .normal
            }

            let cols = bundle.rows.compactMap { $0[safeRow: 3] }
            return IndexDefinition(
                name: name,
                category: category,
                columns: cols,
                method: indexType,
                comment: (comment?.isEmpty == false) ? comment : nil
            )
        }
    }
}
