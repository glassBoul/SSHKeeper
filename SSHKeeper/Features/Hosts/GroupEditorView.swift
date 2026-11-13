import SwiftUI
import SSHKeeperCore

struct GroupEditorView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var newGroupName: String = ""
    @State private var renameTargets: [UUID: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("新建分组") {
                    HStack {
                        TextField("名称", text: $newGroupName)
                        Button("添加", action: addGroup)
                            .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("现有分组") {
                    if store.groups.isEmpty {
                        Text("暂无分组").foregroundStyle(.secondary)
                    } else {
                        ForEach(store.groups) { group in
                            groupRow(group)
                        }
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 360)
        .navigationTitle("分组管理")
    }

    private func groupRow(_ group: HostGroup) -> some View {
        HStack {
            TextField(
                "名称",
                text: Binding(
                    get: { renameTargets[group.id] ?? group.name },
                    set: { renameTargets[group.id] = $0 }
                )
            )
            Button("保存") { rename(group) }
                .disabled((renameTargets[group.id] ?? group.name) == group.name)
            Button(role: .destructive) {
                delete(group)
            } label: {
                Image(systemName: "trash")
            }
        }
    }

    private func addGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try store.upsertGroup(HostGroup(name: name))
            newGroupName = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rename(_ group: HostGroup) {
        guard let newName = renameTargets[group.id]?.trimmingCharacters(in: .whitespaces),
              !newName.isEmpty else { return }
        var updated = group
        updated.name = newName
        do {
            try store.upsertGroup(updated)
            renameTargets[group.id] = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ group: HostGroup) {
        do {
            try store.removeGroup(id: group.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
