import Foundation

public enum KeyDistributionError: Error {
    case publicKeyMissing
    case copyFailed(String)
}

public struct CopyIdResult: Sendable {
    public let exitCode: Int32
    public let combinedOutput: String
}

public enum KeyDistribution {
    private static let sshCopyId = "/usr/bin/ssh-copy-id"

    /// Read the public key contents (the file produced by ssh-keygen alongside the private key).
    public static func readPublicKey(privateKeyPath: String) throws -> String {
        let pubPath = privateKeyPath + ".pub"
        guard FileManager.default.fileExists(atPath: pubPath) else {
            throw KeyDistributionError.publicKeyMissing
        }
        return try String(contentsOfFile: pubPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Push the public key to a remote host via `ssh-copy-id`.
    /// Note: ssh-copy-id needs an interactive auth flow (password or another key) on the
    /// remote side; the GUI just streams output.
    public static func copyId(publicKeyPath: String, target: String) throws -> CopyIdResult {
        let result = try Subprocess.run(
            sshCopyId,
            arguments: ["-i", publicKeyPath, target]
        )
        let combined = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return CopyIdResult(exitCode: result.exitCode, combinedOutput: combined)
    }
}
