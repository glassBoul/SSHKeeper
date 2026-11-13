import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import MySQLNIO
import Logging

/// MySQL 客户端核心：连接生命周期 + 通用 query 执行 + 共享 helper。
/// 表 inspector 类查询拆到 `MySQLDatabaseClient+Inspector.swift`，
/// DDL / 行修改拆到 `MySQLDatabaseClient+Mutation.swift`。
public actor MySQLDatabaseClient: DatabaseClient {
    let database: Database
    let password: String
    var connection: MySQLConnection?
    var currentDatabaseName: String
    let logger: Logger
    var tunnel: SSHTunnel?

    static var eventLoopGroup: MultiThreadedEventLoopGroup {
        DatabaseEventLoopGroup.shared
    }

    public init(database: Database, password: String) {
        self.database = database
        self.password = password
        self.currentDatabaseName = database.defaultDatabase
        var l = Logger(label: "sshkeeper.mysql.\(database.id)")
        l.logLevel = .warning
        self.logger = l
    }

    public func connect() async throws {
        // 如果配置了 SSH 隧道，先把本地端口转发拉起来，再让 NIO 连 127.0.0.1:lport
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
        try await openConnection(database: currentDatabaseName, host: connectHost, port: connectPort)
    }

    public func close() async {
        if let conn = connection {
            try? await conn.close().get()
        }
        connection = nil
        if let t = tunnel {
            await t.stop()
        }
        tunnel = nil
    }

    public func switchDatabase(_ name: String) async throws {
        // 旧实现走 close + reconnect，每次切换浪费一次 TLS 握手；
        // MySQL 直接 `USE db` 就行，标识符要正确反引号转义。
        _ = try await runQuery("USE \(SQLIdentifier.mysql(name))")
        currentDatabaseName = name
    }

    public func runQuery(_ sql: String) async throws -> QueryResult {
        try await runQuery(sql, bindings: [])
    }

    public func runQuery(_ sql: String, bindings: [QueryValue]) async throws -> QueryResult {
        guard let conn = connection else { throw DatabaseClientError.notConnected }
        let start = Date()
        do {
            // MySQLNIO 的 query 把所有行 buffer 到内存后返回，service 端没法早 stop；
            // 但我们至少在 String? 转换/最终数组阶段截断，避免二次内存放大。
            //
            // 路径选择：
            // - 无 bindings → simpleQuery（文本协议 COM_QUERY）— 支持 USE / 多语句 等
            //   prepared 协议拒绝的命令；自由 SQL 编辑器走这条
            // - 有 bindings → query（prepared 协议 COM_STMT_PREPARE）— 真正参数化绑定
            let mysqlRows: [MySQLRow]
            if bindings.isEmpty {
                mysqlRows = try await conn.simpleQuery(sql).get()
            } else {
                let mysqlBinds = bindings.map { Self.toMySQLData($0) }
                mysqlRows = try await conn.query(sql, mysqlBinds).get()
            }
            var columns: [String] = []
            var rows: [[String?]] = []
            var truncated = false
            for row in mysqlRows {
                if columns.isEmpty {
                    columns = row.columnDefinitions.map { $0.name }
                }
                if rows.count >= maxClientResultRows {
                    truncated = true
                    break
                }
                var values: [String?] = []
                values.reserveCapacity(columns.count)
                for column in row.columnDefinitions {
                    let data = row.column(column.name)
                    values.append(Self.dataToString(data))
                }
                rows.append(values)
            }
            return QueryResult(
                columns: columns,
                rows: rows,
                rowsAffected: rows.count,
                executionTime: Date().timeIntervalSince(start),
                isTruncated: truncated
            )
        } catch {
            throw DatabaseClientError.queryFailed(
                DatabaseErrorTranslator.translate(error, context: .query)
            )
        }
    }

    public func listDatabases() async throws -> [String] {
        let result = try await runQuery("SHOW DATABASES")
        return result.rows.compactMap { $0.first ?? nil }
    }

    // MARK: - Helpers shared with extensions

    func qualifiedName(_ table: DatabaseObject) -> String {
        let db = table.parent ?? currentDatabaseName
        return "\(SQLIdentifier.mysql(db)).\(SQLIdentifier.mysql(table.name))"
    }

    func columnSpec(_ col: ColumnDefinition) -> String {
        var parts: [String] = ["\(SQLIdentifier.mysql(col.name)) \(col.dataType)"]
        if let coll = col.collation, !coll.isEmpty {
            let charset = coll.split(separator: "_").first.map(String.init) ?? ""
            if !charset.isEmpty {
                parts.append("CHARACTER SET \(charset) COLLATE \(coll)")
            }
        }
        parts.append(col.nullable ? "NULL" : "NOT NULL")
        if let def = col.defaultValue, !def.isEmpty {
            parts.append("DEFAULT \(def)")
        }
        if col.isAutoIncrement {
            parts.append("AUTO_INCREMENT")
        }
        if let comment = col.comment, !comment.isEmpty {
            parts.append("COMMENT '\(SQLEscape.mysql(comment))'")
        }
        return parts.joined(separator: " ")
    }

    func openConnection(database: String, host: String? = nil, port: Int? = nil) async throws {
        let connectHost = host ?? self.database.host
        let connectPort = port ?? self.database.port
        var tlsConfig: TLSConfiguration?
        switch self.database.tlsMode {
        case .disable:
            tlsConfig = nil
        case .prefer, .require:
            var ssl = TLSConfiguration.makeClientConfiguration()
            if self.database.allowSelfSignedTLS {
                ssl.certificateVerification = .none
            }
            tlsConfig = ssl
        }

        do {
            let address = try SocketAddress.makeAddressResolvingHost(
                connectHost,
                port: connectPort
            )
            // NIOSSL refuses hostname verification on bare IPs; 隧道时连 127.0.0.1
            // 也走这条路径 → 用 nil。校验仍按原始 hostname 期望（不便覆盖 SNI），
            // 自签接受由 allowSelfSignedTLS 控制。
            let serverHostname: String? = Self.isIPAddress(connectHost) ? nil : self.database.host
            connection = try await MySQLConnection.connect(
                to: address,
                username: self.database.username,
                database: database,
                password: password,
                tlsConfiguration: tlsConfig,
                serverHostname: serverHostname,
                logger: logger,
                on: Self.eventLoopGroup.next()
            ).get()
        } catch {
            throw DatabaseClientError.connectionFailed(
                DatabaseErrorTranslator.translate(error, context: .connect)
            )
        }
    }

    static func isIPAddress(_ host: String) -> Bool {
        var sin = sockaddr_in()
        if inet_pton(AF_INET, host, &sin.sin_addr) == 1 { return true }
        var sin6 = sockaddr_in6()
        if inet_pton(AF_INET6, host, &sin6.sin6_addr) == 1 { return true }
        return false
    }

    private static func toMySQLData(_ value: QueryValue) -> MySQLData {
        switch value {
        case .null: return .null
        case .string(let s): return MySQLData(string: s)
        case .int(let i): return MySQLData(int: Int(i))
        case .double(let d): return MySQLData(double: d)
        case .bool(let b): return MySQLData(bool: b)
        case .data(let d):
            var buffer = ByteBufferAllocator().buffer(capacity: d.count)
            buffer.writeBytes(d)
            return MySQLData(type: .blob, format: .text, buffer: buffer, isUnsigned: false)
        }
    }

    /// Foundation 文档声明 ISO8601DateFormatter 是线程安全的（与 DateFormatter 不同），
    /// 跨 actor 共享一个实例，避免每行结果都新建一次。
    /// `nonisolated(unsafe)` 是因为 Swift 6 strict concurrency 不识别 Foundation 的线程安全保证。
    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()

    private static func dataToString(_ data: MySQLData?) -> String? {
        guard let data else { return nil }
        if let s = data.string { return s }
        if let i = data.int { return String(i) }
        if let d = data.double { return String(d) }
        if let b = data.bool { return String(b) }
        if let d = data.date { return iso8601Formatter.string(from: d) }
        // BLOB / BINARY 列：bytes 不是 UTF-8 时 MySQLData.string 返回 nil；以前直接吞掉
        // 让用户看到空字符串。改成 hex 预览（最多 32 字节）+ 总长度，再把整段塞进表格
        // 也只会让滚动卡顿。完整 BLOB 走 cell viewer 单独读取（后续可扩展）。
        if let buffer = data.buffer, buffer.readableBytes > 0 {
            return Self.hexPreview(buffer: buffer)
        }
        return nil
    }

    private static func hexPreview(buffer: ByteBuffer) -> String {
        let total = buffer.readableBytes
        let previewLen = min(total, 32)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: previewLen) ?? []
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        return total > previewLen ? "0x\(hex)… (\(total) bytes)" : "0x\(hex)"
    }
}
