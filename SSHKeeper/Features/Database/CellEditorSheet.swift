import SwiftUI
import SSHKeeperCore

/// 行内/草稿单元格的"扩展编辑器"：列宽窄，但字段长（TEXT / JSON / 长 VARCHAR）时
/// 在 inline TextField 旁按 Shift+Enter 或点 ↗ 按钮弹出本 sheet，提供多行编辑、
/// JSON 格式化、设为 NULL / 重置默认等能力。
///
/// 数据流：父层把当前值丢进来，sheet 内自管草稿；保存时把 outcome 回传，由父决定
/// 是 patch 行内 draft（inline 模式）还是写草稿行 dict（draft 模式）。
struct CellEditorSheet: View {
    let columnName: String
    let columnDef: ColumnDefinition?
    let initialText: String
    let initialIsNull: Bool
    /// nullable 列才显示"设为 NULL"切换；inline 模式从列定义取，草稿模式同。
    let allowSetNull: Bool
    /// 仅草稿模式给 true：允许"重置默认 / 不写此列"——commit 出 .resetDefault。
    let allowResetDefault: Bool
    /// 父层完成后续逻辑。.text / .null / .resetDefault 三选一。
    let onCommit: (CellEditorOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isNull: Bool
    @FocusState private var editorFocused: Bool

    init(
        columnName: String,
        columnDef: ColumnDefinition?,
        initialText: String,
        initialIsNull: Bool,
        allowSetNull: Bool,
        allowResetDefault: Bool,
        onCommit: @escaping (CellEditorOutcome) -> Void
    ) {
        self.columnName = columnName
        self.columnDef = columnDef
        self.initialText = initialText
        self.initialIsNull = initialIsNull
        self.allowSetNull = allowSetNull
        self.allowResetDefault = allowResetDefault
        self.onCommit = onCommit
        _text = State(initialValue: initialText)
        _isNull = State(initialValue: initialIsNull)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            editorBody
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 360, idealHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(columnName)
                    .font(.system(.headline, design: .monospaced))
                    .textSelection(.enabled)
                if let def = columnDef {
                    HStack(spacing: 8) {
                        Text(def.dataType)
                        if !def.nullable {
                            Text("NOT NULL").foregroundStyle(.orange)
                        }
                        if let d = def.defaultValue, !d.isEmpty {
                            Text("DEFAULT \(d)")
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if allowSetNull {
                Button {
                    isNull.toggle()
                } label: {
                    Label(isNull ? "已设为 NULL（点击取消）" : "设为 NULL",
                          systemImage: isNull ? "circle.dotted" : "circle.slash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(isNull ? "保存时写入 SQL NULL" : "将此值改为 NULL")
            }

            Button {
                formatJSONIfPossible()
            } label: {
                Label("格式化 JSON", systemImage: "curlybraces")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isNull || !isValidJSON(text))
            .help(isValidJSON(text) ? "缩进展开当前 JSON" : "当前内容不是合法 JSON")

            Button {
                text = ""
            } label: {
                Label("清空文本", systemImage: "xmark.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isNull || text.isEmpty)

            if allowResetDefault {
                Button {
                    onCommit(.resetDefault)
                    dismiss()
                } label: {
                    Label("重置为默认", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("不写此列，由 DB 走默认值 / 自增")
            }

            Spacer()
            Text(charactersStat)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.04))
    }

    @ViewBuilder
    private var editorBody: some View {
        if isNull {
            VStack(spacing: 10) {
                Image(systemName: "circle.dotted")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("NULL")
                    .font(.title3.monospaced())
                    .foregroundStyle(.secondary)
                Text("保存时写入 SQL NULL。点上方「设为 NULL」按钮可回到文本编辑。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.05))
        } else {
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .onAppear { editorFocused = true }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("⌘⏎ 保存 · ⎋ 取消")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存") { commit() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var charactersStat: String {
        if isNull { return "(NULL)" }
        let chars = text.count
        let bytes = text.lengthOfBytes(using: .utf8)
        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        return "\(lines) 行 · \(chars) 字符 · \(bytes) 字节"
    }

    private func commit() {
        if isNull {
            onCommit(.null)
        } else {
            onCommit(.text(text))
        }
        dismiss()
    }

    private func isValidJSON(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private func formatJSONIfPossible() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: pretty, encoding: .utf8)
        else { return }
        text = str
    }
}

enum CellEditorOutcome {
    case text(String)
    case null
    case resetDefault
}
