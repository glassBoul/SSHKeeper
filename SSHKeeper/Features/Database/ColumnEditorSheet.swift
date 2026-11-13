import SwiftUI
import SSHKeeperCore

enum ColumnEditorTarget: Identifiable {
    case add(after: String?)
    case modify(original: ColumnDefinition)

    var id: String {
        switch self {
        case .add: return "__add__"
        case .modify(let c): return "modify:\(c.name)"
        }
    }

    var title: String {
        switch self {
        case .add: return "添加字段"
        case .modify(let c): return "编辑字段 \(c.name)"
        }
    }

    var commitLabel: String {
        switch self {
        case .add: return "添加"
        case .modify: return "保存"
        }
    }
}

struct ColumnEditorResult {
    let column: ColumnDefinition
    let after: String?      // 仅新增时；nil = 末尾
}

struct ColumnEditorSheet: View {
    let target: ColumnEditorTarget
    let existingNames: Set<String>
    let canEdit: Bool
    let onCommit: (ColumnEditorResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var dataType: String
    @State private var customType: Bool
    @State private var nullable: Bool
    @State private var hasDefault: Bool
    @State private var defaultValue: String
    @State private var isAutoIncrement: Bool
    @State private var comment: String
    @State private var afterName: String
    @State private var validationError: String?

    init(
        target: ColumnEditorTarget,
        existingNames: Set<String>,
        canEdit: Bool,
        onCommit: @escaping (ColumnEditorResult) -> Void
    ) {
        self.target = target
        self.existingNames = existingNames
        self.canEdit = canEdit
        self.onCommit = onCommit

        switch target {
        case .add(let after):
            _name = State(initialValue: "")
            _dataType = State(initialValue: "VARCHAR(255)")
            _customType = State(initialValue: false)
            _nullable = State(initialValue: true)
            _hasDefault = State(initialValue: false)
            _defaultValue = State(initialValue: "")
            _isAutoIncrement = State(initialValue: false)
            _comment = State(initialValue: "")
            _afterName = State(initialValue: after ?? "")
        case .modify(let col):
            _name = State(initialValue: col.name)
            _dataType = State(initialValue: col.dataType)
            _customType = State(initialValue: !MySQLColumnType.common.contains(col.dataType))
            _nullable = State(initialValue: col.nullable)
            _hasDefault = State(initialValue: col.defaultValue != nil)
            _defaultValue = State(initialValue: col.defaultValue ?? "")
            _isAutoIncrement = State(initialValue: col.isAutoIncrement)
            _comment = State(initialValue: col.comment ?? "")
            _afterName = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("字段") {
                    TextField("名称", text: $name)
                    HStack {
                        if customType {
                            TextField("类型", text: $dataType)
                        } else {
                            Picker("类型", selection: $dataType) {
                                ForEach(MySQLColumnType.common, id: \.self) {
                                    Text($0).tag($0)
                                }
                                if !MySQLColumnType.common.contains(dataType), !dataType.isEmpty {
                                    Text(dataType).tag(dataType)
                                }
                            }
                        }
                        Toggle("自定义", isOn: $customType)
                            .controlSize(.small)
                            .toggleStyle(.button)
                    }
                    Toggle("允许 NULL", isOn: $nullable)
                    Toggle("自增 (AUTO_INCREMENT)", isOn: $isAutoIncrement)
                }
                Section("默认值") {
                    Toggle("有默认值", isOn: $hasDefault)
                    if hasDefault {
                        TextField("DEFAULT 表达式", text: $defaultValue, prompt: Text("如 'foo' 或 NOW() 或 0"))
                            .font(.system(.body, design: .monospaced))
                        Text("字符串需带引号；表达式（如 NOW()、CURRENT_TIMESTAMP）原样写。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("注释") {
                    TextField("comment", text: $comment, axis: .vertical)
                        .lineLimit(2...4)
                }
                if case .add = target {
                    Section("位置") {
                        TextField("放在哪个字段之后（留空 = 末尾，FIRST = 最前）", text: $afterName)
                            .font(.system(.body, design: .monospaced))
                    }
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
                Button(target.commitLabel) { tryCommit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canEdit)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 480)
        .navigationTitle(target.title)
    }

    private func tryCommit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = "字段名不能为空"
            return
        }
        // 校验名字冲突
        switch target {
        case .add:
            if existingNames.contains(trimmedName) {
                validationError = "字段名已存在"
                return
            }
        case .modify(let original):
            if trimmedName != original.name && existingNames.contains(trimmedName) {
                validationError = "字段名已被占用"
                return
            }
        }
        guard !dataType.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationError = "类型不能为空"
            return
        }

        let column = ColumnDefinition(
            name: trimmedName,
            dataType: dataType.trimmingCharacters(in: .whitespaces),
            nullable: nullable,
            defaultValue: hasDefault ? defaultValue : nil,
            isAutoIncrement: isAutoIncrement,
            comment: comment.isEmpty ? nil : comment
        )

        let after: String?
        if case .add = target {
            let trimmed = afterName.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                after = nil
            } else if trimmed.uppercased() == "FIRST" {
                after = ""
            } else {
                after = trimmed
            }
        } else {
            after = nil
        }

        onCommit(ColumnEditorResult(column: column, after: after))
    }
}
