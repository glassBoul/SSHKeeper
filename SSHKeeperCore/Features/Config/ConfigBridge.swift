import Foundation

public enum ConfigBridgeError: Error {
    case writeFailed(String)
}

public struct ConfigBridge: Sendable {
    public static let managedHeader = "# Managed by SSHKeeper — DO NOT EDIT BY HAND\n# Edits made here will be overwritten on the next save.\n"
    public static let defaultRelativePath = ".ssh/config.d/sshkeeper.conf"
    public static let defaultIncludePattern = "config.d/*.conf"

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultLocation() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(defaultRelativePath)
    }

    public func render(hosts: [SSHHost]) -> String {
        var output = Self.managedHeader + "\n"
        let managed = hosts.filter { $0.source == .appManaged }
        for (index, host) in managed.enumerated() {
            output += renderHost(host)
            if index < managed.count - 1 {
                output += "\n"
            }
        }
        return output
    }

    public func write(hosts: [SSHHost]) throws {
        try atomicWrite(contents: render(hosts: hosts))
    }

    /// 读当前 conf 文件内容（不存在返回 nil）。事务路径用它在写入前留备份，
    /// 出错时配合 `restore(contents:)` 把文件恢复到调用前的样子。
    public func currentContents() -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// 把指定字符串写回 conf 文件；nil 表示删除文件（恢复"不存在"状态）。
    /// 与 `write` 走同一条 atomic temp + replaceItemAt 路径，保证回滚也是原子的。
    public func restore(contents: String?) throws {
        if let contents {
            try atomicWrite(contents: contents)
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                throw ConfigBridgeError.writeFailed(error.localizedDescription)
            }
        }
    }

    private func atomicWrite(contents: String) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let tempURL = directory.appendingPathComponent(".sshkeeper.\(UUID().uuidString).tmp")
        do {
            try contents.write(to: tempURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tempURL.path
            )
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw ConfigBridgeError.writeFailed(error.localizedDescription)
        }
    }

    private func renderHost(_ host: SSHHost) -> String {
        var lines: [String] = []
        lines.append("Host \(host.alias)")
        lines.append(indent("HostName \(host.hostname)"))
        if host.port != 22 {
            lines.append(indent("Port \(host.port)"))
        }
        if let user = host.user, !user.isEmpty {
            lines.append(indent("User \(user)"))
        }
        if let identity = host.identityFile, !identity.isEmpty {
            lines.append(indent("IdentityFile \(identity)"))
        }
        if let jump = host.proxyJump, !jump.isEmpty {
            lines.append(indent("ProxyJump \(jump)"))
        }
        for key in host.extraOptions.keys.sorted() {
            guard let value = host.extraOptions[key], !value.isEmpty else { continue }
            lines.append(indent("\(canonicalize(key)) \(value)"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func indent(_ line: String) -> String { "    " + line }

    private func canonicalize(_ key: String) -> String {
        // Preserve a few well-known keys with conventional camel case for readability;
        // OpenSSH treats keywords case-insensitively, so anything else passes through.
        let map: [String: String] = [
            "hostname": "HostName",
            "port": "Port",
            "user": "User",
            "identityfile": "IdentityFile",
            "proxyjump": "ProxyJump",
            "proxycommand": "ProxyCommand",
            "forwardagent": "ForwardAgent",
            "serveraliveinterval": "ServerAliveInterval",
            "serveralivecountmax": "ServerAliveCountMax",
            "preferredauthentications": "PreferredAuthentications",
            "stricthostkeychecking": "StrictHostKeyChecking",
            "userknownhostsfile": "UserKnownHostsFile",
            "loglevel": "LogLevel"
        ]
        return map[key.lowercased()] ?? key
    }
}
