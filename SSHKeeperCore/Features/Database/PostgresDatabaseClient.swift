import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO
import Logging
import os

public actor PostgresDatabaseClient: DatabaseClient {
    private let database: Database
    private let password: String
    private var connection: PostgresConnection?
    private var currentDatabase: String
    private let logger: Logger
    private var tunnel: SSHTunnel?

    private static var eventLoopGroup: MultiThreadedEventLoopGroup {
        DatabaseEventLoopGroup.shared
    }

    public init(database: Database, password: String) {
        self.database = database
        self.password = password
        self.currentDatabase = database.defaultDatabase
        var l = Logger(label: "sshkeeper.postgres.\(database.id)")
        l.logLevel = .warning
        self.logger = l
    }

    public func connect() async throws {
        // 隧道：与 MySQL 客户端同样逻辑，配置了 sshHostAlias 时把流量先经本地端口转发
        var connectHost = database.host
        var connectPort = database.port
        if let alias = database.sshHostAlias, !alias.isEmpty {
            let t = SSHTunnel(sshHostAlias: alias, targetHost: database.host, targetPort: database.port)
            do {
                try await t.start()
            } catch {
                throw DatabaseClientError.connectionFailed(error.localizedDescription)
            }
            guard let lport = await t.localPort else {
                throw DatabaseClientError.connectionFailed("SSH 隧道启动后未拿到本地端口")
            }
            self.tunnel = t
            connectHost = "127.0.0.1"
            connectPort = lport
        }
        try await openConnection(database: currentDatabase, host: connectHost, port: connectPort)
    }

    public func close() async {
        if let conn = connection {
            try? await conn.close()
        }
        connection = nil
        if let t = tunnel {
            await t.stop()
        }
        tunnel = nil
    }

    public func switchDatabase(_ name: String) async throws {
        // PG 切库依赖 close + reconnect，要保留隧道（不要关 tunnel）
        if let conn = connection {
            try? await conn.close()
        }
        connection = nil
        currentDatabase = name
        // 隧道还在 → 复用同一 lport
        let host: String
        let port: Int
        if let t = tunnel, let lport = await t.localPort {
            host = "127.0.0.1"
            port = lport
        } else {
            host = database.host
            port = database.port
        }
        try await openConnection(database: name, host: host, port: port)
    }

    public func runQuery(_ sql: String) async throws -> QueryResult {
        try await runQuery(sql, bindings: [])
    }

    public func runQuery(_ sql: String, bindings: [QueryValue]) async throws -> QueryResult {
        guard let conn = connection else { throw DatabaseClientError.notConnected }
        let pgSQL: String
        let pgBinds: PostgresBindings
        if bindings.isEmpty {
            pgSQL = sql
            pgBinds = PostgresBindings()
        } else {
            // 把 `?` 改成 `$1, $2, ...`，再按顺序填 PostgresBindings
            pgSQL = QueryValue.mysqlPlaceholdersToPostgres(sql)
            var binds = PostgresBindings(capacity: bindings.count)
            for value in bindings {
                Self.append(value, to: &binds)
            }
            pgBinds = binds
        }
        let start = Date()
        do {
            // PostgresNIO 的结果是流式 AsyncSequence — 超过阈值直接 break 即可，
            // 服务端会在 stream 取消时停止发送。
            let stream = try await conn.query(PostgresQuery(unsafeSQL: pgSQL, binds: pgBinds), logger: logger)
            var columns: [String] = []
            var rows: [[String?]] = []
            var truncated = false
            for try await row in stream {
                let access = row.makeRandomAccess()
                if columns.isEmpty {
                    columns = (0..<access.count).map { access[$0].columnName }
                }
                if rows.count >= maxClientResultRows {
                    truncated = true
                    break
                }
                var rowValues: [String?] = []
                rowValues.reserveCapacity(access.count)
                for i in 0..<access.count {
                    rowValues.append(Self.cellToString(access[i]))
                }
                rows.append(rowValues)
            }
            return QueryResult(
                columns: columns,
                rows: rows,
                rowsAffected: rows.count,
                executionTime: Date().timeIntervalSince(start),
                isTruncated: truncated
            )
        } catch let error as PSQLError {
            let serverMsg = error.serverInfo?[.message] ?? "\(error)"
            throw DatabaseClientError.queryFailed(
                DatabaseErrorTranslator.translate(
                    NSError(domain: "PSQLError", code: 0, userInfo: [NSLocalizedDescriptionKey: serverMsg]),
                    context: .query
                )
            )
        } catch {
            throw DatabaseClientError.queryFailed(
                DatabaseErrorTranslator.translate(error, context: .query)
            )
        }
    }

    public func listDatabases() async throws -> [String] {
        let result = try await runQuery(
            "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
        )
        return result.rows.compactMap { $0.first ?? nil }
    }

    public func listTables(in database: String?) async throws -> [DatabaseObject] {
        let sql = """
        SELECT table_schema, table_name, table_type
        FROM information_schema.tables
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY table_schema, table_name
        """
        let result = try await runQuery(sql)
        return result.rows.compactMap { row -> DatabaseObject? in
            guard row.count >= 3,
                  let schema = row[0],
                  let name = row[1] else { return nil }
            let kind: DatabaseObject.Kind = (row[2] == "VIEW") ? .view : .table
            return DatabaseObject(
                id: "\(schema).\(name)",
                name: "\(schema).\(name)",
                kind: kind,
                parent: schema
            )
        }
    }

    public func tableStructure(_ table: DatabaseObject) async throws -> QueryResult {
        let (schema, name) = Self.splitQualifiedName(table)
        let sql = """
        SELECT
          c.column_name AS "字段",
          c.data_type AS "类型",
          c.character_maximum_length AS "长度",
          c.is_nullable AS "可空",
          c.column_default AS "默认值",
          CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE '' END AS "主键",
          col_description((quote_ident('\(escape(schema))') || '.' || quote_ident('\(escape(name))'))::regclass, c.ordinal_position) AS "注释"
        FROM information_schema.columns c
        LEFT JOIN (
          SELECT a.attname AS column_name
          FROM pg_index i
          JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
          WHERE i.indrelid = (quote_ident('\(escape(schema))') || '.' || quote_ident('\(escape(name))'))::regclass AND i.indisprimary
        ) pk ON pk.column_name = c.column_name
        WHERE c.table_schema = '\(escape(schema))' AND c.table_name = '\(escape(name))'
        ORDER BY c.ordinal_position
        """
        return try await runQuery(sql)
    }

    public func tableContents(_ table: DatabaseObject, limit: Int, offset: Int, whereClause: String) async throws -> QueryResult {
        let (schema, name) = Self.splitQualifiedName(table)
        var sql = "SELECT * FROM \(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        let trimmed = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sql += " WHERE \(trimmed)"
        }
        sql += " LIMIT \(limit) OFFSET \(offset)"
        return try await runQuery(sql)
    }

    public func countRows(_ table: DatabaseObject, whereClause: String) async throws -> Int? {
        let (schema, name) = Self.splitQualifiedName(table)
        var sql = "SELECT COUNT(*) FROM \(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        let trimmed = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sql += " WHERE \(trimmed)"
        }
        let result = try await runQuery(sql)
        guard let value = result.rows.first?.first ?? nil else { return nil }
        return Int(value)
    }

    public func tableInfoDetailed(_ table: DatabaseObject) async throws -> TableInfoDetail {
        let (schema, name) = Self.splitQualifiedName(table)
        // Postgres 没有 engine / charset / collation 这种表层概念；只填能查到的几个。
        let sql = """
        SELECT
          obj_description((quote_ident('\(escape(schema))') || '.' || quote_ident('\(escape(name))'))::regclass) AS comment,
          pg_size_pretty(pg_relation_size(quote_ident('\(escape(schema))') || '.' || quote_ident('\(escape(name))'))) AS data,
          pg_size_pretty(pg_indexes_size(quote_ident('\(escape(schema))') || '.' || quote_ident('\(escape(name))'))) AS idx,
          (SELECT n_live_tup FROM pg_stat_user_tables WHERE schemaname = '\(escape(schema))' AND relname = '\(escape(name))') AS rows
        """
        let result = try await runQuery(sql)
        let row = result.rows.first ?? []
        return TableInfoDetail(
            tableName: name,
            schema: schema,
            engine: "PostgreSQL",
            rowCount: row.indices.contains(3) ? row[3].flatMap(Int.init) : nil,
            comment: row.indices.contains(0) ? row[0] : nil
        )
    }

    public func updateTableMetadata(_ table: DatabaseObject, changes: TableMetadataChanges) async throws {
        // 只支持改注释；其他 PG 不支持表级编码 / 引擎切换
        guard let comment = changes.newComment else {
            throw DatabaseClientError.invalidConfiguration("PostgreSQL 不支持改表引擎 / 编码 / 排序规则")
        }
        let (schema, name) = Self.splitQualifiedName(table)
        let sql = "COMMENT ON TABLE \(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name)) IS '\(escape(comment))'"
        _ = try await runQuery(sql)
    }

    public func tableColumnDefinitions(_ table: DatabaseObject) async throws -> [ColumnDefinition] {
        let (schema, name) = Self.splitQualifiedName(table)
        let sql = """
        SELECT
          c.column_name,
          c.data_type ||
            CASE
              WHEN c.character_maximum_length IS NOT NULL THEN '(' || c.character_maximum_length || ')'
              ELSE ''
            END AS full_type,
          c.is_nullable,
          c.column_default,
          CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE 'NO' END AS is_pk,
          col_description((quote_ident('\(escape(schema))') || '.' || quote_ident('\(escape(name))'))::regclass, c.ordinal_position) AS comment
        FROM information_schema.columns c
        LEFT JOIN (
          SELECT a.attname AS column_name
          FROM pg_index i
          JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
          WHERE i.indrelid = (quote_ident('\(escape(schema))') || '.' || quote_ident('\(escape(name))'))::regclass AND i.indisprimary
        ) pk ON pk.column_name = c.column_name
        WHERE c.table_schema = '\(escape(schema))' AND c.table_name = '\(escape(name))'
        ORDER BY c.ordinal_position
        """
        let result = try await runQuery(sql)
        return result.rows.compactMap { row -> ColumnDefinition? in
            guard let n = row.first ?? nil, !n.isEmpty else { return nil }
            let nullable: Bool = {
                guard row.indices.contains(2), let s = row[2] else { return true }
                return s.uppercased() == "YES"
            }()
            let isPK: Bool = {
                guard row.indices.contains(4), let s = row[4] else { return false }
                return s == "YES"
            }()
            return ColumnDefinition(
                name: n,
                dataType: row.indices.contains(1) ? (row[1] ?? "") : "",
                nullable: nullable,
                defaultValue: row.indices.contains(3) ? row[3] : nil,
                isPrimaryKey: isPK,
                comment: row.indices.contains(5) ? row[5] : nil
            )
        }
    }

    public func addColumn(_ table: DatabaseObject, column: ColumnDefinition, after: String?) async throws {
        // PG 不支持 AFTER（列序固定），忽略 after 参数
        let (schema, name) = Self.splitQualifiedName(table)
        let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        var spec = "\(SQLIdentifier.postgres(column.name)) \(column.dataType) \(column.nullable ? "NULL" : "NOT NULL")"
        if let def = column.defaultValue, !def.isEmpty {
            spec += " DEFAULT \(def)"
        }
        _ = try await runQuery("ALTER TABLE \(qualified) ADD COLUMN \(spec)")
        if let comment = column.comment, !comment.isEmpty {
            _ = try await runQuery(
                "COMMENT ON COLUMN \(qualified).\(SQLIdentifier.postgres(column.name)) IS '\(escape(comment))'"
            )
        }
    }

    public func dropColumn(_ table: DatabaseObject, columnName: String) async throws {
        let (schema, name) = Self.splitQualifiedName(table)
        let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        _ = try await runQuery("ALTER TABLE \(qualified) DROP COLUMN \(SQLIdentifier.postgres(columnName))")
    }

    public func tableIndexDefinitions(_ table: DatabaseObject) async throws -> [IndexDefinition] {
        let (schema, name) = Self.splitQualifiedName(table)
        let sql = """
        SELECT
          c.relname AS index_name,
          i.indisunique AS is_unique,
          i.indisprimary AS is_primary,
          am.amname AS method,
          pg_get_indexdef(i.indexrelid) AS def
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_class t ON t.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_am am ON am.oid = c.relam
        WHERE n.nspname = '\(escape(schema))' AND t.relname = '\(escape(name))'
        ORDER BY c.relname
        """
        let result = try await runQuery(sql)
        return result.rows.compactMap { row -> IndexDefinition? in
            guard let idxName = row.first ?? nil else { return nil }
            let isUnique = (row.indices.contains(1) ? row[1] : nil) == "t" || (row.indices.contains(1) ? row[1] : nil) == "true"
            let isPrimary = (row.indices.contains(2) ? row[2] : nil) == "t" || (row.indices.contains(2) ? row[2] : nil) == "true"
            let method = row.indices.contains(3) ? row[3] : nil
            let def = row.indices.contains(4) ? (row[4] ?? "") : ""
            // 从 indexdef 抠出字段列表（括号内）
            var cols: [String] = []
            if let lparen = def.firstIndex(of: "("),
               let rparen = def.lastIndex(of: ")") {
                let inner = def[def.index(after: lparen)..<rparen]
                cols = inner.split(separator: ",").map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                }
            }
            return IndexDefinition(
                name: idxName,
                category: isPrimary ? .primary : (isUnique ? .unique : .normal),
                columns: cols,
                method: method
            )
        }
    }

    public func addIndex(_ table: DatabaseObject, index: IndexDefinition) async throws {
        guard !index.columns.isEmpty else {
            throw DatabaseClientError.invalidConfiguration("索引必须至少包含一个字段")
        }
        let (schema, name) = Self.splitQualifiedName(table)
        let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        let cols = index.columns.map { SQLIdentifier.postgres($0) }.joined(separator: ", ")
        switch index.category {
        case .primary:
            _ = try await runQuery("ALTER TABLE \(qualified) ADD PRIMARY KEY (\(cols))")
        case .unique:
            _ = try await runQuery("CREATE UNIQUE INDEX \(SQLIdentifier.postgres(index.name)) ON \(qualified) (\(cols))")
        case .normal:
            var sql = "CREATE INDEX \(SQLIdentifier.postgres(index.name)) ON \(qualified)"
            if let method = index.method, !method.isEmpty {
                sql += " USING \(method)"
            }
            sql += " (\(cols))"
            _ = try await runQuery(sql)
        case .fulltext, .spatial:
            throw DatabaseClientError.invalidConfiguration("PostgreSQL 不支持 FULLTEXT/SPATIAL 索引（用 GIN/GIST 自定义）")
        }
    }

    public func dropIndex(_ table: DatabaseObject, indexName: String) async throws {
        let (schema, _) = Self.splitQualifiedName(table)
        // PG 索引在 schema 下，不挂表名
        _ = try await runQuery("DROP INDEX \(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(indexName))")
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
        // database 实际上是 schema 名（PG 没"切库"概念，PG 的 database 用 currentDatabase）
        let qualified = "\(SQLIdentifier.postgres(database)).\(SQLIdentifier.postgres(name))"
        var lines: [String] = columns.map { col -> String in
            var spec = "\(SQLIdentifier.postgres(col.name)) \(col.dataType) \(col.nullable ? "NULL" : "NOT NULL")"
            if let def = col.defaultValue, !def.isEmpty {
                spec += " DEFAULT \(def)"
            }
            return spec
        }
        if !primaryKeys.isEmpty {
            let pks = primaryKeys.map { SQLIdentifier.postgres($0) }.joined(separator: ", ")
            lines.append("PRIMARY KEY (\(pks))")
        }
        let body = lines.joined(separator: ",\n  ")
        let sql = "CREATE TABLE \(qualified) (\n  \(body)\n)"
        _ = try await runQuery(sql)

        // PG 的列注释要分开发
        for col in columns {
            if let comment = col.comment, !comment.isEmpty {
                _ = try await runQuery(
                    "COMMENT ON COLUMN \(qualified).\(SQLIdentifier.postgres(col.name)) IS '\(escape(comment))'"
                )
            }
        }
    }

    public func dropTable(_ table: DatabaseObject) async throws {
        let (schema, name) = Self.splitQualifiedName(table)
        let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        _ = try await runQuery("DROP TABLE \(qualified)")
    }

    public func truncateTable(_ table: DatabaseObject) async throws {
        let (schema, name) = Self.splitQualifiedName(table)
        let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        // RESTART IDENTITY 显式重置 OWNED BY 该表的所有 sequence，
        // 与 MySQL TRUNCATE 重置 AUTO_INCREMENT 的语义对齐。
        _ = try await runQuery("TRUNCATE TABLE \(qualified) RESTART IDENTITY")
    }

    public func deleteAllRows(_ table: DatabaseObject) async throws {
        let (schema, name) = Self.splitQualifiedName(table)
        let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        _ = try await runQuery("DELETE FROM \(qualified)")
    }

    public func renameTable(_ table: DatabaseObject, to newName: String) async throws {
        let (schema, name) = Self.splitQualifiedName(table)
        let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        _ = try await runQuery("ALTER TABLE \(qualified) RENAME TO \(SQLIdentifier.postgres(newName))")
    }

    public func duplicateTable(_ table: DatabaseObject, newName: String, includeData: Bool) async throws {
        let (schema, name) = Self.splitQualifiedName(table)
        let oldQ = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        let newQ = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(newName))"
        // INCLUDING ALL 拷索引 / 默认值 / 约束（除外键）
        _ = try await runQuery("CREATE TABLE \(newQ) (LIKE \(oldQ) INCLUDING ALL)")
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
        let (schema, name) = Self.splitQualifiedName(table)
        let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        var bindings: [QueryValue] = []
        bindings.append(value.map { .string($0) } ?? .null)
        let sortedKeys = primaryKey.keys.sorted()
        for k in sortedKeys { bindings.append(.string(primaryKey[k]!)) }
        let whereExpr = sortedKeys.map { "\(SQLIdentifier.postgres($0)) = ?" }.joined(separator: " AND ")
        _ = try await runQuery(
            "UPDATE \(qualified) SET \(SQLIdentifier.postgres(column)) = ? WHERE \(whereExpr)",
            bindings: bindings
        )
    }

    public func insertRow(_ table: DatabaseObject, values: [String: String?]) async throws {
        let (schema, name) = Self.splitQualifiedName(table)
        let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        let (sql, bindings) = try Self.insertSQL(qualified: qualified, values: values)
        _ = try await runQuery(sql, bindings: bindings)
    }

    public func deleteRow(_ table: DatabaseObject, primaryKey: [String: String]) async throws {
        let (schema, name) = Self.splitQualifiedName(table)
        let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        let (sql, bindings) = try Self.deleteSQL(qualified: qualified, primaryKey: primaryKey)
        _ = try await runQuery(sql, bindings: bindings)
    }

    /// 纯字符串构建，可独立测试。`qualified` 由调用方算好（含 schema + 双引号转义）。
    static func insertSQL(
        qualified: String,
        values: [String: String?]
    ) throws -> (sql: String, bindings: [QueryValue]) {
        guard !values.isEmpty else {
            throw DatabaseClientError.invalidConfiguration("至少要提供一列的值")
        }
        let keys = values.keys.sorted()
        let cols = keys.map { SQLIdentifier.postgres($0) }.joined(separator: ", ")
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
            .map { "\(SQLIdentifier.postgres($0)) = ?" }
            .joined(separator: " AND ")
        let bindings: [QueryValue] = sortedKeys.map { .string(primaryKey[$0]!) }
        // PG 不支持 DELETE ... LIMIT；靠 PK 唯一性保证只删一行
        return ("DELETE FROM \(qualified) WHERE \(whereExpr)", bindings)
    }

    public func modifyColumn(_ table: DatabaseObject, oldName: String, column: ColumnDefinition) async throws {
        let (schema, name) = Self.splitQualifiedName(table)
        let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
        // PG 必须分多条 ALTER：rename → type → null → default → comment
        if oldName != column.name {
            _ = try await runQuery("ALTER TABLE \(qualified) RENAME COLUMN \(SQLIdentifier.postgres(oldName)) TO \(SQLIdentifier.postgres(column.name))")
        }
        let colIdent = SQLIdentifier.postgres(column.name)
        _ = try await runQuery("ALTER TABLE \(qualified) ALTER COLUMN \(colIdent) TYPE \(column.dataType)")
        if column.nullable {
            _ = try await runQuery("ALTER TABLE \(qualified) ALTER COLUMN \(colIdent) DROP NOT NULL")
        } else {
            _ = try await runQuery("ALTER TABLE \(qualified) ALTER COLUMN \(colIdent) SET NOT NULL")
        }
        if let def = column.defaultValue, !def.isEmpty {
            _ = try await runQuery("ALTER TABLE \(qualified) ALTER COLUMN \(colIdent) SET DEFAULT \(def)")
        } else {
            _ = try await runQuery("ALTER TABLE \(qualified) ALTER COLUMN \(colIdent) DROP DEFAULT")
        }
        if let comment = column.comment {
            _ = try await runQuery("COMMENT ON COLUMN \(qualified).\(colIdent) IS '\(escape(comment))'")
        }
    }

    public func tableForeignKeys(_ table: DatabaseObject) async throws -> QueryResult {
        let (schema, name) = Self.splitQualifiedName(table)
        let sql = """
        SELECT
          tc.constraint_name AS "约束名",
          kcu.column_name AS "本表字段",
          ccu.table_schema AS "目标 schema",
          ccu.table_name AS "目标表",
          ccu.column_name AS "目标字段",
          rc.update_rule AS "更新",
          rc.delete_rule AS "删除"
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
        JOIN information_schema.constraint_column_usage ccu
          ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
        JOIN information_schema.referential_constraints rc
          ON rc.constraint_name = tc.constraint_name AND rc.constraint_schema = tc.table_schema
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND tc.table_schema = '\(escape(schema))'
          AND tc.table_name = '\(escape(name))'
        ORDER BY tc.constraint_name
        """
        return try await runQuery(sql)
    }

    public func tableTriggers(_ table: DatabaseObject) async throws -> QueryResult {
        let (schema, name) = Self.splitQualifiedName(table)
        let sql = """
        SELECT
          trigger_name AS "名称",
          event_manipulation AS "事件",
          action_timing AS "时机",
          action_orientation AS "粒度",
          action_statement AS "动作"
        FROM information_schema.triggers
        WHERE event_object_schema = '\(escape(schema))'
          AND event_object_table = '\(escape(name))'
        ORDER BY trigger_name
        """
        return try await runQuery(sql)
    }

    public func tableInfo(_ table: DatabaseObject) async throws -> QueryResult {
        let (schema, name) = Self.splitQualifiedName(table)
        let qualified = "\(schema).\(name)"
        let sql = """
        SELECT
          '\(escape(qualified))' AS "表",
          (SELECT pg_size_pretty(pg_total_relation_size(quote_ident('\(escape(schema))') || '.' || quote_ident('\(escape(name))')))) AS "总大小",
          (SELECT pg_size_pretty(pg_relation_size(quote_ident('\(escape(schema))') || '.' || quote_ident('\(escape(name))')))) AS "数据大小",
          (SELECT pg_size_pretty(pg_indexes_size(quote_ident('\(escape(schema))') || '.' || quote_ident('\(escape(name))')))) AS "索引大小",
          (SELECT n_live_tup FROM pg_stat_user_tables WHERE schemaname = '\(escape(schema))' AND relname = '\(escape(name))') AS "估算行数",
          (SELECT obj_description((quote_ident('\(escape(schema))') || '.' || quote_ident('\(escape(name))'))::regclass)) AS "表注释",
          (SELECT string_agg(indexname || ' (' || indexdef || ')', E'\n') FROM pg_indexes WHERE schemaname = '\(escape(schema))' AND tablename = '\(escape(name))') AS "索引"
        """
        return try await runQuery(sql)
    }

    private static func splitQualifiedName(_ table: DatabaseObject) -> (schema: String, name: String) {
        if let parent = table.parent {
            // table.name is "schema.name"; strip schema prefix to get bare name
            let prefix = parent + "."
            let bare = table.name.hasPrefix(prefix)
                ? String(table.name.dropFirst(prefix.count))
                : table.name
            return (parent, bare)
        }
        let parts = table.name.split(separator: ".", maxSplits: 1).map(String.init)
        if parts.count == 2 { return (parts[0], parts[1]) }
        return ("public", table.name)
    }

    private func escape(_ s: String) -> String {
        SQLEscape.postgres(s)
    }

    private func openConnection(database: String, host: String? = nil, port: Int? = nil) async throws {
        let connectHost = host ?? self.database.host
        let connectPort = port ?? self.database.port
        let tlsConfig: PostgresConnection.Configuration.TLS
        switch self.database.tlsMode {
        case .disable:
            tlsConfig = .disable
        case .prefer, .require:
            var ssl = TLSConfiguration.makeClientConfiguration()
            if self.database.allowSelfSignedTLS {
                ssl.certificateVerification = .none
            }
            let context = try NIOSSLContext(configuration: ssl)
            tlsConfig = (self.database.tlsMode == .require)
                ? .require(context)
                : .prefer(context)
        }

        let config = PostgresConnection.Configuration(
            host: connectHost,
            port: connectPort,
            username: self.database.username,
            password: password,
            database: database,
            tls: tlsConfig
        )

        do {
            connection = try await PostgresConnection.connect(
                on: Self.eventLoopGroup.next(),
                configuration: config,
                id: Self.nextConnectionID(),
                logger: logger
            )
        } catch {
            throw DatabaseClientError.connectionFailed(
                DatabaseErrorTranslator.translate(error, context: .connect)
            )
        }
    }

    /// 跨 actor 共享单实例，省掉每行/每单元格 new 一个 formatter 的开销。
    /// `nonisolated(unsafe)`：Foundation 文档保证 ISO8601DateFormatter 线程安全，
    /// 但 Swift 6 strict concurrency 不识别这条保证。
    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()

    /// PostgresNIO 用 connection id 给日志 / metrics 打 tag，要求全进程单调唯一。
    /// 旧实现 `Int.random(in: 1...Int.max)` 极小概率冲突；改成 unfair lock 保护的
    /// 单调计数器（连接创建是稀有事件，加锁开销可忽略）。
    private static let connectionIDLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    private static func nextConnectionID() -> Int {
        connectionIDLock.withLock { state in
            state &+= 1
            return state
        }
    }

    private static func append(_ value: QueryValue, to binds: inout PostgresBindings) {
        switch value {
        case .null: binds.appendNull()
        case .string(let s): binds.append(s)
        case .int(let i): binds.append(i)
        case .double(let d): binds.append(d)
        case .bool(let b): binds.append(b)
        case .data(let d):
            // Data 的 append 是 throwing；改用 ByteBuffer（NonThrowing）+ 同样编码为 bytea，
            // 让整个 helper 不需要 throws。
            var buf = ByteBuffer()
            buf.writeBytes(d)
            binds.append(buf)
        }
    }

    private static func cellToString(_ cell: PostgresCell) -> String? {
        guard cell.bytes != nil else { return nil }
        if let v = try? cell.decode(String.self, context: .default) { return v }
        if let v = try? cell.decode(Int64.self, context: .default) { return String(v) }
        if let v = try? cell.decode(Int32.self, context: .default) { return String(v) }
        if let v = try? cell.decode(Int16.self, context: .default) { return String(v) }
        if let v = try? cell.decode(Double.self, context: .default) { return String(v) }
        if let v = try? cell.decode(Float.self, context: .default) { return String(v) }
        if let v = try? cell.decode(Bool.self, context: .default) { return String(v) }
        if let v = try? cell.decode(Date.self, context: .default) {
            return iso8601Formatter.string(from: v)
        }
        if let v = try? cell.decode(UUID.self, context: .default) { return v.uuidString }
        return "<\(cell.dataType)>"
    }
}
