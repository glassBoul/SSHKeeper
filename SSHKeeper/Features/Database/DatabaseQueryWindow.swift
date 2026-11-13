import SwiftUI
import AppKit
import SSHKeeperCore

/// 单个 DB session 的主视图。由 DatabaseWorkspaceView 在 tab 切换时按 active session 渲染。
struct DatabaseQueryView: View {
    @Bindable var session: DatabaseSession

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            HSplitView {
                tableSidebar
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 360, maxHeight: .infinity)
                rightPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("\(session.database.kind.displayName) · \(session.database.name)")
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            if !session.availableDatabases.isEmpty {
                Picker("数据库", selection: Binding(
                    get: { session.currentDatabase },
                    set: { newValue in
                        Task { await session.switchDatabase(newValue) }
                    }
                )) {
                    ForEach(session.availableDatabases, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            Spacer()
            modeIndicator
            connectionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var modeIndicator: some View {
        HStack(spacing: 6) {
            Button {
                session.inspector.deselectTable()
            } label: {
                Label("SQL", systemImage: "text.alignleft")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        session.inspector.selectedTable == nil ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            if let table = session.inspector.selectedTable {
                Image(systemName: "chevron.right").font(.callout).foregroundStyle(.tertiary)
                Text(table.name)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch session.status {
        case .connected:
            Button("断开") { Task { await session.disconnect() } }
        case .disconnected:
            Button("连接") { Task { await session.connect() } }
                .buttonStyle(.borderedProminent)
        case .error:
            Button("重连") { Task { await session.connect() } }
                .buttonStyle(.borderedProminent)
        case .connecting:
            ProgressView().controlSize(.small)
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .disconnected: .gray
        case .connecting: .yellow
        case .connected: .green
        case .error: .red
        }
    }

    private var statusText: String {
        switch session.status {
        case .disconnected: "未连接"
        case .connecting: "连接中…"
        case .connected: "已连接 · \(session.database.username)@\(session.database.host)"
        case .error(let msg): msg
        }
    }

    @ViewBuilder
    private var tableSidebar: some View {
        TableSidebar(session: session)
    }

    @ViewBuilder
    private var rightPane: some View {
        if session.inspector.selectedTable != nil {
            TableInspectorPane(session: session)
        } else {
            sqlPane
        }
    }

    private var sqlPane: some View {
        VStack(spacing: 0) {
            sqlTabBar
            Divider()
            VSplitView {
                queryEditor
                    .frame(minHeight: 120, idealHeight: 220)
                resultArea
                    .frame(minHeight: 180)
            }
        }
    }

    private var sqlTabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(session.sqlTabs) { tab in
                        SQLTabChip(
                            tab: tab,
                            isActive: tab.id == session.activeSQLTabID,
                            canClose: session.sqlTabs.count > 1,
                            onSelect: { session.setActiveSQLTab(tab.id) },
                            onClose: { session.closeSQLTab(tab.id) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
            Button {
                session.newSQLTab()
            } label: {
                Image(systemName: "plus").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("新建 SQL 标签 (⌘T)")
            .keyboardShortcut("t", modifiers: .command)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(.regularMaterial)
    }

    private var queryEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.activeSQLTab?.title ?? "SQL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if hasSelection {
                    Text("\(selectionLineCount) 行选中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if activeIsRunning {
                    Button("取消") {
                        Task { await session.cancelActiveQuery() }
                    }
                    .buttonStyle(.bordered)
                    .help("断开连接以中止当前查询，然后立即重连")
                } else {
                    Button {
                        Task { await session.runExplain() }
                    } label: {
                        Label("EXPLAIN", systemImage: "sparkles.rectangle.stack")
                            .labelStyle(.titleOnly)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isConnected)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .help("在当前 SQL 前加 EXPLAIN 跑一次（⇧⌘E）— 仅看执行计划，不执行原查询")

                    Button(hasSelection ? "运行选区" : "运行") {
                        Task { await session.runActiveQuery() }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isConnected)
                    .help(hasSelection ? "只跑选中的 SQL（⌘↵）" : "跑整个标签的 SQL（⌘↵）")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            SQLEditor(
                text: Binding(
                    get: { session.activeQueryText },
                    set: { session.activeQueryText = $0 }
                ),
                selectedText: Binding(
                    get: { session.activeSelectedSQL },
                    set: { session.activeSelectedSQL = $0 }
                ),
                completionProvider: { [weak session] prefix, contextBefore in
                    session?.completions(prefix: prefix, contextBefore: contextBefore) ?? []
                }
            )
        }
    }

    private var resultArea: some View {
        VStack(spacing: 0) {
            HStack {
                if let result = session.activeSQLTab?.lastResult {
                    Text("\(result.rows.count) 行 · \(String(format: "%.2f", result.executionTime * 1000)) ms")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let err = session.activeSQLTab?.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("⌘↵ 执行 SQL").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if activeIsRunning {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            if let result = session.activeSQLTab?.lastResult, !result.columns.isEmpty {
                ResultGrid(result: result)
            } else {
                ContentUnavailableView(
                    "无结果",
                    systemImage: "tablecells.badge.ellipsis"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var activeIsRunning: Bool {
        session.activeSQLTab?.isRunning ?? false
    }

    private var isConnected: Bool {
        if case .connected = session.status { return true }
        return false
    }

    private var hasSelection: Bool {
        !session.activeSelectedSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectionLineCount: Int {
        session.activeSelectedSQL.split(whereSeparator: { $0.isNewline }).count
    }
}

private struct SQLTabChip: View {
    let tab: SQLTab
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.isRunning {
                ProgressView().controlSize(.mini)
            } else if tab.lastError != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption2)
            } else if tab.lastResult != nil {
                Circle().fill(Color.green).frame(width: 6, height: 6)
            } else {
                Circle().fill(Color.gray.opacity(0.4)).frame(width: 6, height: 6)
            }
            Text(tab.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220)
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .opacity(hovering || isActive ? 0.9 : 0.3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isActive ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isActive ? Color.accentColor.opacity(0.5) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}
