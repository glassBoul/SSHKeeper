import Foundation
import Observation

@Observable
@MainActor
public final class KeyManager {
    public private(set) var keys: [KeyRef] = []
    public private(set) var lastError: String?
    public private(set) var lastInfo: String?

    private let directory: URL

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh")
    ) {
        self.directory = directory
    }

    public func reload() {
        let result = KeyScanner.scan(directory: directory)
        self.keys = result.keys
    }

    public func generate(_ options: KeygenRunner.Options, addToKeychain: Bool) async {
        do {
            let path = try await Task.detached { try KeygenRunner.generate(options) }.value
            if addToKeychain {
                try await Task.detached { try KeychainAdapter.addToKeychain(privateKeyPath: path) }.value
                lastInfo = "已生成并加入 Keychain：\(path)"
            } else {
                lastInfo = "已生成：\(path)"
            }
            lastError = nil
            reload()
        } catch {
            lastError = "生成失败：\(error.localizedDescription)"
        }
    }

    public func addToKeychain(_ key: KeyRef) async {
        do {
            try await Task.detached { try KeychainAdapter.addToKeychain(privateKeyPath: key.path) }.value
            lastInfo = "已加入 Keychain：\(key.path)"
            lastError = nil
            reload()
        } catch {
            lastError = "加入 Keychain 失败：\(error.localizedDescription)"
        }
    }

    public func removeFromAgent(_ key: KeyRef) async {
        do {
            try await Task.detached { try KeychainAdapter.removeFromAgent(privateKeyPath: key.path) }.value
            lastInfo = "已从 ssh-agent 移除：\(key.path)"
            lastError = nil
            reload()
        } catch {
            lastError = "移除失败：\(error.localizedDescription)"
        }
    }

    public func copyPublicKeyToClipboard(_ key: KeyRef) {
        guard let path = key.publicKeyPath,
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            lastError = "公钥不存在"
            return
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        Pasteboard.set(trimmed)
        lastInfo = "公钥已复制到剪贴板"
        lastError = nil
    }

    public func copyId(key: KeyRef, target: String) async -> CopyIdResult? {
        guard let pubPath = key.publicKeyPath else {
            lastError = "公钥不存在"
            return nil
        }
        do {
            let result = try await Task.detached {
                try KeyDistribution.copyId(publicKeyPath: pubPath, target: target)
            }.value
            if result.exitCode == 0 {
                lastInfo = "已推送到 \(target)"
                lastError = nil
            } else {
                lastError = "ssh-copy-id 失败：\(result.combinedOutput)"
            }
            return result
        } catch {
            lastError = "ssh-copy-id 启动失败：\(error.localizedDescription)"
            return nil
        }
    }

    public func clearMessages() {
        lastInfo = nil
        lastError = nil
    }
}

#if canImport(AppKit)
import AppKit

private enum Pasteboard {
    static func set(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
#else
private enum Pasteboard {
    static func set(_ string: String) {}
}
#endif
