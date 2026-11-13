import Foundation

public enum DatabaseErrorContext {
    case connect
    case query
}

public enum DatabaseErrorTranslator {
    /// 把 NIOSSL / PSQLError / MySQLError 等底层错误的原文，加上一段人话解释。
    /// 保留原文，避免漏掉调试信息。
    public static func translate(_ error: Error, context: DatabaseErrorContext) -> String {
        let raw = (error as NSError).localizedDescription
        let lowered = raw.lowercased()

        if let hint = matchHint(lowered: lowered, context: context) {
            return "\(hint)\n\n原始错误：\(raw)"
        }
        return raw
    }

    private static func matchHint(lowered: String, context: DatabaseErrorContext) -> String? {
        // 网络层
        if lowered.contains("connection refused") {
            return "连接被拒绝：目标端口没有服务在监听，确认数据库进程已启动且端口正确。"
        }
        if lowered.contains("could not connect") || lowered.contains("connection reset") {
            return "无法建立连接：服务端可能崩了或网络中断。"
        }
        if lowered.contains("operation timed out") || lowered.contains("connection timed out") {
            return "连接超时：网络不通或被防火墙挡掉，检查 IP/端口可达性。"
        }
        if lowered.contains("could not resolve") || lowered.contains("nodename nor servname") || lowered.contains("hostname could not be resolved") {
            return "无法解析主机名：DNS 找不到这个域名，或写错了。"
        }
        if lowered.contains("network is unreachable") || lowered.contains("no route to host") {
            return "网络不可达：路由问题或防火墙规则挡了。"
        }

        // 认证 / 权限
        if lowered.contains("password authentication failed") {
            return "PostgreSQL 认证失败：密码错误（用户名是对的）。"
        }
        if lowered.contains("access denied for user") {
            return "MySQL 认证失败：用户名或密码错误，或该用户没有从这个 IP 连入的权限。"
        }
        if lowered.contains("no pg_hba.conf entry") {
            return "PostgreSQL 没给你的 IP / 用户 / 库 配认证规则（pg_hba.conf）。"
        }
        if lowered.contains("ident authentication failed") {
            return "PostgreSQL 配置成 ident 认证，需要操作系统用户匹配，无法用密码登录。"
        }
        if lowered.contains("permission denied") {
            return "权限不足：当前用户没有访问该资源的权限。"
        }

        // 库 / 表 / 字段
        if (lowered.contains("database") && lowered.contains("does not exist")) || lowered.contains("unknown database") {
            return "数据库不存在：检查「默认数据库」字段填的名字是否正确。"
        }
        if lowered.contains("relation") && lowered.contains("does not exist") {
            return "表 / 视图不存在：可能是 schema 错了，或表名拼错。"
        }
        if lowered.contains("doesn't exist") && lowered.contains("table") {
            return "表不存在：检查表名和当前库是否匹配。"
        }
        if lowered.contains("column") && (lowered.contains("does not exist") || lowered.contains("unknown column")) {
            return "字段不存在：检查列名拼写和大小写。"
        }

        // SQL 错误
        if lowered.contains("syntax error") {
            return "SQL 语法错误：仔细看错误指出的位置。"
        }
        if lowered.contains("duplicate key") || lowered.contains("duplicate entry") {
            return "唯一约束冲突：要插入的值跟已有记录重复。"
        }
        if lowered.contains("foreign key constraint") {
            return "外键约束失败：引用的目标行不存在，或被引用的行不能删。"
        }

        // TLS
        if lowered.contains("ssl") || lowered.contains("tls") || lowered.contains("certificate") || lowered.contains("niossl") {
            if context == .connect {
                return "TLS / SSL 错误：服务端可能没开 TLS（试试在编辑器里把 TLS 设成「关闭」），或证书无效（勾上「允许自签证书」）。"
            }
            return "TLS / SSL 错误："
        }

        return nil
    }
}
