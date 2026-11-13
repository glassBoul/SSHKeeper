import SwiftUI
import SSHKeeperCore

enum IndexEditorTarget: Identifiable {
    case add
    var id: String { "__add_index__" }
}

struct IndexEditorResult {
    let index: IndexDefinition
}

struct IndexEditorSheet: View {
    let target: IndexEditorTarget
    let availableColumns: [String]
    let existingNames: Set<String>
    let canEdit: Bool
    let onCommit: (IndexEditorResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var category: IndexCategory = .normal
    @State private var selectedColumns: [String] = []
    @State private var method: String = "BTREE"
    @State private var comment: String = ""
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("索引") {
                    TextField("索引名", text: $name)
                    Picker("类型", selection: $category) {
                        ForEach([IndexCategory.normal, .unique, .fulltext, .spatial, .primary], id: \.self) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    if category == .primary {
                        Text("主键名固定为 PRIMARY，索引名忽略。同一表只能有一个主键。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if category == .normal || category == .unique {
                        Picker("方法", selection: $method) {
                            Text("BTREE").tag("BTREE")
                            Text("HASH").tag("HASH")
                        }
                    }
                }
                Section("字段（按顺序）") {
                    ForEach(availableColumns, id: \.self) { col in
                        Toggle(col, isOn: Binding(
                            get: { selectedColumns.contains(col) },
                            set: { newValue in
                                if newValue {
                                    if !selectedColumns.contains(col) {
                                        selectedColumns.append(col)
                                    }
                                } else {
                                    selectedColumns.removeAll { $0 == col }
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                    if !selectedColumns.isEmpty {
                        Text("已选：\(selectedColumns.joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Section("注释") {
                    TextField("comment", text: $comment, axis: .vertical)
                        .lineLimit(2...4)
                }
                if let validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!canEdit)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { tryCommit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canEdit)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 480)
        .navigationTitle("添加索引")
    }

    private func tryCommit() {
        let trimmedName = category == .primary ? "PRIMARY" : name.trimmingCharacters(in: .whitespaces)
        if category != .primary {
            guard !trimmedName.isEmpty else {
                validationError = "索引名不能为空"
                return
            }
            if existingNames.contains(trimmedName) {
                validationError = "索引名已存在"
                return
            }
        }
        guard !selectedColumns.isEmpty else {
            validationError = "至少选一个字段"
            return
        }
        let index = IndexDefinition(
            name: trimmedName,
            category: category,
            columns: selectedColumns,
            method: (category == .normal || category == .unique) ? method : nil,
            comment: comment.isEmpty ? nil : comment
        )
        onCommit(IndexEditorResult(index: index))
    }
}
