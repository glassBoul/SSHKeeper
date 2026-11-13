import SwiftUI
import SSHKeeperCore

private enum StructureSubTab: Hashable, CaseIterable {
    case fields
    case indexes
    var title: String {
        switch self {
        case .fields: "字段"
        case .indexes: "索引"
        }
    }
}

struct TableStructureView: View {
    @Bindable var inspector: TableInspectorState
    let canEdit: Bool

    @State private var subTab: StructureSubTab = .fields
    @State private var editorTarget: ColumnEditorTarget?
    @State private var indexEditorTarget: IndexEditorTarget?
    @State private var deleteCandidate: ColumnDefinition?
    @State private var deleteIndexCandidate: IndexDefinition?
    @State private var actionError: String?
    @State private var actionRunning: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            subTabBar
            Divider()
            switch subTab {
            case .fields:
                toolbar
                Divider()
                list
            case .indexes:
                indexToolbar
                Divider()
                indexList
            }
            if let actionError {
                Divider()
                Label(actionError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
        .sheet(item: $indexEditorTarget) { target in
            IndexEditorSheet(
                target: target,
                availableColumns: (inspector.currentColumnDefinitions() ?? []).map(\.name),
                existingNames: Set((inspector.currentIndexDefinitions() ?? []).map(\.name)),
                canEdit: canEdit,
                onCommit: { result in
                    Task { await applyIndexResult(result) }
                }
            )
        }
        .confirmationDialog(
            deleteIndexCandidate.map { "删除索引「\($0.name)」？" } ?? "",
            isPresented: Binding(
                get: { deleteIndexCandidate != nil },
                set: { if !$0 { deleteIndexCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteIndexCandidate
        ) { idx in
            Button("删除", role: .destructive) {
                Task { await runDropIndex(idx.name) }
            }
            Button("取消", role: .cancel) { deleteIndexCandidate = nil }
        } message: { idx in
            Text("ALTER TABLE DROP INDEX \(idx.name)，加回去要重建。")
        }
        .sheet(item: $editorTarget) { target in
            ColumnEditorSheet(
                target: target,
                existingNames: existingColumnNames,
                canEdit: canEdit,
                onCommit: { result in
                    Task { await applyEditorResult(result, target: target) }
                }
            )
        }
        .confirmationDialog(
            deleteCandidate.map { "删除字段「\($0.name)」？" } ?? "",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteCandidate
        ) { col in
            Button("删除", role: .destructive) {
                Task { await runDrop(name: col.name) }
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        } message: { col in
            Text("会执行 ALTER TABLE DROP COLUMN \(col.name)，数据会丢，无法撤销。")
        }
        .task {
            if columns == nil {
                await inspector.loadColumnDefinitions()
            }
            if inspector.currentIndexDefinitions() == nil {
                await inspector.loadIndexDefinitions()
            }
        }
    }

    private var subTabBar: some View {
        HStack(spacing: 4) {
            ForEach(StructureSubTab.allCases, id: \.self) { tab in
                Button {
                    subTab = tab
                } label: {
                    Text(tab.title)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            subTab == tab ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    subTab == tab ? Color.accentColor.opacity(0.5) : .clear,
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    // MARK: - 索引子页

    private var indexes: [IndexDefinition]? {
        inspector.currentIndexDefinitions()
    }

    private var indexToolbar: some View {
        HStack {
            Text("\(indexes?.count ?? 0) 个索引")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if actionRunning {
                ProgressView().controlSize(.small)
            }
            Button {
                indexEditorTarget = .add
            } label: {
                Label("添加索引", systemImage: "plus")
            }
            .disabled(!canEdit || actionRunning || (inspector.currentColumnDefinitions() ?? []).isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var indexList: some View {
        if let idxs = indexes {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    indexHeaderRow
                    Divider()
                    if idxs.isEmpty {
                        Text("暂无索引")
                            .font(.caption).foregroundStyle(.tertiary)
                            .padding(20)
                    }
                    ForEach(idxs) { idx in
                        indexRow(idx)
                        Divider().opacity(0.3)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var indexHeaderRow: some View {
        HStack(spacing: 0) {
            cell("名称", weight: .semibold).frame(width: 200, alignment: .leading)
            cell("类型", weight: .semibold).frame(width: 100, alignment: .leading)
            cell("方法", weight: .semibold).frame(width: 80, alignment: .leading)
            cell("字段", weight: .semibold).frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 40)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func indexRow(_ idx: IndexDefinition) -> some View {
        HStack(spacing: 0) {
            cell(idx.name).frame(width: 200, alignment: .leading)
                .help(idx.name)
            HStack(spacing: 4) {
                Text(idx.category.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(idx.category == .primary ? Color.accentColor : Color.primary)
            }.frame(width: 100, alignment: .leading)
            cell(idx.method ?? "—").frame(width: 80, alignment: .leading)
            cell(idx.columns.joined(separator: ", "))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(role: .destructive) {
                deleteIndexCandidate = idx
            } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .disabled(!canEdit || actionRunning)
            .frame(width: 40)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: - 字段子页

    private var toolbar: some View {
        HStack {
            Text("\(columns?.count ?? 0) 个字段")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if actionRunning {
                ProgressView().controlSize(.small)
            }
            Button {
                editorTarget = .add(after: columns?.last?.name)
            } label: {
                Label("添加字段", systemImage: "plus")
            }
            .disabled(!canEdit || actionRunning)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var list: some View {
        if let columns {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    headerRow
                    Divider()
                    ForEach(columns) { col in
                        columnRow(col)
                        Divider().opacity(0.3)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            cell("字段", weight: .semibold).frame(width: 180, alignment: .leading)
            cell("类型", weight: .semibold).frame(width: 200, alignment: .leading)
            cell("可空", weight: .semibold).frame(width: 50, alignment: .center)
            cell("默认", weight: .semibold).frame(width: 140, alignment: .leading)
            cell("PK", weight: .semibold).frame(width: 36, alignment: .center)
            cell("自增", weight: .semibold).frame(width: 50, alignment: .center)
            cell("注释", weight: .semibold).frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 70)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func columnRow(_ col: ColumnDefinition) -> some View {
        HStack(spacing: 0) {
            cell(col.name).frame(width: 180, alignment: .leading)
                .help(col.name)
            cell(col.dataType).frame(width: 200, alignment: .leading)
                .help(col.dataType)
            cell(col.nullable ? "Yes" : "No").frame(width: 50, alignment: .center)
                .foregroundStyle(col.nullable ? .secondary : .primary)
            cell(col.defaultValue ?? "—").frame(width: 140, alignment: .leading)
                .foregroundStyle(col.defaultValue == nil ? .tertiary : .primary)
            cell(col.isPrimaryKey ? "✓" : "").frame(width: 36, alignment: .center)
                .foregroundStyle(.tint)
            cell(col.isAutoIncrement ? "✓" : "").frame(width: 50, alignment: .center)
                .foregroundStyle(.tint)
            cell(col.comment ?? "").frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Button {
                    editorTarget = .modify(original: col)
                } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .disabled(!canEdit || actionRunning)
                Button(role: .destructive) {
                    deleteCandidate = col
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(!canEdit || actionRunning)
            }
            .frame(width: 70)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func cell(_ text: String, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(.system(size: 14, design: .monospaced).weight(weight))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var columns: [ColumnDefinition]? {
        inspector.currentColumnDefinitions()
    }

    private var existingColumnNames: Set<String> {
        Set((columns ?? []).map(\.name))
    }

    // MARK: - 操作

    private func applyEditorResult(_ result: ColumnEditorResult, target: ColumnEditorTarget) async {
        actionError = nil
        actionRunning = true
        defer { actionRunning = false }
        do {
            switch target {
            case .add:
                try await inspector.addColumn(result.column, after: result.after)
            case .modify(let original):
                try await inspector.modifyColumn(oldName: original.name, column: result.column)
            }
            editorTarget = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func runDrop(name: String) async {
        actionError = nil
        actionRunning = true
        defer { actionRunning = false }
        do {
            try await inspector.dropColumn(name)
            deleteCandidate = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func applyIndexResult(_ result: IndexEditorResult) async {
        actionError = nil
        actionRunning = true
        defer { actionRunning = false }
        do {
            try await inspector.addIndex(result.index)
            indexEditorTarget = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func runDropIndex(_ name: String) async {
        actionError = nil
        actionRunning = true
        defer { actionRunning = false }
        do {
            try await inspector.dropIndex(name)
            deleteIndexCandidate = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}
