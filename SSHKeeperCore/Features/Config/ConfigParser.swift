import Foundation

struct ParsedSshConfig: Sendable, Equatable {
    var hosts: [SSHHost]
    var includeDirectives: [IncludeDirective]
    var visitedFiles: [String]
    /// OpenSSH 的 Match 条件（match host *.prod、match exec ...）解析比较复杂，
    /// 当前 parser 只跳过整个 Match 块。把跳过的位置记录下来，让 UI 能给用户
    /// 一句"有 N 个 Match 块未导入"的提示，避免静默丢失。
    var skippedMatchBlocks: [SkippedMatchBlock]
}

struct IncludeDirective: Sendable, Equatable {
    var rawArgument: String
    var resolvedFiles: [String]
    var sourceFile: String
}

struct SkippedMatchBlock: Sendable, Equatable {
    /// "Match" 后面的原始参数串，例如 "host *.prod" 或 "exec hostname-check"
    var rawArgument: String
    var sourceFile: String
}

enum ConfigParseError: Error, Equatable {
    case fileNotFound(String)
    case unreadable(String)
}

enum ConfigParser {
    private static let firstClassKeys: Set<String> = [
        "hostname", "port", "user", "identityfile", "proxyjump"
    ]

    static func parse(fileURL: URL) throws -> ParsedSshConfig {
        var hosts: [SSHHost] = []
        var includes: [IncludeDirective] = []
        var skipped: [SkippedMatchBlock] = []
        var visited = Set<String>()
        try parseRecursive(
            fileURL: fileURL,
            hosts: &hosts,
            includes: &includes,
            skipped: &skipped,
            visited: &visited
        )
        return ParsedSshConfig(
            hosts: hosts,
            includeDirectives: includes,
            visitedFiles: Array(visited).sorted(),
            skippedMatchBlocks: skipped
        )
    }

    static func parseString(
        _ contents: String,
        fileURL: URL? = nil
    ) -> ParsedSshConfig {
        var hosts: [SSHHost] = []
        var includes: [IncludeDirective] = []
        var skipped: [SkippedMatchBlock] = []
        let sourcePath = fileURL?.path ?? "<memory>"
        parseLines(
            contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
            sourcePath: sourcePath,
            hosts: &hosts,
            includes: &includes,
            skipped: &skipped
        )
        return ParsedSshConfig(
            hosts: hosts,
            includeDirectives: includes,
            visitedFiles: [sourcePath],
            skippedMatchBlocks: skipped
        )
    }

    private static func parseRecursive(
        fileURL: URL,
        hosts: inout [SSHHost],
        includes: inout [IncludeDirective],
        skipped: inout [SkippedMatchBlock],
        visited: inout Set<String>
    ) throws {
        let canonical = fileURL.standardizedFileURL.path
        if visited.contains(canonical) { return }
        visited.insert(canonical)

        let contents: String
        do {
            contents = try String(contentsOf: fileURL, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            throw ConfigParseError.fileNotFound(canonical)
        } catch {
            throw ConfigParseError.unreadable(canonical)
        }

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var localIncludes: [IncludeDirective] = []
        parseLines(
            lines,
            sourcePath: canonical,
            hosts: &hosts,
            includes: &localIncludes,
            skipped: &skipped
        )

        for directive in localIncludes {
            var resolved: [String] = []
            for pattern in tokenize(directive.rawArgument) {
                let expanded = expandPath(pattern, baseDirectory: fileURL.deletingLastPathComponent())
                let matches = glob(pattern: expanded)
                for match in matches {
                    resolved.append(match)
                    let url = URL(fileURLWithPath: match)
                    try? parseRecursive(
                        fileURL: url,
                        hosts: &hosts,
                        includes: &includes,
                        skipped: &skipped,
                        visited: &visited
                    )
                }
            }
            includes.append(IncludeDirective(
                rawArgument: directive.rawArgument,
                resolvedFiles: resolved,
                sourceFile: canonical
            ))
        }
    }

    private static func parseLines(
        _ lines: [String],
        sourcePath: String,
        hosts: inout [SSHHost],
        includes: inout [IncludeDirective],
        skipped: inout [SkippedMatchBlock]
    ) {
        var currentAliases: [String] = []
        var pending: [String: PendingHostFields] = [:]
        var inMatchBlock = false

        func flush() {
            for alias in currentAliases {
                guard let fields = pending[alias] else { continue }
                guard !isPattern(alias) else { continue }
                hosts.append(fields.intoHost(alias: alias))
            }
            currentAliases = []
            pending = [:]
        }

        for raw in lines {
            let stripped = stripComment(raw).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            let tokens = tokenize(stripped)
            guard let head = tokens.first else { continue }
            let keyword = head.lowercased()
            let valueTokens = Array(tokens.dropFirst())

            switch keyword {
            case "host":
                flush()
                inMatchBlock = false
                currentAliases = valueTokens
                for alias in valueTokens where !isPattern(alias) {
                    pending[alias] = PendingHostFields()
                }
            case "match":
                flush()
                inMatchBlock = true
                skipped.append(SkippedMatchBlock(
                    rawArgument: valueTokens.joined(separator: " "),
                    sourceFile: sourcePath
                ))
            case "include":
                let arg = valueTokens.joined(separator: " ")
                includes.append(IncludeDirective(
                    rawArgument: arg,
                    resolvedFiles: [],
                    sourceFile: sourcePath
                ))
            default:
                guard !inMatchBlock else { continue }
                guard !currentAliases.isEmpty else { continue }
                let value = valueTokens.joined(separator: " ")
                for alias in currentAliases where !isPattern(alias) {
                    pending[alias]?.apply(key: keyword, value: value)
                }
            }
        }
        flush()
    }

    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            switch ch {
            case "\"":
                inQuote.toggle()
            case "=" where !inQuote:
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            case " ", "\t":
                if inQuote {
                    current.append(ch)
                } else if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            default:
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func stripComment(_ line: String) -> String {
        var inQuote = false
        var result = ""
        for ch in line {
            if ch == "\"" { inQuote.toggle() }
            if ch == "#" && !inQuote { break }
            result.append(ch)
        }
        return result
    }

    static func isPattern(_ alias: String) -> Bool {
        alias.contains("*") || alias.contains("?") || alias.hasPrefix("!")
    }

    static func expandPath(_ path: String, baseDirectory: URL) -> String {
        if path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + String(path.dropFirst(1))
        }
        if path.hasPrefix("/") { return path }
        return baseDirectory.appendingPathComponent(path).path
    }

    static func glob(pattern: String) -> [String] {
        var globResult = glob_t()
        defer { globfree(&globResult) }
        let flags: Int32 = GLOB_TILDE | GLOB_NOSORT
        let rc = pattern.withCString { Darwin.glob($0, flags, nil, &globResult) }
        guard rc == 0 else { return [] }
        let count = Int(globResult.gl_pathc)
        var paths: [String] = []
        paths.reserveCapacity(count)
        for index in 0..<count {
            if let cString = globResult.gl_pathv[index] {
                paths.append(String(cString: cString))
            }
        }
        return paths.sorted()
    }
}

private struct PendingHostFields {
    var hostname: String?
    var port: Int?
    var user: String?
    var identityFile: String?
    var proxyJump: String?
    var extraOptions: [String: String] = [:]

    mutating func apply(key: String, value: String) {
        switch key {
        case "hostname":
            hostname = value
        case "port":
            port = Int(value)
        case "user":
            user = value
        case "identityfile":
            identityFile = value
        case "proxyjump":
            proxyJump = value
        default:
            extraOptions[key] = value
        }
    }

    func intoHost(alias: String) -> SSHHost {
        SSHHost(
            alias: alias,
            hostname: hostname ?? alias,
            port: port ?? 22,
            user: user,
            identityFile: identityFile,
            proxyJump: proxyJump,
            extraOptions: extraOptions,
            source: .imported
        )
    }
}
