import Foundation

public enum KeychainAdapterError: Error {
    case sshAddFailed(String)
}

public enum KeychainAdapter {
    private static let sshAdd = "/usr/bin/ssh-add"

    /// Add a private key to the macOS Keychain via `ssh-add --apple-use-keychain`.
    /// The system Keychain prompt (with Touch ID) handles the passphrase; the App
    /// never holds the secret in memory.
    public static func addToKeychain(privateKeyPath: String) throws {
        let result = try Subprocess.run(
            sshAdd,
            arguments: ["--apple-use-keychain", privateKeyPath]
        )
        guard result.isSuccess else {
            throw KeychainAdapterError.sshAddFailed(
                [result.stdout, result.stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )
        }
    }

    /// Add a key to the running ssh-agent without touching the Keychain.
    public static func addToAgent(privateKeyPath: String) throws {
        let result = try Subprocess.run(sshAdd, arguments: [privateKeyPath])
        guard result.isSuccess else {
            throw KeychainAdapterError.sshAddFailed(
                [result.stdout, result.stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )
        }
    }

    /// Remove a key from the agent (`ssh-add -d`).
    public static func removeFromAgent(privateKeyPath: String) throws {
        let result = try Subprocess.run(sshAdd, arguments: ["-d", privateKeyPath])
        guard result.isSuccess else {
            throw KeychainAdapterError.sshAddFailed(
                [result.stdout, result.stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )
        }
    }
}
