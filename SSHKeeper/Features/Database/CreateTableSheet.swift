import SwiftUI
import SSHKeeperCore

struct CreateTableSheet: View {
    let database: String
    let onCommit: (String, [ColumnDefinition], [String]) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var tableName: String = ""
    @State private var columns: [DraftColumn] = [
        DraftColumn(name: "id", dataType: "INT", nullable: false, isPK: true, isAutoIncrement: true)
    ]
    @State private var validationError: String?
    @State private var saving: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    nameSection
                    columnsSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 880, minHeight: 540)
        .navigationTitle("新建表")
    }

    private var header: some View {
        HStack {
            Image(systemName: "tablecells.badge.ellipsis")
                .foregroundStyle(.tint)
            Text("在 \(database) 库中新建表").font(.headline)
            Spacer()
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("表名").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            TextField("table_name", text: $tableName)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private var columnsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("字段").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    columns.append(DraftColumn(name: "", dataType: "VARCHAR(255)"))
                } label: {
                    Label("添加字段", systemImage: "plus")
                        .font(.caption)
                }
            }
            VStack(spacing: 0) {
                columnsHeader
                Divider()
                ForEach(columns.indices, id: \.self) { i in
                    columnRow(index: i)
                    Divider().opacity(0.3)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var columnsHeader: some View {
        HStack(spacing: 6) {
            Text("名称").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text("类型").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Text("NULL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 50, alignment: .center)
            Text("默认").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text("PK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 36, alignment: .center)
            Text("自增").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 50, alignment: .center)
            Text("注释").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 24)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func columnRow(index i: Int) -> some View {
        HStack(spacing: 6) {
            TextField("name", text: $columns[i].name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, design: .monospaced))
                .frame(width: 140)
            HStack(spacing: 4) {
                Picker("", selection: $columns[i].dataType) {
                    ForEach(MySQLColumnType.common, id: \.self) { Text($0).tag($0) }
                    if !MySQLColumnType.common.contains(columns[i].dataType), !columns[i].dataType.isEmpty {
                        Text(columns[i].dataType).tag(columns[i].dataType)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Toggle("", isOn: $columns[i].nullable)
                .labelsHidden()
                .frame(width: 50)
            TextField("DEFAULT", text: $columns[i].defaultValue)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, design: .monospaced))
                .frame(width: 110)
            Toggle("", isOn: $columns[i].isPK)
                .labelsHidden()
                .frame(width: 36)
            Toggle("", isOn: $columns[i].isAutoIncrement)
                .labelsHidden()
                .frame(width: 50)
            TextField("comment", text: $columns[i].comment)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, design: .monospaced))
                .frame(maxWidth: .infinity)
            Button(role: .destructive) {
                columns.remove(at: i)
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
            .frame(width: 24)
            .disabled(columns.count <= 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            if saving {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("创建") { Task { await save() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(saving)
        }
        .padding(12)
    }

    private func save() async {
        let trimmedName = tableName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = "表名不能为空"
            return
        }
        let cleaned = columns.compactMap { d -> ColumnDefinition? in
            let name = d.name.trimmingCharacters(in: .whitespaces)
            let type = d.dataType.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !type.isEmpty else { return nil }
            return ColumnDefinition(
                name: name,
                dataType: type,
                nullable: d.nullable,
                defaultValue: d.defaultValue.isEmpty ? nil : d.defaultValue,
                isAutoIncrement: d.isAutoIncrement,
                comment: d.comment.isEmpty ? nil : d.comment
            )
        }
        guard !cleaned.isEmpty else {
            validationError = "至少要有一个字段（名称 + 类型）"
            return
        }
        let dupes = Dictionary(grouping: cleaned) { $0.name }.filter { $0.value.count > 1 }
        if !dupes.isEmpty {
            validationError = "字段名重复：\(dupes.keys.joined(separator: ", "))"
            return
        }
        let pks = columns.filter { $0.isPK }.map { $0.name }
        validationError = nil
        saving = true
        defer { saving = false }
        do {
            try await onCommit(trimmedName, cleaned, pks)
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

private struct DraftColumn: Identifiable {
    let id = UUID()
    var name: String
    var dataType: String
    var nullable: Bool = true
    var defaultValue: String = ""
    var isPK: Bool = false
    var isAutoIncrement: Bool = false
    var comment: String = ""
}
