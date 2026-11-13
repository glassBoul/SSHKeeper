import Foundation
import Security

public enum PasswordKeychainError: Error {
    case osStatus(OSStatus)

    public var localizedDescription: String {
        switch self {
        case .osStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return message
        }
    }
}

/// Stores per-host SSH login passwords in the macOS Keychain. The Keychain ACL
/// grants access to whoever wrote the item; since the App writes and the App is
/// the askpass helper too, no extra prompts on subsequent reads.
public enum PasswordKeychain {
    private static let serviceTagPrefix = "com.sshkeeper.app.password:"

    public static func has(alias: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: alias),
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    public static func read(alias: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: alias),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func write(alias: String, account: String?, password: String) throws {
        try? delete(alias: alias)
        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: alias),
            kSecAttrAccount as String: account ?? alias,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "SSHKeeper · \(alias)"
        ]
        attrs[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PasswordKeychainError.osStatus(status)
        }
    }

    public static func delete(alias: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: alias)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordKeychainError.osStatus(status)
        }
    }

    private static func service(for alias: String) -> String {
        serviceTagPrefix + alias
    }
}
