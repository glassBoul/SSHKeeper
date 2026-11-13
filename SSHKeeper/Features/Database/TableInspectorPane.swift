import SwiftUI
import SSHKeeperCore

struct TableInspectorPane: View {
    @Bindable var session: DatabaseSession
    @State private var filterDraft: String = ""
    @State private var filterRows: [FilterRow] = []
    @State private var pendingDelete: PendingDelete?
    @State private var operationError: String?
    /// 草稿提交进行中（禁用按钮 + ProgressView）
    @State private var draftCommitting: Bool = false
    /// 草稿提交失败时的错误（显示在 ResultGrid 的草稿工具条里）
    @State private var draftError: String?

    /// 行删除 — 经 confirmationDialog 二次确认。
    private struct PendingDelete: Identifiable {
        let id = UUID()
        let primaryKey: [String: String]
        let tableLabel: String
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: session.inspector.inspectorTab) {
            await session.inspector.loadInspector(tab: session.inspector.inspectorTab)
        }
        .onChange(of: session.inspector.selectedTable?.id) { _, _ in
            syncFilterRowsFromState()
        }
        .onAppear {
            syncFilterRowsFromState()
        }
        .confirmationDialog(
            "确认删除这一行吗？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { item in
            Button("删除", role: .destructive) {
                let primaryKey = item.primaryKey
                Task {
                    do {
                        try await session.inspector.deleteRow(primaryKey: primaryKey)
                    } catch {
                        operationError = "删除失败：\(error.localizedDescription)"
                    }
                }
            }
            Button("取消", role: .cancel) { }
        } message: { item in
            let pkText = item.primaryKey.keys.sorted()
                .map { "\($0) = \(item.primaryKey[$0]!)" }
                .joined(separator: ", ")
            Text("\(item.tableLabel)\n\(pkText)\n\n「删除」操作不可撤销。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            ),
            presenting: operationError
        ) { _ in
            Button("好") { operationError = nil }
        } message: { msg in
            Text(msg).textSelection(.enabled)
        }
    }

    /// 「dbname.tablename」/「schema.tablename」统一显示。PG 的 `name` 已含 schema，避免重复。
    private func qualifiedLabel(_ t: DatabaseObject) -> String {
        if let parent = t.parent, !t.name.contains(".") {
            return "\(parent).\(t.name)"
        }
        return t.name
    }

    /// 启动 inline 空白草稿行（替代旧的 RowInsertSheet 弹窗）。
    /// 列定义未缓存时先 await 加载，确保 PK / auto_increment 标记可用。
    private func startBlankDraft(insertAfter rowIdx: Int? = nil) async {
        guard session.inspector.selectedTable != nil else { return }
        if session.inspector.currentColumnDefinitions() == nil {
            await session.inspector.loadColumnDefinitions()
        }
        draftError = nil
        session.inspector.startBlankDraft(insertAfter: rowIdx)
    }

    /// 复制现有行 → 启动以该行为模板的草稿（主键 / auto_increment 列被剔除）。
    private func startCopyDraft(from row: [String?], columnNames: [String], insertAfter rowIdx: Int?) async {
        guard session.inspector.selectedTable != nil else { return }
        if session.inspector.currentColumnDefinitions() == nil {
            await session.inspector.loadColumnDefinitions()
        }
        draftError = nil
        session.inspector.startDraftCopying(from: row, columnNames: columnNames, insertAfter: rowIdx)
    }

    private func commitDraft() {
        guard !draftCommitting else { return }
        draftError = nil
        draftCommitting = true
        Task {
            defer { draftCommitting = false }
            do {
                try await session.inspector.commitDraft()
            } catch {
                draftError = error.localizedDescription
            }
        }
    }

    private func cancelDraft() {
        draftError = nil
        session.inspector.cancelDraft()
    }

    private func syncFilterRowsFromState() {
        let cached = session.inspector.currentFilterRows
        if cached.isEmpty {
            filterRows = [FilterRow(column: defaultColumnName())]
        } else {
            filterRows = cached
        }
    }

    private func defaultColumnName() -> String {
        if let col = session.inspector.currentColumnDefinitions()?.first?.name { return col }
        if let col = session.inspector.currentInspectorResult()?.columns.first { return col }
        return ""
    }

    /// 仅在「内容」tab 且表有主键时返回非空 → ResultGrid 启用单元格编辑 + 行级增删。
    private func contentEditConfig(for result: QueryResult) -> ResultGrid.EditConfig? {
        guard session.inspector.inspectorTab == .content else { return nil }
        let cols = session.inspector.currentColumnDefinitions() ?? []
        let pkNames = Set(cols.filter { $0.isPrimaryKey }.map { $0.name })
        guard !pkNames.isEmpty else { return nil }
        let inspector = session.inspector
        let resultCols = result.columns
        let tableLabel = session.inspector.selectedTable.map(qualifiedLabel) ?? ""
        return ResultGrid.EditConfig(
            pkColumns: pkNames,
            columnDefs: cols,
            onCellEdit: { row, columnName, newValue in
                var pkValues: [String: String] = [:]
                for (i, name) in resultCols.enumerated() where pkNames.contains(name) {
                    if let v = row[safe: i] ?? nil {
                        pkValues[name] = v
                    }
                }
                guard pkValues.count == pkNames.count else {
                    throw DatabaseClientError.invalidConfiguration("当前行没拿到完整主键值，无法定位")
                }
                try await inspector.updateRow(
                    primaryKey: pkValues,
                    column: columnName,
                    value: newValue
                )
            },
            onRowDelete: { row in
                var pkValues: [String: String] = [:]
                for (i, name) in resultCols.enumerated() where pkNames.contains(name) {
                    if let v = row[safe: i] ?? nil {
                        pkValues[name] = v
                    }
                }
                guard pkValues.count == pkNames.count else { return }
                pendingDelete = PendingDelete(primaryKey: pkValues, tableLabel: tableLabel)
            },
            onRowInsert: { idx in
                Task { await startBlankDraft(insertAfter: idx) }
            },
            onRowCopy: { row, idx in
                Task { await startCopyDraft(from: row, columnNames: resultCols, insertAfter: idx) }
            }
        )
    }

    /// 仅在 inspector 持有 draft 且当前选中表的列定义可用时构造，喂给 ResultGrid 渲染 inline 编辑行。
    private func contentDraftConfig() -> ResultGrid.DraftConfig? {
        guard let draft = session.inspector.draftRow,
              let table = session.inspector.selectedTable,
              draft.tableID == table.id else { return nil }
        let defs = session.inspector.currentColumnDefinitions() ?? []
        guard !defs.isEmpty else { return nil }
        let inspector = session.inspector
        return ResultGrid.DraftConfig(
            columnDefs: defs,
            values: draft.values,
            insertAfterRowIndex: draft.insertAfterRowIndex,
            onSetValue: { col, v in inspector.setDraftValue(column: col, value: v) },
            onSetNull: { col in inspector.setDraftNull(column: col) },
            onResetToDefault: { col in inspector.resetDraftToDefault(column: col) },
            onCommit: { commitDraft() },
            onCancel: { cancelDraft() },
            errorMessage: draftError,
            isCommitting: draftCommitting
        )
    }

    private var availableColumns: [String] {
        if let cols = session.inspector.currentColumnDefinitions(), !cols.isEmpty {
            return cols.map(\.name)
        }
        return session.inspector.currentInspectorResult()?.columns ?? []
    }

    private var contentFilterBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头：标题 + 启用条数（多于 1 时才显示计数）
            HStack(spacing: 6) {
                Text("筛选")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                if activeFilterCount > 0 {
                    Text("\(activeFilterCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                }
                Spacer()
            }
            .padding(.bottom, 6)

            VStack(spacing: 3) {
                ForEach(filterRows.indices, id: \.self) { i in
                    filterRowView(index: i)
                }
            }

            // 尾：清空 + 应用
            HStack(spacing: 8) {
                Button {
                    filterRows = [FilterRow(column: defaultColumnName())]
                    Task {
                        session.inspector.setFilterRows(filterRows)
                        await session.inspector.applyFilterRows(kind: session.database.kind)
                    }
                } label: {
                    Text("清空")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(filterRows.count == 1 && filterRows[0].value.isEmpty && !filterRows[0].op.needsValue == false)

                Spacer()

                Button {
                    Task {
                        session.inspector.setFilterRows(filterRows)
                        await session.inspector.applyFilterRows(kind: session.database.kind)
                    }
                } label: {
                    Text("应用筛选")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var activeFilterCount: Int {
        filterRows.filter { $0.isExecutable }.count
    }

    @ViewBuilder
    private func filterRowView(index i: Int) -> some View {
        let row = filterRows[safe: i]
        let enabled = row?.enabled ?? true

        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { filterRows[safe: i]?.enabled ?? true },
                set: { newValue in
                    guard filterRows.indices.contains(i) else { return }
                    filterRows[i].enabled = newValue
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            // 字段
            Menu {
                ForEach(availableColumns, id: \.self) { col in
                    Button(col) {
                        guard filterRows.indices.contains(i) else { return }
                        filterRows[i].column = col
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(row?.column.isEmpty == false ? row!.column : "选择列")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(row?.column.isEmpty == false ? .primary : .tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 150)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            // 操作符
            Menu {
                ForEach(FilterOp.allCases) { op in
                    Button(op.displayName) {
                        guard filterRows.indices.contains(i) else { return }
                        filterRows[i].op = op
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(row?.op.displayName ?? FilterOp.equals.displayName)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 140)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            // 值输入
            if let row, row.op.needsValue {
                TextField(row.op.valuePlaceholder, text: Binding(
                    get: { filterRows[safe: i]?.value ?? "" },
                    set: { newValue in
                        guard filterRows.indices.contains(i) else { return }
                        filterRows[i].value = newValue
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity)
                .onSubmit {
                    Task {
                        session.inspector.setFilterRows(filterRows)
                        await session.inspector.applyFilterRows(kind: session.database.kind)
                    }
                }
                if row.op.needsSecondValue {
                    Text("AND")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                    TextField("结束值", text: Binding(
                        get: { filterRows[safe: i]?.value2 ?? "" },
                        set: { newValue in
                            guard filterRows.indices.contains(i) else { return }
                            filterRows[i].value2 = newValue
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: .infinity)
                }
            } else {
                // 占位让 +/- 不挪位
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }

            // - / +
            HStack(spacing: 2) {
                Button {
                    if filterRows.count > 1 {
                        filterRows.remove(at: i)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(filterRows.count <= 1 ? Color.secondary.opacity(0.3) : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(filterRows.count <= 1)
                .help("删除此条筛选")

                Button {
                    let col = filterRows[safe: i]?.column ?? defaultColumnName()
                    let newRow = FilterRow(column: col)
                    filterRows.insert(newRow, at: i + 1)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("在下方添加一条")
            }
        }
        .opacity(enabled ? 1.0 : 0.45)
        .animation(.easeInOut(duration: 0.12), value: enabled)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(TableInspectorTab.allCases) { tab in
                Button {
                    // 即时切换：直接同步赋值，加载由 .task(id: inspectorTab) 异步触发。
                    session.inspector.inspectorTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 16, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            session.inspector.inspectorTab == tab ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    session.inspector.inspectorTab == tab ? Color.accentColor.opacity(0.5) : .clear,
                                    lineWidth: 1
                                )
                        )
                        // .plain 下按钮的 hit-test 默认贴 label 的渲染内容（文字+图标），
                        // 点在外侧的 padding/背景上不响应 → 用户感觉「点了一下没反应、要点两次」。
                        // 显式声明整个矩形都接管点击。
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                Task { await session.inspector.reloadCurrentInspector() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.bordered)
            .help("刷新当前标签")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var content: some View {
        if session.inspector.loadingInspector {
            VStack(spacing: 12) {
                ProgressView()
                Button("取消") {
                    Task { await session.cancelActiveQuery() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = session.inspector.currentInspectorError() {
            ContentUnavailableView {
                Label("加载失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("重试") { Task { await session.inspector.reloadCurrentInspector() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.inspector.inspectorTab == .info {
            // 「表信息」走 TableInfoView 富格式
            if let detail = session.inspector.currentTableInfoDetail() {
                TableInfoView(
                    detail: detail,
                    canEditMetadata: session.database.kind == .mysql,
                    onSave: { changes in
                        do {
                            try await session.inspector.saveTableMetadata(changes)
                        } catch {
                            // 错误会在 reload 后体现在加载流程；这里静默
                        }
                    },
                    onReload: {
                        await session.inspector.reloadInfoDetail()
                    }
                )
                .id(detail.tableName)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if session.inspector.inspectorTab == .structure {
            // 「结构」走 TableStructureView，可编辑
            TableStructureView(
                inspector: session.inspector,
                canEdit: session.database.kind == .mysql || session.database.kind == .postgres
            )
            .id(session.inspector.selectedTable?.id ?? "none")
        } else if let result = session.inspector.currentInspectorResult() {
            VStack(spacing: 0) {
                if session.inspector.inspectorTab == .content {
                    contentFilterBar
                    Divider()
                }
                HStack {
                    Text("\(result.rows.count) 行 · \(String(format: "%.2f", result.executionTime * 1000)) ms")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                Divider()
                if result.columns.isEmpty {
                    ContentUnavailableView("无数据", systemImage: "tablecells.badge.ellipsis")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ResultGrid(
                        result: result,
                        editConfig: contentEditConfig(for: result),
                        draftConfig: contentDraftConfig()
                    )
                }
                if session.inspector.inspectorTab == .content {
                    Divider()
                    paginationFooter
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var paginationFooter: some View {
        HStack(spacing: 12) {
            Button {
                Task { await session.inspector.prevContentPage() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(session.inspector.currentContentPage <= 0)

            Text(pageStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                Task { await session.inspector.nextContentPage() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(isLastPage)

            Spacer()

            Button {
                Task { await startBlankDraft() }
            } label: {
                Label("新增行", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(session.inspector.selectedTable == nil || session.inspector.draftRow != nil)
            .help("在表格首行启动 inline 编辑")

            Text("每页")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("每页", selection: Binding(
                get: { session.inspector.contentPageSize },
                set: { newValue in
                    Task { await session.inspector.setContentPageSize(newValue) }
                }
            )) {
                Text("100").tag(100)
                Text("200").tag(200)
                Text("500").tag(500)
                Text("1000").tag(1000)
            }
            .labelsHidden()
            .frame(width: 80)
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    private var pageStatusText: String {
        let page = session.inspector.currentContentPage + 1
        if let total = session.inspector.currentContentTotalPages, let rows = session.inspector.currentContentRowCount {
            return "第 \(page) / \(total) 页 · 共 \(rows) 行"
        }
        if session.inspector.currentContentRowCountTimedOut {
            return "第 \(page) 页（行数计算超时）"
        }
        return "第 \(page) 页"
    }

    private var isLastPage: Bool {
        if let total = session.inspector.currentContentTotalPages {
            return session.inspector.currentContentPage >= total - 1
        }
        // 不知道总数时：如果当前页数据不足一页就到底
        if let result = session.inspector.currentInspectorResult() {
            return result.rows.count < session.inspector.contentPageSize
        }
        return false
    }
}
