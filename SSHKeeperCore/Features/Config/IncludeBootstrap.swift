import Foundation

public enum IncludeBootstrapError: Error {
    case backupFailed(String)
    case writeFailed(String)
}

public struct IncludeBootstrap: Identifiable, Sendable {
    public let id = UUID()
    public let configFileURL: URL
    public let includePattern: String

    public init(
        configFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config"),
        includePattern: String = ConfigBridge.defaultIncludePattern
    ) {
        self.configFileURL = configFileURL
        self.includePattern = includePattern
    }

    /// Returns true if the user's ~/.ssh/config already pulls in the App-managed file
    /// (either directly via the exact pattern or via a glob that covers it).
    public func isAlreadyIncluded() -> Bool {
        guard let contents = try? String(contentsOf: configFileURL, encoding: .utf8) else {
            return false
        }
        let candidates = candidatePatterns(for: includePattern)
        for raw in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let stripped = ConfigParser.stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            let tokens = ConfigParser.tokenize(stripped)
            guard tokens.first?.lowercased() == "include" else { continue }
            for token in tokens.dropFirst() {
                if candidates.contains(token) { return true }
            }
        }
        return false
    }

    /// Inject `Include <pattern>` at the top of ~/.ssh/config, after backing the file up.
    /// Returns the backup file URL (or nil if no original existed).
    @discardableResult
    public func injectInclude(timestamp: Date = Date()) throws -> URL? {
        let directory = configFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var backupURL: URL?
        var existing = ""
        if FileManager.default.fileExists(atPath: configFileURL.path) {
            do {
                existing = try String(contentsOf: configFileURL, encoding: .utf8)
            } catch {
                throw IncludeBootstrapError.backupFailed(error.localizedDescription)
            }
            backupURL = directory.appendingPathComponent("config.bak.\(Self.timestampString(timestamp))")
            do {
                try existing.write(to: backupURL!, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: backupURL!.path
                )
            } catch {
                throw IncludeBootstrapError.backupFailed(error.localizedDescription)
            }
        }

        // OpenSSH is first-match-wins for shared options. Putting Include at the top
        // lets App-managed Host blocks resolve before user `Host *` globals.
        let banner = "# Added by SSHKeeper. Removing this line will detach the App from your config.\n"
        let injected = banner + "Include \(includePattern)\n\n" + existing

        let tempURL = directory.appendingPathComponent(".sshkeeper.config.\(UUID().uuidString).tmp")
        do {
            try injected.write(to: tempURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tempURL.path
            )
            if FileManager.default.fileExists(atPath: configFileURL.path) {
                _ = try FileManager.default.replaceItemAt(configFileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: configFileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw IncludeBootstrapError.writeFailed(error.localizedDescription)
        }

        return backupURL
    }

    private func candidatePatterns(for pattern: String) -> Set<String> {
        var set: Set<String> = [pattern]
        if !pattern.hasPrefix("~/") && !pattern.hasPrefix("/") {
            set.insert("~/.ssh/" + pattern)
        }
        return set
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
