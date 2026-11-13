import SwiftUI
import AppKit
import SSHKeeperCore

/// 行内编辑：当前正在编辑的 cell 位置 + 原始值。
/// originalValue 用于 commit 前判 "值变了" 才发 SQL。
struct InlineEditingCell: Equatable {
    let rowIdx: Int
    let col: Int
    let originalValue: String?
}

/// 行内编辑的草稿值。
/// .text 是用户在 TextField 里的当前输入；.null 是 "设为 NULL" 状态（cell 显示 NULL 灰字）。
enum InlineEditingDraft: Equatable {
    case text(String)
    case null

    /// 提交时转成 onCellEdit 的 newValue 参数：.text → 字符串；.null → nil。
    var asNewValue: String? {
        switch self {
        case .text(let s): return s
        case .null: return nil
        }
    }
}

struct ResultGrid: View {
    let result: QueryResult
    var editConfig: EditConfig? = nil
    var draftConfig: DraftConfig? = nil

    /// 仅在 inspector 内容标签且表有主键时由父构造，启用单元格修改、行级插入与删除。
    struct EditConfig {
        let pkColumns: Set<String>
        /// 用于行内编辑右键菜单决定 "设为 NULL" 是否可见（只有 nullable 列才显示）。
        /// 父层 TableInspectorPane 注入；空数组时所有 "设为 NULL" 菜单都不显示（fail-closed）。
        let columnDefs: [ColumnDefinition]
        let onCellEdit: ([String?], String, String?) async throws -> Void
        /// 行级删除：父层根据 row 抽 PK 字典并弹确认后再调实际 delete。
        let onRowDelete: ([String?]) -> Void
        /// 行级插入：触发父层启动空白草稿行（idx = 在第 idx 行之后插入；nil = 表尾）。
        let onRowInsert: (Int?) -> Void
        /// 行级复制：以这行为模板启动草稿（自动去掉主键 / auto_increment）。
        /// idx 同上。
        let onRowCopy: ([String?], Int?) -> Void
    }

    /// 内容标签处于「草稿编辑」状态时由父注入，渲染 inline 编辑行 + 工具条。
    struct DraftConfig {
        let columnDefs: [ColumnDefinition]
        /// 与 inspector.draftRow.values 同形：缺列 = 走 DB DEFAULT；.some(nil) = NULL；.some(.some(s)) = s
        let values: [String: String?]
        /// 草稿渲染位置:nil = 表尾；i = 第 i 行之后。
        let insertAfterRowIndex: Int?
        let onSetValue: (String, String) -> Void
        let onSetNull: (String) -> Void
        let onResetToDefault: (String) -> Void
        let onCommit: () -> Void
        let onCancel: () -> Void
        /// 父层提交失败时填这里；本组件只负责显示。
        let errorMessage: String?
        /// 提交进行中 → 禁用 TextField。
        let isCommitting: Bool
    }

    @State private var columnWidths: [CGFloat] = []
    @State private var sortColumn: Int? = nil
    @State private var sortAscending: Bool = true
    @State private var cachedRows: [[String?]] = []
    @State private var liveDragColumn: Int? = nil
    @State private var liveDragOffset: CGFloat = 0
    @State private var selectedRowIdx: Int? = nil
    @State private var editingCell: InlineEditingCell? = nil
    @State private var editingDraft: InlineEditingDraft = .text("")
    @State private var editError: String? = nil
    @State private var editIsSaving: Bool = false
    /// 扩展编辑器（CellEditorSheet）打开状态。
    /// 打开时 inline TextField 会失焦 → 失焦自动 commit 必须跳过，否则 sheet 一弹就
    /// commit 并退出编辑态，sheet 拿到的就是个"幽灵 cell"。
    @State private var inlineExpandedEditor: Bool = false

    private static let defaultWidth: CGFloat = 160
    private static let minWidth: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            if result.isTruncated {
                truncationBanner
                Divider()
            }
            if let draftConfig {
                draftToolbar(draftConfig)
                Divider()
            }
            if editingCell != nil {
                inlineEditBanner
                Divider()
            }
            if !result.columns.isEmpty {
                gridToolbar
                Divider()
            }
            grid
        }
        .background(keyboardShortcutRouter)
        .onAppear {
            ensureWidths()
            recomputeRows()
        }
        .onChange(of: sortColumn) { _, _ in
            selectedRowIdx = nil   // 排序后行号无意义
            recomputeRows()
        }
        .onChange(of: sortAscending) { _, _ in
            selectedRowIdx = nil
            recomputeRows()
        }
        .onChange(of: result.rows) { oldRows, newRows in
            // 翻页 / reload 才清选中；单格 in-place patch（行数相同）保留 selectedRowIdx
            if oldRows.count != newRows.count {
                selectedRowIdx = nil
            }
            recomputeRows()
        }
        .onChange(of: result.columns) { _, _ in
            columnWidths = []
            sortColumn = nil
            selectedRowIdx = nil
            ensureWidths()
            recomputeRows()
        }
        .sheet(isPresented: $inlineExpandedEditor, onDismiss: {
            // sheet 关闭后 inline TextField 重获焦点；commit 由 sheet 内的保存动作走
            // editingDraft → commitEditIfChanged，这里只负责复位标志即可。
            inlineExpandedEditor = false
        }) {
            inlineExpandedEditorSheet
        }
    }

    /// 行内编辑的扩展编辑器 sheet 内容。editingCell 失踪（被 cancel / 切行）就退出。
    @ViewBuilder
    private var inlineExpandedEditorSheet: some View {
        if let cell = editingCell,
           cell.col < result.columns.count {
            let name = result.columns[cell.col]
            let def = editConfig?.columnDefs.first { $0.name == name }
            let initialIsNull: Bool = { if case .null = editingDraft { return true } else { return false } }()
            let initialText: String = {
                if case .text(let s) = editingDraft { return s }
                return cell.originalValue ?? ""
            }()
            CellEditorSheet(
                columnName: name,
                columnDef: def,
                initialText: initialText,
                initialIsNull: initialIsNull,
                allowSetNull: def?.nullable ?? false,
                allowResetDefault: false
            ) { outcome in
                switch outcome {
                case .text(let s):
                    editingDraft = .text(s)
                    Task { await commitEditIfChanged() }
                case .null:
                    editingDraft = .null
                    Task { await commitEditIfChanged() }
                case .resetDefault:
                    // inline 模式不开放此分支（allowResetDefault=false）
                    break
                }
            }
        } else {
            // 编辑 cell 中途丢了 → 直接关
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { inlineExpandedEditor = false }
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(cachedRows.indices, id: \.self) { rowIdx in
                            ResultRowView(
                                row: cachedRows[rowIdx],
                                rowIdx: rowIdx,
                                columnWidths: columnWidths,
                                columns: result.columns,
                                isSelected: rowIdx == selectedRowIdx,
                                onSelectRow: { selectedRowIdx = $0 },
                                onDoubleTap: { rIdx, col, val in beginEdit(rowIdx: rIdx, col: col, originalValue: val) },
                                onCopyTSV: { copyRow($0, separator: "\t") },
                                onCopyCSV: { copyRow($0, separator: ",", quote: true) },
                                onCopyInsert: { copyRowAsInsert($0) },
                                onInsertRow: { editConfig?.onRowInsert(rowIdx) },
                                onCopyRow: { editConfig?.onRowCopy($0, rowIdx) },
                                onDeleteRow: editConfig?.onRowDelete,
                                editingCol: (editingCell?.rowIdx == rowIdx) ? editingCell?.col : nil,
                                // 非编辑行恒传 .text("") —— 编辑行按键时 editingDraft 频繁变，要避免触发所有行 re-render
                                editingDraft: (editingCell?.rowIdx == rowIdx) ? editingDraft : .text(""),
                                editIsSaving: (editingCell?.rowIdx == rowIdx) ? editIsSaving : false,
                                editHasError: (editingCell?.rowIdx == rowIdx) && (editError != nil),
                                editColumnDefs: editConfig?.columnDefs ?? [],
                                editIsExpanded: (editingCell?.rowIdx == rowIdx) && inlineExpandedEditor,
                                onDraftTextChange: { s in editingDraft = .text(s) },
                                onSetNull: { editingDraft = .null },
                                onClearNull: { editingDraft = .text("") },
                                onCommit: { Task { await commitEditIfChanged() } },
                                onCancelEdit: { cancelEdit() },
                                onTabNav: { forward in tabNav(forward: forward) },
                                onExpandEditor: { inlineExpandedEditor = true }
                            )
                            .equatable()
                            // 草稿恰好该出现在这行之后
                            if let draft = draftConfig, draft.insertAfterRowIndex == rowIdx {
                                DraftRowView(
                                    config: draft,
                                    columns: result.columns,
                                    columnWidths: columnWidths
                                )
                            }
                        }
                        // 表尾草稿（insertAfterRowIndex == nil；或位置超出已渲染范围 → 尾部兜底）
                        if let draft = draftConfig,
                           draft.insertAfterRowIndex == nil
                           || (draft.insertAfterRowIndex ?? -1) >= cachedRows.count {
                            DraftRowView(
                                config: draft,
                                columns: result.columns,
                                columnWidths: columnWidths
                            )
                        }
                    } header: {
                        headerRow(widths: columnWidths)
                            .background(Color(nsColor: .textBackgroundColor))
                    }
                }
                // 强制 LazyVStack 至少撑到 viewport 大小，alignment 顶左 → 内容贴左上角
                .frame(
                    minWidth: geo.size.width,
                    minHeight: geo.size.height,
                    alignment: .topLeading
                )
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var gridToolbar: some View {
        HStack(spacing: 6) {
            Spacer()
            Menu {
                Button("CSV") { exportToFile(format: .csv) }
                Button("TSV") { exportToFile(format: .tsv) }
                Divider()
                Button("拷贝全部为 CSV") { copyAllRows(separator: ",", quote: true) }
                Button("拷贝全部为 TSV") { copyAllRows(separator: "\t", quote: false) }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12))
                    .padding(.horizontal, 4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("导出当前结果（最多 \(maxClientResultRows) 行；超量见顶部提示）")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial)
    }

    private enum ExportFormat { case csv, tsv }

    private func exportToFile(format: ExportFormat) {
        let panel = NSSavePanel()
        panel.title = format == .csv ? "导出 CSV" : "导出 TSV"
        panel.nameFieldStringValue = defaultExportFilename(format: format)
        panel.allowedContentTypes = format == .csv
            ? [.commaSeparatedText]
            : [.tabSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch format {
            case .csv:
                try CSVExporter.write(result, to: url)
            case .tsv:
                // TSV 走 \t 分隔 + 不引号；最简单：把 \t / \n 替换掉
                var data = Data()
                data.append(Data((result.columns.joined(separator: "\t") + "\n").utf8))
                for row in result.rows {
                    let line = row.map { ($0 ?? "")
                        .replacingOccurrences(of: "\t", with: " ")
                        .replacingOccurrences(of: "\n", with: " ") }
                        .joined(separator: "\t")
                    data.append(Data((line + "\n").utf8))
                }
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // 导出失败提示：弹一个简单 NSAlert
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "导出失败"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    private func defaultExportFilename(format: ExportFormat) -> String {
        let ext = format == .csv ? "csv" : "tsv"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "result-\(formatter.string(from: Date())).\(ext)"
    }

    private func copyAllRows(separator: String, quote: Bool) {
        var lines: [String] = []
        lines.append(result.columns.map { quote ? csvQuote($0) : $0 }.joined(separator: separator))
        for row in result.rows {
            let cells = row.map { v -> String in
                let s = v ?? ""
                return quote ? csvQuote(s) : s
            }
            lines.append(cells.joined(separator: separator))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func csvQuote(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// 隐藏的快捷键路由：⌘C 拷贝选中行 / ⌘V 在选中行下方启动复制草稿 / Esc 取消草稿。
    /// SwiftUI Button keyboardShortcut 走 menu-style 分发 → first responder（TextField）先吃 →
    /// 没消费才到这里：所以 TextField focus 时 ⌘C/⌘V 仍是文本字段的内置行为，不冲突。
    /// `.opacity(0).frame(0).allowsHitTesting(false)` 让按钮不可见、不抢点击，但快捷键仍生效。
    @ViewBuilder
    private var keyboardShortcutRouter: some View {
        ZStack {
            Button("copy-row-shortcut") { handleCopyShortcut() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(selectedRowIdx == nil || editConfig == nil)
            Button("paste-row-shortcut") { handlePasteShortcut() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(editConfig == nil)
            if editingCell != nil {
                // 编辑态优先吃 Esc；不在编辑态时才让 draft 拿
                Button("cancel-edit-shortcut") { cancelEdit() }
                    .keyboardShortcut(.cancelAction)
            } else if draftConfig != nil {
                Button("cancel-draft-shortcut") { draftConfig?.onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func handleCopyShortcut() {
        guard let idx = selectedRowIdx, idx < cachedRows.count else { return }
        let row = cachedRows[idx]
        RowClipboard.shared.set(columns: result.columns, values: row)
        // 也写到系统剪贴板的 TSV，跨应用兼容（Excel / 编辑器粘贴）
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            row.map { $0 ?? "" }.joined(separator: "\t"),
            forType: .string
        )
    }

    private func handlePasteShortcut() {
        let cb = RowClipboard.shared
        guard !cb.isEmpty, let onCopy = editConfig?.onRowCopy else { return }
        // 把 clipboard 的 columns + values 按目标表的 columns 顺序重排
        // 跨表粘贴时只匹配同名列；不存在的列留 nil（=源不指定，DB 走默认）
        var aligned: [String?] = Array(repeating: nil, count: result.columns.count)
        for (cbIdx, name) in cb.columns.enumerated() {
            if let target = result.columns.firstIndex(of: name), cbIdx < cb.values.count {
                aligned[target] = cb.values[cbIdx]
            }
        }
        // 插入位置 = 当前选中行的下方；没选中走表尾（nil）
        onCopy(aligned, selectedRowIdx)
    }

    /// 草稿编辑提示条：纯状态显示。提交 / 取消由键盘走，不放按钮。
    /// 提交 = TextField onSubmit（回车）；取消 = .cancelAction 隐藏路由（Esc）。
    private func draftToolbar(_ cfg: DraftConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.line")
                .foregroundStyle(Color.accentColor)
            Text("新行编辑中")
                .font(.caption.weight(.semibold))
            Text("· ⏎ 保存 · ⎋ 取消 · 主键 / 自增列由 DB 生成")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let err = cfg.errorMessage {
                Text("· \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            Spacer()
            if cfg.isCommitting {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
    }

    /// 行内编辑提示条：常态显示快捷键提示；失败时显示红字错误。
    private var inlineEditBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.line")
                .foregroundStyle(Color.accentColor)
            Text("行内编辑中")
                .font(.caption.weight(.semibold))
            Text("· ⏎ 保存（值变才发 SQL） · ⎋ 取消 · ⇥ 下一列")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let err = editError {
                Text("· \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            Spacer()
            if editIsSaving {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
    }

    private var truncationBanner: some View {
        // 客户端层硬截断；服务端结果远不止 100k 行时提示用户加 LIMIT。
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("结果集过大，仅显示前 \(result.rows.count) 行")
                .font(.caption.weight(.medium))
            Text("· 请加 LIMIT / WHERE 缩小范围以查看完整数据")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }


    // MARK: - 行内编辑（in-place cell editing）

    /// 由 ResultRowView 双击 cell 时触发。
    /// 主键列 / editConfig 缺失 → 守门拦下不进入编辑态。
    private func beginEdit(rowIdx: Int, col: Int, originalValue: String?) {
        guard let cfg = editConfig else { return }
        guard col < result.columns.count else { return }
        let columnName = result.columns[col]
        guard !cfg.pkColumns.contains(columnName) else { return }
        editingCell = InlineEditingCell(rowIdx: rowIdx, col: col, originalValue: originalValue)
        // 永远以 .text 进入，让 TextField 一定 mount → 键盘 / focus / 提交链路始终生效。
        // 原值是 NULL 也用 .text("") 起步；用户要保留 NULL 走 Esc，要重新设 NULL 走右键菜单。
        // 副作用：原值是 NULL 时双击 + 回车（空字符串）会发 SET col = ''，与"什么都没改"语义不同；
        // 这是 spec 里"回车提交（值变了才发 SQL）"的直接推论，"" ≠ nil。
        editingDraft = .text(originalValue ?? "")
        editError = nil
        editIsSaving = false
    }

    /// Esc / 提交成功 / 边界 Tab 退出编辑态。
    private func cancelEdit() {
        editingCell = nil
        editingDraft = .text("")
        editError = nil
        editIsSaving = false
    }

    /// 提交：值变了才发 SQL；没变直接退出。
    /// 失败留态：editingCell 不动、editError 非空、editIsSaving 复位；UI 显红框 + 顶部 banner。
    @MainActor
    private func commitEditIfChanged() async {
        guard !editIsSaving else { return }
        guard let cell = editingCell, let cfg = editConfig else { return }
        let newValue = editingDraft.asNewValue
        if newValue == cell.originalValue {
            cancelEdit()
            return
        }
        guard cachedRows.indices.contains(cell.rowIdx) else { cancelEdit(); return }
        let snapshotRow = cachedRows[cell.rowIdx]
        let columnName = result.columns[cell.col]
        editIsSaving = true
        editError = nil
        do {
            try await cfg.onCellEdit(snapshotRow, columnName, newValue)
            cancelEdit()
        } catch {
            editError = error.localizedDescription
            editIsSaving = false
        }
    }

    /// 在指定行内、从 from 列出发，找下一个可编辑列（跳过主键）。
    /// forward=true 向右，否则向左。找不到返回 nil。
    private func findNextEditableCol(from: Int, in rowIdx: Int, forward: Bool) -> Int? {
        guard let cfg = editConfig else { return nil }
        let cols = result.columns
        let candidates: [Int]
        if forward {
            candidates = Array((from + 1)..<cols.count)
        } else {
            candidates = (0..<from).reversed()
        }
        return candidates.first { col in
            let name = cols[col]
            return !cfg.pkColumns.contains(name)
        }
    }

    /// Tab / Shift+Tab：先 commit 当前；成功则跳同行下一可编辑列；失败留在当前 cell 显错。
    private func tabNav(forward: Bool) {
        guard let pinned = editingCell else { return }
        Task {
            await commitEditIfChanged()
            if editError != nil { return }
            if let next = findNextEditableCol(from: pinned.col, in: pinned.rowIdx, forward: forward) {
                let originalValue = cachedRows.indices.contains(pinned.rowIdx)
                    ? (cachedRows[pinned.rowIdx].indices.contains(next) ? cachedRows[pinned.rowIdx][next] : nil)
                    : nil
                beginEdit(rowIdx: pinned.rowIdx, col: next, originalValue: originalValue)
            }
            // 边界：commit 已 cancelEdit 过，什么都不做
        }
    }

    private func headerRow(widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(result.columns.indices, id: \.self) { i in
                headerCell(i, widths: widths)
            }
        }
    }

    private func headerCell(_ i: Int, widths: [CGFloat]) -> some View {
        let width = widths.indices.contains(i) ? widths[i] : Self.defaultWidth
        return ZStack(alignment: .trailing) {
            Button {
                if sortColumn == i {
                    sortAscending.toggle()
                } else {
                    sortColumn = i
                    sortAscending = true
                }
            } label: {
                HStack(spacing: 4) {
                    Text(result.columns[i])
                        .font(.system(size: 14, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if sortColumn == i {
                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: width, alignment: .leading)
                .background(Color(nsColor: .underPageBackgroundColor))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { headerContextMenu(columnIndex: i) }
            .border(.quaternary)

            // 拖拽手柄：右侧 6px 的可拖区域；只在 onEnded 提交，避免每帧 re-render 全表
            Rectangle()
                .fill(Color.clear)
                .frame(width: 6)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            liveDragColumn = i
                            liveDragOffset = value.translation.width
                        }
                        .onEnded { value in
                            ensureWidths()
                            let newWidth = max(Self.minWidth, width + value.translation.width)
                            columnWidths[i] = newWidth
                            liveDragColumn = nil
                            liveDragOffset = 0
                        }
                )
                .onHover { hovering in
                    if hovering { NSCursor.resizeLeftRight.set() }
                    else { NSCursor.arrow.set() }
                }
                .overlay(
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 1)
                )
                .overlay(alignment: .center) {
                    // 拖拽中显示一条 accent 色预览线，跟着鼠标走
                    if liveDragColumn == i {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2)
                            .offset(x: liveDragOffset)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func headerContextMenu(columnIndex i: Int) -> some View {
        Group {
            Button("升序排序") { sortColumn = i; sortAscending = true }
            Button("降序排序") { sortColumn = i; sortAscending = false }
            Button("取消排序") { sortColumn = nil }
            Divider()
            Button("自适应列宽") {
                ensureWidths()
                columnWidths[i] = Self.defaultWidth
            }
            Divider()
            Button("复制全部 (TSV)") { copyAll(separator: "\t") }
            Button("复制全部 (CSV)") { copyAll(separator: ",", quote: true) }
        }
    }

    // MARK: helpers

    private func ensureWidths() {
        if columnWidths.count != result.columns.count {
            columnWidths = Array(repeating: Self.defaultWidth, count: result.columns.count)
        }
    }

    private func recomputeRows() {
        cachedRows = sortedRows()
    }

    private func sortedRows() -> [[String?]] {
        guard let col = sortColumn,
              col < result.columns.count else {
            return result.rows
        }
        return result.rows.sorted { a, b in
            let av = col < a.count ? a[col] : nil
            let bv = col < b.count ? b[col] : nil
            return sortAscending ? Self.lessThan(av, bv) : Self.lessThan(bv, av)
        }
    }

    private static func lessThan(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (av?, bv?):
            if let ad = Double(av), let bd = Double(bv) { return ad < bd }
            return av.localizedStandardCompare(bv) == .orderedAscending
        }
    }

    private func copyRow(_ row: [String?], separator: String, quote: Bool = false) {
        let text = row.map { fmt($0, quote: quote) }.joined(separator: separator)
        write(text)
    }

    private func copyRowAsInsert(_ row: [String?]) {
        let cols = result.columns.joined(separator: ", ")
        let vals = row.map { value -> String in
            guard let v = value else { return "NULL" }
            return "'\(v.replacingOccurrences(of: "'", with: "''"))'"
        }.joined(separator: ", ")
        write("INSERT INTO <table> (\(cols)) VALUES (\(vals));")
    }

    private func copyAll(separator: String, quote: Bool = false) {
        var lines: [String] = []
        lines.append(result.columns.map { fmt($0, quote: quote) }.joined(separator: separator))
        for row in cachedRows {
            lines.append(row.map { fmt($0, quote: quote) }.joined(separator: separator))
        }
        write(lines.joined(separator: "\n"))
    }

    private func fmt(_ value: String?, quote: Bool) -> String {
        let s = value ?? ""
        if quote {
            let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return s
    }

    private func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// `.sheet(item:)` 用的 Identifiable 包装；String 自身不能直接做 item。
private struct DraftExpandTarget: Identifiable, Equatable {
    let name: String
    var id: String { name }
}

/// 草稿行：inline TextField 编辑，列宽与表头对齐。
/// - PK / auto_increment 列：禁用 + 显示「(自增)」/「(由 DB 定)」灰底
/// - 普通列：TextField；右键菜单可切「NULL」/「重置为默认」/「在大编辑器中打开」
struct DraftRowView: View {
    let config: ResultGrid.DraftConfig
    let columns: [String]
    let columnWidths: [CGFloat]

    @FocusState private var focusedColumn: String?
    @State private var expandedColumn: DraftExpandTarget?

    private static let defaultWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { col in
                let name = columns[col]
                let width = columnWidths.indices.contains(col) ? columnWidths[col] : Self.defaultWidth
                cell(for: name, width: width)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.gray.opacity(0.12)).frame(width: 0.5)
                    }
            }
        }
        .background(Color.accentColor.opacity(0.06))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.accentColor).frame(width: 2)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(height: 1)
        }
        .disabled(config.isCommitting)
        .onAppear {
            // 启动草稿 → 第一个非 PK / 非自增列 focus，光标进 TextField，立即可输入 + ⏎ 提交
            if focusedColumn == nil {
                focusedColumn = firstEditableColumn()
            }
        }
        .sheet(item: $expandedColumn) { target in
            let def = columnDef(target.name)
            let entry = config.values[target.name]
            let isNull = (entry.map { $0 == .some(nil) } ?? false)
            let initialText: String = {
                if case .some(.some(let s)) = entry { return s }
                return ""
            }()
            CellEditorSheet(
                columnName: target.name,
                columnDef: def,
                initialText: initialText,
                initialIsNull: isNull,
                allowSetNull: def?.nullable ?? false,
                allowResetDefault: true
            ) { outcome in
                switch outcome {
                case .text(let s): config.onSetValue(target.name, s)
                case .null: config.onSetNull(target.name)
                case .resetDefault: config.onResetToDefault(target.name)
                }
            }
        }
    }

    private func firstEditableColumn() -> String? {
        for name in columns {
            if let def = columnDef(name), def.isPrimaryKey || def.isAutoIncrement { continue }
            return name
        }
        return nil
    }

    private func columnDef(_ name: String) -> ColumnDefinition? {
        config.columnDefs.first { $0.name == name }
    }

    @ViewBuilder
    private func cell(for name: String, width: CGFloat) -> some View {
        let def = columnDef(name)
        let isAuto = def?.isAutoIncrement ?? false
        let isPK = def?.isPrimaryKey ?? false
        // 主键 / auto_increment 列：占位 + 禁用
        if isAuto || isPK {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10))
                Text(isAuto ? "(自增)" : "(主键，由 DB 定)")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(Color.secondary.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: width, alignment: .leading)
            .help("此列由 DB 自动生成；不能手动指定")
        } else {
            let entry = config.values[name]
            let isNull = (entry.map { $0 == .some(nil) } ?? false)
            HStack(spacing: 4) {
                if isNull {
                    Text("NULL")
                        .font(.system(size: 13, design: .monospaced).italic())
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(placeholderText(def: def), text: textBinding(for: name))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(1)
                        .focused($focusedColumn, equals: name)
                        .onSubmit { config.onCommit() }
                        .onKeyPress(keys: [.return]) { keyPress in
                            // Shift+Enter → 弹出扩展编辑器；普通 Enter 留给 onSubmit
                            if keyPress.modifiers.contains(.shift) {
                                expandedColumn = DraftExpandTarget(name: name)
                                return .handled
                            }
                            return .ignored
                        }
                }
                Button {
                    expandedColumn = DraftExpandTarget(name: name)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("在大编辑器中打开（Shift+Enter）")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu { cellContextMenu(name: name, def: def, isNull: isNull) }
        }
    }

    @ViewBuilder
    private func cellContextMenu(name: String, def: ColumnDefinition?, isNull: Bool) -> some View {
        let nullable = def?.nullable ?? true
        let hasDefault = (def?.defaultValue.map { !$0.isEmpty } ?? false)
        Button("在大编辑器中打开…") { expandedColumn = DraftExpandTarget(name: name) }
        Divider()
        if nullable {
            Button(isNull ? "取消 NULL（输入值）" : "设为 NULL") {
                if isNull {
                    config.onSetValue(name, "")
                } else {
                    config.onSetNull(name)
                }
            }
        }
        if hasDefault {
            Button("重置为 DEFAULT（\(def?.defaultValue ?? "")）") {
                config.onResetToDefault(name)
            }
        } else {
            Button("清空（不写此列，由 DB 处理）") {
                config.onResetToDefault(name)
            }
            .disabled(config.values[name] == nil)
        }
    }

    private func placeholderText(def: ColumnDefinition?) -> String {
        guard let def else { return "" }
        if let d = def.defaultValue, !d.isEmpty { return "DEFAULT \(d)" }
        if def.nullable { return "(空 = NULL / 不写)" }
        return def.dataType
    }

    private func textBinding(for name: String) -> Binding<String> {
        Binding(
            get: {
                if case .some(.some(let s)) = config.values[name] { return s }
                return ""
            },
            set: { config.onSetValue(name, $0) }
        )
    }
}

/// 给 row 接管左键点击 / 双击的事件路由。
/// SwiftUI 的 `TapGesture(count:1)` 和 `(count:2)` 共存时单击会等 ~500ms 区分；
/// 用两个独立 `NSClickGestureRecognizer`（buttonMask=0x1 仅左键）：
///   - single (numberOfClicksRequired=1) 单击立即 fire
///   - double (numberOfClicksRequired=2) 双击时再 fire（single 已先 fire 过）
/// 右键不在 buttonMask 内 → SwiftUI 的 `.contextMenu` 不受影响。
struct RowClickRouter: NSViewRepresentable {
    let onSingleClick: (CGPoint) -> Void
    let onDoubleClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let single = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingle(_:))
        )
        single.numberOfClicksRequired = 1
        single.buttonMask = 0x1
        let double = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDouble(_:))
        )
        double.numberOfClicksRequired = 2
        double.buttonMask = 0x1
        v.addGestureRecognizer(single)
        v.addGestureRecognizer(double)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onSingleClick = onSingleClick
        context.coordinator.onDoubleClick = onDoubleClick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleClick: onSingleClick, onDoubleClick: onDoubleClick)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSingleClick: (CGPoint) -> Void
        var onDoubleClick: (CGPoint) -> Void
        init(onSingleClick: @escaping (CGPoint) -> Void,
             onDoubleClick: @escaping (CGPoint) -> Void) {
            self.onSingleClick = onSingleClick
            self.onDoubleClick = onDoubleClick
        }
        @objc func handleSingle(_ g: NSClickGestureRecognizer) {
            guard let v = g.view else { return }
            onSingleClick(g.location(in: v))
        }
        @objc func handleDouble(_ g: NSClickGestureRecognizer) {
            guard let v = g.view else { return }
            onDoubleClick(g.location(in: v))
        }
    }
}

struct ResultRowView: View, Equatable {
    let row: [String?]
    let rowIdx: Int
    let columnWidths: [CGFloat]
    let columns: [String]
    let isSelected: Bool
    let onSelectRow: (Int) -> Void
    let onDoubleTap: (Int, Int, String?) -> Void   // (rowIdx, col, value)
    let onCopyTSV: ([String?]) -> Void
    let onCopyCSV: ([String?]) -> Void
    let onCopyInsert: ([String?]) -> Void
    /// 非 nil 才显示「插入新行」右键项（说明父层已配 EditConfig）
    let onInsertRow: (() -> Void)?
    /// 非 nil 才显示「复制为新行」右键项（同 EditConfig 配套）
    let onCopyRow: (([String?]) -> Void)?
    /// 非 nil 才显示「删除此行」右键项（说明表有主键、可定位）
    let onDeleteRow: (([String?]) -> Void)?

    // MARK: 行内编辑 props（nil = 该行不在编辑态）
    /// 当前编辑列号；非 nil 时该 cell 渲染 TextField。
    let editingCol: Int?
    /// 当前草稿；仅在 editingCol != nil 时使用。
    let editingDraft: InlineEditingDraft
    /// 保存中 → TextField disabled + 右侧 ProgressView。
    let editIsSaving: Bool
    /// 该行的编辑 cell 是否失败 → 红框。
    let editHasError: Bool
    /// 列定义（用于右键 "设为 NULL" 只在 nullable 列显示）；可能空数组。
    let editColumnDefs: [ColumnDefinition]
    /// 父层"扩展编辑器"sheet 是否已打开。打开时本 cell 的 TextField 失焦不应再触发
    /// 自动 commit —— 否则 sheet 一弹起就 commit + cancelEdit，sheet 拿到空状态。
    let editIsExpanded: Bool

    let onDraftTextChange: (String) -> Void
    let onSetNull: () -> Void
    let onClearNull: () -> Void
    let onCommit: () -> Void
    let onCancelEdit: () -> Void
    let onTabNav: (_ forward: Bool) -> Void
    /// 行内编辑态下 ↗ 按钮 / Shift+Enter 触发：父层弹 CellEditorSheet。
    let onExpandEditor: () -> Void

    /// 缓存闭包的 nil 状态。`==` 是 `nonisolated`，不能直接读非 Sendable 的闭包属性；
    /// 用 Sendable 的 Bool 镜像来比较 —— 仍然能感知 editConfig 从 nil → 非 nil 的转变。
    private let hasInsertHook: Bool
    private let hasCopyHook: Bool
    private let hasDeleteHook: Bool

    init(
        row: [String?],
        rowIdx: Int,
        columnWidths: [CGFloat],
        columns: [String],
        isSelected: Bool,
        onSelectRow: @escaping (Int) -> Void,
        onDoubleTap: @escaping (Int, Int, String?) -> Void,
        onCopyTSV: @escaping ([String?]) -> Void,
        onCopyCSV: @escaping ([String?]) -> Void,
        onCopyInsert: @escaping ([String?]) -> Void,
        onInsertRow: (() -> Void)?,
        onCopyRow: (([String?]) -> Void)?,
        onDeleteRow: (([String?]) -> Void)?,
        editingCol: Int?,
        editingDraft: InlineEditingDraft,
        editIsSaving: Bool,
        editHasError: Bool,
        editColumnDefs: [ColumnDefinition],
        editIsExpanded: Bool,
        onDraftTextChange: @escaping (String) -> Void,
        onSetNull: @escaping () -> Void,
        onClearNull: @escaping () -> Void,
        onCommit: @escaping () -> Void,
        onCancelEdit: @escaping () -> Void,
        onTabNav: @escaping (_ forward: Bool) -> Void,
        onExpandEditor: @escaping () -> Void
    ) {
        self.row = row
        self.rowIdx = rowIdx
        self.columnWidths = columnWidths
        self.columns = columns
        self.isSelected = isSelected
        self.onSelectRow = onSelectRow
        self.onDoubleTap = onDoubleTap
        self.onCopyTSV = onCopyTSV
        self.onCopyCSV = onCopyCSV
        self.onCopyInsert = onCopyInsert
        self.onInsertRow = onInsertRow
        self.onCopyRow = onCopyRow
        self.onDeleteRow = onDeleteRow
        self.hasInsertHook = onInsertRow != nil
        self.hasCopyHook = onCopyRow != nil
        self.hasDeleteHook = onDeleteRow != nil
        self.editingCol = editingCol
        self.editingDraft = editingDraft
        self.editIsSaving = editIsSaving
        self.editHasError = editHasError
        self.editColumnDefs = editColumnDefs
        self.editIsExpanded = editIsExpanded
        self.onDraftTextChange = onDraftTextChange
        self.onSetNull = onSetNull
        self.onClearNull = onClearNull
        self.onCommit = onCommit
        self.onCancelEdit = onCancelEdit
        self.onTabNav = onTabNav
        self.onExpandEditor = onExpandEditor
    }

    private static let defaultWidth: CGFloat = 160

    /// 闭包不参与 ==，避免每次父 body 都判定为不同；只对真正要看的数据做相等判断。
    /// 「闭包是否存在」通过 Sendable 的 Bool 镜像参与比较 —— 否则 editConfig 从 nil
    /// （列定义未到）变非 nil 后，equatable() 沿用首帧的 nil 闭包，菜单不显示。
    nonisolated static func == (lhs: ResultRowView, rhs: ResultRowView) -> Bool {
        lhs.rowIdx == rhs.rowIdx &&
        lhs.row == rhs.row &&
        lhs.columnWidths == rhs.columnWidths &&
        lhs.columns == rhs.columns &&
        lhs.isSelected == rhs.isSelected &&
        lhs.hasInsertHook == rhs.hasInsertHook &&
        lhs.hasCopyHook == rhs.hasCopyHook &&
        lhs.hasDeleteHook == rhs.hasDeleteHook &&
        lhs.editingCol == rhs.editingCol &&
        lhs.editingDraft == rhs.editingDraft &&
        lhs.editIsSaving == rhs.editIsSaving &&
        lhs.editHasError == rhs.editHasError &&
        lhs.editIsExpanded == rhs.editIsExpanded
    }

    @FocusState private var editFocus: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(row.indices, id: \.self) { col in
                let width = columnWidths.indices.contains(col) ? columnWidths[col] : Self.defaultWidth
                cellView(col: col, width: width)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: width, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.gray.opacity(0.12)).frame(width: 0.5)
                    }
            }
        }
        .background(rowBackground)
        .overlay(alignment: .leading) {
            // 选中时左侧 accent 色条；2pt 宽，不挤掉单元格
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.gray.opacity(0.1)).frame(height: 0.5)
        }
        .contentShape(Rectangle())
        // 单击 + 双击：SwiftUI gesture 单/双共存时单击会等 ~500ms double-click interval。
        // 用两个独立 NSClickGestureRecognizer（buttonMask=左键）替代 — 单击零延迟立即 fire，
        // 双击时单击 recognizer 仍会先 fire（→ 选中行），随后 double fire（→ 弹编辑器）。
        // 体感和 Finder / NSTableView 一致。右键不在 buttonMask 内，contextMenu 照常工作。
        .overlay(
            RowClickRouter(
                onSingleClick: { _ in onSelectRow(rowIdx) },
                onDoubleClick: { pt in
                    let col = columnIndex(at: pt.x)
                    if col >= 0, col < row.count {
                        onDoubleTap(rowIdx, col, row[col])
                    }
                }
            )
        )
        .contextMenu {
            Button("复制行 (TSV)") { onCopyTSV(row) }
            Button("复制行 (CSV)") { onCopyCSV(row) }
            Button("复制为 INSERT") { onCopyInsert(row) }
            if onInsertRow != nil || onCopyRow != nil || onDeleteRow != nil {
                Divider()
                if let insert = onInsertRow {
                    Button("插入新行…") { insert() }
                }
                if let copy = onCopyRow {
                    Button("复制为新行（不含主键）…") { copy(row) }
                }
                if let delete = onDeleteRow {
                    Button("删除此行…", role: .destructive) { delete(row) }
                        .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(col: Int, width: CGFloat) -> some View {
        if col == editingCol {
            editingCell(col: col)
        } else {
            displayCell(col: col)
        }
    }

    @ViewBuilder
    private func displayCell(col: Int) -> some View {
        if let value = row[col] {
            Text(value)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.primary)
        } else {
            Text("NULL")
                .font(.system(size: 14, design: .monospaced).italic())
                .foregroundStyle(Color.secondary.opacity(0.6))
        }
    }

    @ViewBuilder
    private func editingCell(col: Int) -> some View {
        let isNull: Bool = { if case .null = editingDraft { return true } else { return false } }()
        HStack(spacing: 4) {
            if isNull {
                Text("NULL")
                    .font(.system(size: 13, design: .monospaced).italic())
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            } else {
                TextField("", text: Binding(
                    get: {
                        if case .text(let s) = editingDraft { return s }
                        return ""
                    },
                    set: { onDraftTextChange($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .focused($editFocus)
                .disabled(editIsSaving)
                .onSubmit { onCommit() }
                .onAppear { editFocus = true }
                .onChange(of: editFocus) { _, focused in
                    // 失焦提交（commit 内部会判 "值变了才发 SQL"）。
                    // 但扩展编辑器 sheet 打开时 TextField 必然失焦——这里跳过，
                    // 否则 sheet 一弹立刻 commit + cancelEdit。
                    if !focused && !editIsExpanded { onCommit() }
                }
                .onKeyPress(.escape) {
                    onCancelEdit()
                    return .handled
                }
                .onKeyPress(keys: [.tab]) { keyPress in
                    let forward = !keyPress.modifiers.contains(.shift)
                    onTabNav(forward)
                    return .handled
                }
                .onKeyPress(keys: [.return]) { keyPress in
                    // Shift+Enter → 弹出扩展编辑器；普通 Enter 不消费，留给 onSubmit
                    if keyPress.modifiers.contains(.shift) {
                        onExpandEditor()
                        return .handled
                    }
                    return .ignored
                }
            }
            // ↗ 按钮：弹出 CellEditorSheet（多行 + JSON 格式化等）
            // 列宽极窄时仍显示——它只占 18pt，TextField 会让出空间
            Button {
                onExpandEditor()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("在大编辑器中打开（Shift+Enter）")
            .disabled(editIsSaving)

            if editIsSaving {
                ProgressView().controlSize(.mini)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 2)
                .stroke(editHasError ? Color.red : Color.accentColor, lineWidth: 1)
        )
        .contextMenu { editingCellContextMenu(col: col) }
    }

    @ViewBuilder
    private func editingCellContextMenu(col: Int) -> some View {
        let columnName = columns[safe: col] ?? ""
        let def = editColumnDefs.first { $0.name == columnName }
        let nullable = def?.nullable ?? false
        let isNull: Bool = { if case .null = editingDraft { return true } else { return false } }()
        Button("在大编辑器中打开…") { onExpandEditor() }
        Divider()
        if nullable {
            if isNull {
                Button("取消 NULL（输入值）") { onClearNull() }
            } else {
                Button("设为 NULL") { onSetNull() }
            }
        }
        Button("取消编辑") { onCancelEdit() }
    }

    /// 选中色压过斑马条；未选中走原来的奇偶斑马条。
    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        return rowIdx.isMultiple(of: 2) ? Color.clear : Color.gray.opacity(0.04)
    }

    private func columnIndex(at x: CGFloat) -> Int {
        var accumulated: CGFloat = 0
        for col in 0..<row.count {
            let width = columnWidths.indices.contains(col) ? columnWidths[col] : Self.defaultWidth
            accumulated += width
            if x < accumulated { return col }
        }
        return row.count - 1
    }
}

/// 进程内行剪贴板（⌘C 写 / ⌘V 读）。
/// 同时也写 NSPasteboard 的 TSV 形式让外部应用粘贴，但不依赖 NSPasteboard 的回读（避免
/// 复杂的格式协商；本程序内的行复制走 in-memory 路径）。
@Observable
@MainActor
final class RowClipboard {
    static let shared = RowClipboard()
    private(set) var columns: [String] = []
    private(set) var values: [String?] = []
    var isEmpty: Bool { columns.isEmpty }

    func set(columns: [String], values: [String?]) {
        self.columns = columns
        self.values = values
    }

    func clear() {
        columns = []
        values = []
    }
}
