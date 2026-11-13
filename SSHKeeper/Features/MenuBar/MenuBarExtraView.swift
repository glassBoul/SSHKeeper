import SwiftUI
import AppKit
import SSHKeeperCore

struct MenuBarExtraView: View {
    let store: HostStore
    let engine: SessionEngine
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !recentHosts.isEmpty {
                        sectionHeader("最近使用")
                        ForEach(recentHosts) { host in
                            row(host)
                        }
                        Divider().padding(.vertical, 4)
                    }
                    sectionHeader("全部主机")
                    if filteredHosts.isEmpty {
                        Text("没有匹配的主机").font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(filteredHosts) { host in
                        row(host)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private func row(_ host: SSHHost) -> some View {
        Button {
            openSession(for: host)
        } label: {
            HStack {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.alias).font(.body)
                    Text(host.hostname).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(Color.clear)
    }

    private var footer: some View {
        HStack {
            Button("打开主窗口") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
        }
        .padding(8)
    }

    private var recentHosts: [SSHHost] {
        store.hosts
            .filter { $0.lastUsedAt != nil }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    private var filteredHosts: [SSHHost] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let all = store.hosts.sorted { $0.alias < $1.alias }
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.alias.lowercased().contains(trimmed) ||
            $0.hostname.lowercased().contains(trimmed) ||
            $0.tags.contains(where: { $0.lowercased().contains(trimmed) })
        }
    }

    private func openSession(for host: SSHHost) {
        try? store.touch(alias: host.alias)
        engine.openSession(alias: host.alias)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
