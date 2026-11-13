import SwiftUI
import SSHKeeperCore

struct KeyManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manager = KeyManager()
    @State private var showingKeygen = false
    @State private var copyIdTarget = ""
    @State private var copyIdKey: KeyRef?
    @State private var copyIdResult: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle("密钥管理")
        .onAppear { manager.reload() }
        .sheet(isPresented: $showingKeygen) {
            KeygenSheet(manager: manager)
        }
        .sheet(item: $copyIdKey) { key in
            CopyIdSheet(
                manager: manager,
                key: key,
                target: $copyIdTarget,
                result: $copyIdResult
            )
        }
    }

    private var header: some View {
        HStack {
            Text("~/.ssh 中的密钥")
                .font(.headline)
            Spacer()
            Button("刷新", systemImage: "arrow.clockwise") { manager.reload() }
                .labelStyle(.iconOnly)
            Button("新建密钥") { showingKeygen = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if manager.keys.isEmpty {
                    ContentUnavailableView(
                        "未找到密钥",
                        systemImage: "key",
                        description: Text("点击上方「新建密钥」创建第一个 SSH 密钥。")
                    )
                    .padding(.vertical, 32)
                }
                ForEach(manager.keys) { key in
                    keyRow(key)
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func keyRow(_ key: KeyRef) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key")
                .font(.title2)
                .foregroundStyle(key.inKeychain ? Color.green : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: key.path).lastPathComponent)
                        .font(.body.weight(.medium))
                    Text(key.type.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if let bits = key.bitLength {
                        Text("\(bits) bit").font(.caption).foregroundStyle(.secondary)
                    }
                    if key.hasPassphrase {
                        Label("有 passphrase", systemImage: "lock.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if key.inKeychain {
                        Label("已在 ssh-agent", systemImage: "checkmark.seal.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text(key.fingerprint ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(key.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                if let comment = key.comment, !comment.isEmpty {
                    Text(comment).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            actionMenu(for: key)
        }
        .padding(12)
    }

    private func actionMenu(for key: KeyRef) -> some View {
        Menu {
            Button("复制公钥") { manager.copyPublicKeyToClipboard(key) }
            if !key.inKeychain {
                Button("加入 Keychain（Touch ID）") {
                    Task { await manager.addToKeychain(key) }
                }
            } else {
                Button("从 ssh-agent 移除") {
                    Task { await manager.removeFromAgent(key) }
                }
            }
            Divider()
            Button("推送到主机（ssh-copy-id）...") {
                copyIdTarget = ""
                copyIdResult = nil
                copyIdKey = key
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 36)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .center) {
            if let info = manager.lastInfo {
                Label(info, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else if let error = manager.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else {
                Text("\(manager.keys.count) 个密钥").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }
}
