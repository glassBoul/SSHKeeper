import Foundation

public enum KeygenError: Error {
    case invalidPath
    case alreadyExists(String)
    case failed(String)
}

public enum KeygenRunner {
    private static let sshKeygen = "/usr/bin/ssh-keygen"

    public struct Options: Sendable {
        public var type: KeyType
        public var bitLength: Int?
        public var comment: String
        public var path: String
        public var passphrase: String

        public init(
            type: KeyType = .ed25519,
            bitLength: Int? = nil,
            comment: String,
            path: String,
            passphrase: String = ""
        ) {
            self.type = type
            self.bitLength = bitLength
            self.comment = comment
            self.path = path
            self.passphrase = passphrase
        }
    }

    /// Run /usr/bin/ssh-keygen non-interactively. Returns the absolute path of the new
    /// private key on success. Throws if ssh-keygen exits non-zero or the file already exists.
    @discardableResult
    public static func generate(_ options: Options) throws -> String {
        let expanded = (options.path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { throw KeygenError.invalidPath }
        if FileManager.default.fileExists(atPath: expanded) {
            throw KeygenError.alreadyExists(expanded)
        }
        let directory = (expanded as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var args: [String] = [
            "-t", typeArgument(options.type),
            "-C", options.comment,
            "-f", expanded,
            "-N", options.passphrase
        ]
        if let bits = options.bitLength {
            args += ["-b", String(bits)]
        }

        let result = try Subprocess.run(sshKeygen, arguments: args)
        guard result.isSuccess else {
            throw KeygenError.failed(combinedOutput(result))
        }
        return expanded
    }

    private static func typeArgument(_ type: KeyType) -> String {
        switch type {
        case .ed25519: "ed25519"
        case .rsa: "rsa"
        case .ecdsa: "ecdsa"
        case .dsa: "dsa"
        case .unknown: "ed25519"
        }
    }

    private static func combinedOutput(_ result: SubprocessResult) -> String {
        let parts = [result.stdout, result.stderr].filter { !$0.isEmpty }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
