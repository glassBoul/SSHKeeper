import SwiftUI
import SSHKeeperCore

struct TableInfoView: View {
    let detail: TableInfoDetail
    let canEditMetadata: Bool   // MySQL: true, Postgres: false（除注释）
    let onSave: (TableMetadataChanges) async -> Void
    let onReload: () async -> Void

    @State private var engine: String
    @State private var charset: String
    @State private var collation: String
    @State private var comment: String
    @State private var saving: Bool = false
    @State private var saveError: String?

    private let originalEngine: String
    private let originalCharset: String
    private let originalCollation: String
    private let originalComment: String

    init(
        detail: TableInfoDetail,
        canEditMetadata: Bool,
        onSave: @escaping (TableMetadataChanges) async -> Void,
        onReload: @escaping () async -> Void
    ) {
        self.detail = detail
        self.canEditMetadata = canEditMetadata
        self.onSave = onSave
        self.onReload = onReload
        let e = detail.engine ?? ""
        let cs = detail.charset ?? ""
        let coll = detail.collation ?? ""
        let cmt = detail.comment ?? ""
        _engine = State(initialValue: e)
        _charset = State(initialValue: cs)
        _collation = State(initialValue: coll)
        _comment = State(initialValue: cmt)
        self.originalEngine = e
        self.originalCharset = cs
        self.originalCollation = coll
        self.originalComment = cmt
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topSection
                Divider().padding(.vertical, 4)
                statsSection
                Divider().padding(.vertical, 4)
                commentSection
                Divider().padding(.vertical, 4)
                createSyntaxSection
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            if hasChanges || saveError != nil {
                saveBar
            }
        }
    }

    // MARK: - Top: 引擎 / 编码 / 排序

    private var topSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("Type:").gridLabel()
                if canEditMetadata {
                    Picker("", selection: $engine) {
                        ForEach(Self.commonEngines, id: \.self) { Text($0).tag($0) }
                        if !Self.commonEngines.contains(engine), !engine.isEmpty {
                            Text(engine).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200, alignment: .leading)
                } else {
                    Text(engine.isEmpty ? "—" : engine)
                }
                Text("Created at:").gridLabel()
                Text(detail.createdAt ?? "不可用").foregroundStyle(.secondary)
            }
            GridRow {
                Text("Encoding:").gridLabel()
                if canEditMetadata {
                    Picker("", selection: $charset) {
                        ForEach(Self.commonCharsets, id: \.self) { Text($0).tag($0) }
                        if !Self.commonCharsets.contains(charset), !charset.isEmpty {
                            Text(charset).tag(charset)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200, alignment: .leading)
                    .onChange(of: charset) { _, newCharset in
                        // 切换 charset 时把 collation 重置成该 charset 默认 collation
                        if !Self.collationsFor(charset: newCharset).contains(collation) {
                            collation = Self.defaultCollation(for: newCharset)
                        }
                    }
                } else {
                    Text(charset.isEmpty ? "—" : charset)
                }
                Text("Updated at:").gridLabel()
                Text(detail.updatedAt ?? "不可用").foregroundStyle(.secondary)
            }
            GridRow {
                Text("Collation:").gridLabel()
                if canEditMetadata {
                    Picker("", selection: $collation) {
                        ForEach(Self.collationsFor(charset: charset), id: \.self) { Text($0).tag($0) }
                        if !Self.collationsFor(charset: charset).contains(collation), !collation.isEmpty {
                            Text(collation).tag(collation)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)
                } else {
                    Text(collation.isEmpty ? "—" : collation)
                }
                Color.clear.gridCellColumns(2)
            }
        }
    }

    // MARK: - 统计

    private var statsSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                stat("Number of rows", value: detail.rowCount.map { String($0) })
                stat("Data size", value: detail.dataSize.map(Self.formatBytes))
            }
            GridRow {
                stat("Row format", value: detail.rowFormat)
                stat("Max data size", value: detail.maxDataSize.map(Self.formatBytes))
            }
            GridRow {
                stat("Avg. row length", value: detail.avgRowLength.map { String($0) })
                stat("Index size", value: detail.indexSize.map(Self.formatBytes))
            }
            GridRow {
                stat("Auto increment", value: detail.autoIncrement.map { String($0) })
                stat("Free data size", value: detail.freeDataSize.map(Self.formatBytes))
            }
        }
    }

    @ViewBuilder
    private func stat(_ label: String, value: String?) -> some View {
        Text(label + ":").gridLabel()
        Text(value ?? "不可用").foregroundStyle(value == nil ? .tertiary : .primary)
    }

    // MARK: - 注释

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comments:").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            if canEditMetadata || !comment.isEmpty {
                TextEditor(text: $comment)
                    .font(.system(.body, design: .default))
                    .frame(minHeight: 60, maxHeight: 100)
                    .padding(4)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                    .disabled(!canEditMetadata && Self.cannotEditPostgres)
            } else {
                Text("（无注释）").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private static let cannotEditPostgres = false  // Postgres 也允许改注释

    // MARK: - CREATE 语句

    @ViewBuilder
    private var createSyntaxSection: some View {
        if let syntax = detail.createSyntax, !syntax.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Create syntax:").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(syntax, forType: .string)
                    }
                    .controlSize(.small)
                }
                ReadOnlySQLView(text: syntax)
                    .frame(minHeight: 200)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    // MARK: - 保存栏

    private var saveBar: some View {
        HStack(spacing: 12) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if hasChanges {
                Text("有未保存的修改").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("放弃") {
                engine = originalEngine
                charset = originalCharset
                collation = originalCollation
                comment = originalComment
                saveError = nil
            }
            .disabled(!hasChanges || saving)
            Button("保存") {
                Task { await save() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!hasChanges || saving)
        }
        .padding(8)
        .background(.regularMaterial)
    }

    private var hasChanges: Bool {
        engine != originalEngine ||
        charset != originalCharset ||
        collation != originalCollation ||
        comment != originalComment
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let changes = TableMetadataChanges(
            newEngine: engine != originalEngine ? engine : nil,
            newCharset: charset != originalCharset ? charset : nil,
            newCollation: collation != originalCollation ? collation : nil,
            newComment: comment != originalComment ? comment : nil
        )
        await onSave(changes)
        await onReload()
        saveError = nil
    }

    // MARK: - 静态选项

    private static let commonEngines = ["InnoDB", "MyISAM", "MEMORY", "ARCHIVE", "CSV"]
    private static let commonCharsets = ["utf8mb4", "utf8", "latin1", "ascii", "gbk", "gb2312", "big5"]

    private static func collationsFor(charset: String) -> [String] {
        switch charset {
        case "utf8mb4":
            return ["utf8mb4_unicode_ci", "utf8mb4_general_ci", "utf8mb4_bin", "utf8mb4_0900_ai_ci", "utf8mb4_unicode_520_ci"]
        case "utf8":
            return ["utf8_general_ci", "utf8_unicode_ci", "utf8_bin"]
        case "latin1":
            return ["latin1_swedish_ci", "latin1_general_ci", "latin1_bin"]
        case "ascii":
            return ["ascii_general_ci", "ascii_bin"]
        case "gbk":
            return ["gbk_chinese_ci", "gbk_bin"]
        case "gb2312":
            return ["gb2312_chinese_ci", "gb2312_bin"]
        case "big5":
            return ["big5_chinese_ci", "big5_bin"]
        default:
            return []
        }
    }

    private static func defaultCollation(for charset: String) -> String {
        switch charset {
        case "utf8mb4": return "utf8mb4_unicode_ci"
        case "utf8": return "utf8_general_ci"
        case "latin1": return "latin1_swedish_ci"
        case "ascii": return "ascii_general_ci"
        case "gbk": return "gbk_chinese_ci"
        case "gb2312": return "gb2312_chinese_ci"
        case "big5": return "big5_chinese_ci"
        default: return ""
        }
    }

    private static func formatBytes(_ bytes: Int) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[unit])
    }
}

// 一段只读、带 SQL 高亮的 NSTextView 包装（复用 SQLEditor 的高亮器）
private struct ReadOnlySQLView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = false
        textView.string = text
        if let storage = textView.textStorage {
            SQLHighlighter.apply(to: storage)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            if let storage = textView.textStorage {
                SQLHighlighter.apply(to: storage)
            }
        }
    }
}

private extension Text {
    func gridLabel() -> some View {
        self
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 110, alignment: .trailing)
    }
}
