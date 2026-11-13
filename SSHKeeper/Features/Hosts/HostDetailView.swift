import SwiftUI
import SSHKeeperCore

struct HostDetailView: View {
    let host: SSHHost
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onConnect: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                Divider()
                infoGrid
                if !host.tags.isEmpty {
                    tagsSection
                }
                if !host.extraOptions.isEmpty {
                    extraOptionsSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("编辑", systemImage: "pencil", action: onEdit)
                Button("删除", systemImage: "trash", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        }
        .confirmationDialog(
            "删除主机 \(host.alias)？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { onDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            if host.source == .imported {
                Text("该主机来自你手写的 ~/.ssh/config，App 不会修改原文件，仅从列表移除（重新打开 App 仍会显示）。")
            } else {
                Text("将从 ~/.ssh/config.d/sshkeeper.conf 中移除该条目。")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(host.alias).font(.largeTitle.weight(.semibold))
                    if host.source == .imported {
                        Text("imported")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(connectionString)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(action: onConnect) {
                Label("连接", systemImage: "terminal")
                    .frame(minWidth: 80)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .help("M3 阶段会接入 SwiftTerm")
        }
    }

    private var connectionString: String {
        let target = host.user.map { "\($0)@\(host.hostname)" } ?? host.hostname
        return host.port == 22 ? target : "\(target):\(host.port)"
    }

    private var infoGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row(label: "主机名", value: host.hostname)
            row(label: "端口", value: "\(host.port)")
            row(label: "用户", value: host.user ?? "—")
            row(label: "私钥", value: host.identityFile ?? "—")
            row(label: "ProxyJump", value: host.proxyJump ?? "—")
            if let lastUsed = host.lastUsedAt {
                row(label: "最近使用", value: lastUsed.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func row(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标签").font(.headline)
            HStack(spacing: 6) {
                ForEach(host.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    private var extraOptionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("其他 ssh_config 选项").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(host.extraOptions.keys.sorted(), id: \.self) { key in
                    if let value = host.extraOptions[key] {
                        Text("\(key) = \(value)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
