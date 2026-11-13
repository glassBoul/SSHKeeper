import SwiftUI
import SSHKeeperCore

struct HostListSidebar: View {
    @Environment(HostStore.self) private var store
    @Binding var selection: String?
    @Binding var searchText: String
    let onAddHost: () -> Void
    let onAddGroup: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(sectionedHosts(), id: \.title) { section in
                Section(section.title) {
                    ForEach(section.hosts) { host in
                        HostRow(host: host)
                            .tag(host.alias)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索主机或标签")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("新建主机", action: onAddHost)
                    Button("新建分组", action: onAddGroup)
                } label: {
                    Label("添加", systemImage: "plus")
                }
            }
        }
        .navigationTitle("SSHKeeper")
    }

    private func sectionedHosts() -> [HostSection] {
        let filtered = filteredHosts()
        let groupsByID = Dictionary(uniqueKeysWithValues: store.groups.map { ($0.id, $0) })

        var ungrouped: [SSHHost] = []
        var bucket: [UUID: [SSHHost]] = [:]
        for host in filtered {
            if let groupID = host.groupID, groupsByID[groupID] != nil {
                bucket[groupID, default: []].append(host)
            } else {
                ungrouped.append(host)
            }
        }

        var sections: [HostSection] = []
        if !ungrouped.isEmpty {
            sections.append(HostSection(title: "未分组", hosts: sortHosts(ungrouped)))
        }
        for group in store.groups.sorted(by: { $0.name < $1.name }) {
            if let hosts = bucket[group.id], !hosts.isEmpty {
                sections.append(HostSection(title: group.name, hosts: sortHosts(hosts)))
            }
        }
        return sections
    }

    private func filteredHosts() -> [SSHHost] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return store.hosts }
        return store.hosts.filter { host in
            if host.alias.lowercased().contains(trimmed) { return true }
            if host.hostname.lowercased().contains(trimmed) { return true }
            if host.tags.contains(where: { $0.lowercased().contains(trimmed) }) { return true }
            return false
        }
    }

    private func sortHosts(_ hosts: [SSHHost]) -> [SSHHost] {
        hosts.sorted { $0.alias < $1.alias }
    }
}

private struct HostSection {
    let title: String
    let hosts: [SSHHost]
}

private struct HostRow: View {
    let host: SSHHost

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(rowColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(host.alias)
                        .font(.body.weight(.medium))
                    if host.source == .imported {
                        Text("imported")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(displayHostname)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !host.tags.isEmpty {
                    Text(host.tags.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var rowColor: Color {
        if let hex = host.colorHex, let parsed = Color(hex: hex) {
            return parsed
        }
        return host.source == .imported ? .gray : .accentColor
    }

    private var displayHostname: String {
        if let user = host.user, !user.isEmpty {
            return "\(user)@\(host.hostname):\(host.port)"
        }
        return host.port == 22 ? host.hostname : "\(host.hostname):\(host.port)"
    }
}

extension Color {
    init?(hex: String) {
        var trimmed = hex.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xff) / 255
        let g = Double((value >> 8) & 0xff) / 255
        let b = Double(value & 0xff) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
