import Foundation

public struct KeyScannerResult: Sendable {
    public let keys: [KeyRef]
    public let agentFingerprints: Set<String>
}

public enum KeyScanner {
    private static let sshKeygen = "/usr/bin/ssh-keygen"
    private static let sshAdd = "/usr/bin/ssh-add"

    public static func scan(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
    ) -> KeyScannerResult {
        let agentFingerprints = loadAgentFingerprints()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return KeyScannerResult(keys: [], agentFingerprints: agentFingerprints)
        }

        // Collect public keys; private key is the file with the same name minus ".pub".
        var keys: [KeyRef] = []
        for url in entries where url.pathExtension == "pub" {
            let privateURL = url.deletingPathExtension()
            guard FileManager.default.fileExists(atPath: privateURL.path) else { continue }
            keys.append(buildKeyRef(privatePath: privateURL, publicPath: url, agentFingerprints: agentFingerprints))
        }
        keys.sort { $0.path < $1.path }
        return KeyScannerResult(keys: keys, agentFingerprints: agentFingerprints)
    }

    public static func loadAgentFingerprints() -> Set<String> {
        guard let result = try? Subprocess.run(sshAdd, arguments: ["-l"]),
              result.isSuccess else {
            return []
        }
        // Each line: "<bits> SHA256:<hash> <comment> (<TYPE>)"
        var fingerprints: Set<String> = []
        for line in result.stdout.split(separator: "\n") {
            let tokens = line.split(separator: " ")
            if tokens.count >= 2 {
                fingerprints.insert(String(tokens[1]))
            }
        }
        return fingerprints
    }

    private static func buildKeyRef(
        privatePath: URL,
        publicPath: URL,
        agentFingerprints: Set<String>
    ) -> KeyRef {
        let info = readPublicKeyInfo(publicPath)
        let hasPassphrase = detectPassphrase(privatePath: privatePath)
        let inKeychain = info.fingerprint.map { agentFingerprints.contains($0) } ?? false
        return KeyRef(
            path: privatePath.path,
            publicKeyPath: publicPath.path,
            type: info.type,
            bitLength: info.bitLength,
            fingerprint: info.fingerprint,
            comment: info.comment,
            hasPassphrase: hasPassphrase,
            inKeychain: inKeychain
        )
    }

    private struct PublicKeyInfo {
        let type: KeyType
        let bitLength: Int?
        let fingerprint: String?
        let comment: String?
    }

    private static func readPublicKeyInfo(_ url: URL) -> PublicKeyInfo {
        guard let result = try? Subprocess.run(sshKeygen, arguments: ["-l", "-f", url.path]),
              result.isSuccess else {
            return PublicKeyInfo(type: .unknown, bitLength: nil, fingerprint: nil, comment: nil)
        }
        // "<bits> SHA256:<hash> <comment> (<TYPE>)"
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else {
            return PublicKeyInfo(type: .unknown, bitLength: nil, fingerprint: nil, comment: nil)
        }
        let bitLength = Int(tokens[0])
        let fingerprint = tokens[1]
        let typeToken = tokens.last ?? ""
        let type = parseType(typeToken)
        let commentTokens = tokens.dropFirst(2).dropLast()
        let comment = commentTokens.isEmpty ? nil : commentTokens.joined(separator: " ")
        return PublicKeyInfo(
            type: type,
            bitLength: bitLength,
            fingerprint: fingerprint,
            comment: comment
        )
    }

    private static func parseType(_ token: String) -> KeyType {
        let lowered = token.lowercased()
        if lowered.contains("ed25519") { return .ed25519 }
        if lowered.contains("rsa") { return .rsa }
        if lowered.contains("ecdsa") { return .ecdsa }
        if lowered.contains("dsa") { return .dsa }
        return .unknown
    }

    private static func detectPassphrase(privatePath: URL) -> Bool {
        // `ssh-keygen -y -P '' -f <path>` returns exit 0 if the key has no passphrase
        // and exit 1 with "incorrect passphrase" if it does. Standard input is
        // redirected from /dev/null so the command does not block waiting for one.
        guard let result = try? Subprocess.run(
            sshKeygen,
            arguments: ["-y", "-P", "", "-f", privatePath.path]
        ) else {
            return false
        }
        return !result.isSuccess
    }
}
