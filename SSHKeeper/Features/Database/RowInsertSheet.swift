import SwiftUI
import SSHKeeperCore

/// 单列在 sheet 内的输入状态：三态。提交时折叠成 `[String: String?]`：
/// - useDefault → 不进 dict，SQL 不写该列，DB 走默认值/自增
/// - null       → dict[name] = .some(nil)，SQL 写 NULL
/// - value(s)   → dict[name] = .some(.some(s))
enum RowInsertFieldMode: Equatable {
    case useDefault
    case null
    case value(String)
}

struct RowInsertSheet: View {
    let columns: [ColumnDefinition]
    let tableLabel: String
    /// 提交回调。throws 用于把 DB / 网络错误透传回 sheet 内展示，不关闭 sheet。
    let onCommit: ([String: String?]) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var modes: [String: RowInsertFieldMode] = [:]
    @State private var errorMessage: String?
    @State private var submitting: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(columns) { col in
                    Section(header: columnHeader(col)) {
                        fieldRow(for: col)
                    }
                }
                if let validation = firstValidationError() {
                    Section {
                        Label(validation, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("插入") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(submitting || firstValidationError() != nil)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 460)
        .navigationTitle("新增行 — \(tableLabel)")
        .onAppear { ensureInitialModes() }
        .disabled(submitting)
        .overlay {
            if submitting {
                ProgressView().controlSize(.large)
            }
        }
    }

    // MARK: - 初始化每列默认 mode

    private func ensureInitialModes() {
        guard modes.isEmpty else { return }
        for col in columns {
            modes[col.name] = initialMode(for: col)
        }
    }

    private func initialMode(for col: ColumnDefinition) -> RowInsertFieldMode {
        if col.isAutoIncrement { return .useDefault }
        if let def = col.defaultValue, !def.isEmpty { return .useDefault }
        if col.nullable { return .null }
        return .value("")
    }

    // MARK: - 单列展示

    @ViewBuilder
    private func columnHeader(_ col: ColumnDefinition) -> some View {
        HStack(spacing: 8) {
            Text(col.name)
                .font(.system(.body, design: .monospaced).weight(.semibold))
            Text(col.dataType)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if col.isPrimaryKey {
                Text("PK")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
            }
            if col.isAutoIncrement {
                Text("AUTO_INCREMENT")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !col.nullable {
                Text("NOT NULL")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
            }
            if let def = col.defaultValue, !def.isEmpty {
                Text("DEFAULT \(def)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func fieldRow(for col: ColumnDefinition) -> some View {
        let mode = modes[col.name] ?? .useDefault
        let isAuto = col.isAutoIncrement
        let canUseDefault = isAuto || (col.defaultValue != nil && !(col.defaultValue ?? "").isEmpty)

        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if case .value = mode {
                TextField("输入值", text: textBinding(for: col.name))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                Text(mode == .null ? "NULL" : (isAuto ? "由 DB 分配" : "DEFAULT"))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("默认值", isOn: useDefaultBinding(for: col))
                .toggleStyle(.checkbox)
                .disabled(!canUseDefault && !isAuto)

            Toggle("NULL", isOn: nullBinding(for: col))
                .toggleStyle(.checkbox)
                .disabled(!col.nullable || isAuto)
        }
    }

    // MARK: - Bindings

    private func textBinding(for name: String) -> Binding<String> {
        Binding(
            get: {
                if case .value(let s) = modes[name] { return s }
                return ""
            },
            set: { modes[name] = .value($0) }
        )
    }

    private func useDefaultBinding(for col: ColumnDefinition) -> Binding<Bool> {
        Binding(
            get: { (modes[col.name] ?? .useDefault) == .useDefault },
            set: { isOn in
                if isOn {
                    modes[col.name] = .useDefault
                } else {
                    // 关掉默认值 → 给一个最合理的次选
                    modes[col.name] = col.nullable ? .null : .value("")
                }
            }
        )
    }

    private func nullBinding(for col: ColumnDefinition) -> Binding<Bool> {
        Binding(
            get: { (modes[col.name] ?? .useDefault) == .null },
            set: { isOn in
                if isOn {
                    modes[col.name] = .null
                } else {
                    // 关掉 NULL → 切到 value（空字符串）
                    modes[col.name] = .value("")
                }
            }
        )
    }

    // MARK: - 校验

    /// 返回第一条校验错误。校验失败时禁用「插入」按钮并把消息显示在 sheet 内。
    private func firstValidationError() -> String? {
        var anyExplicit = false
        for col in columns {
            let mode = modes[col.name] ?? initialMode(for: col)
            switch mode {
            case .null:
                anyExplicit = true
                if !col.nullable {
                    return "「\(col.name)」为 NOT NULL，不能设为 NULL"
                }
            case .useDefault:
                let hasDefault = col.defaultValue.map { !$0.isEmpty } ?? false
                if !col.isAutoIncrement && !hasDefault && !col.nullable {
                    return "「\(col.name)」没有默认值，必须显式提供"
                }
            case .value:
                anyExplicit = true
            }
        }
        if !anyExplicit && !columns.isEmpty {
            return "至少要修改一列（不能全部走默认值/自增）"
        }
        return nil
    }

    // MARK: - 提交

    private func submit() async {
        // 折叠 modes → values dict
        var values: [String: String?] = [:]
        for col in columns {
            let mode = modes[col.name] ?? initialMode(for: col)
            switch mode {
            case .useDefault:
                continue
            case .null:
                values[col.name] = .some(nil)
            case .value(let s):
                values[col.name] = .some(.some(s))
            }
        }
        // values.isEmpty 不会到这里 — firstValidationError 已经把它拦住、按钮禁用
        errorMessage = nil
        submitting = true
        defer { submitting = false }
        do {
            try await onCommit(values)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
