import SwiftUI
import SSHKeeperCore

struct PanelManagerSheet: View {
    @Environment(PanelStore.self) private var store
    @Environment(PanelWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var editorTarget: PanelEditorTarget?
    @State private var deleteCandidate: Panel?
    @State private var openError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle("面板")
        .sheet(item: $editorTarget) { target in
            PanelEditorView(editing: target.panel)
        }
        .confirmationDialog(
            deleteCandidate.map { "删除面板「\($0.name)」？" } ?? "",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteCandidate
        ) { panel in
            Button("删除", role: .destructive) {
                try? store.remove(id: panel.id)
                try? PasswordKeychain.delete(alias: "panel:\(panel.id.uuidString)")
                deleteCandidate = nil
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        } message: { _ in
            Text("将同时清除存在 Keychain 的密码。")
        }
        .alert(
            "无法打开",
            isPresented: Binding(
                get: { openError != nil },
                set: { if !$0 { openError = nil } }
            ),
            presenting: openError
        ) { _ in
            Button("好") { openError = nil }
        } message: { msg in
            Text(msg).textSelection(.enabled)
        }
    }

    private var header: some View {
        HStack {
            Text("已保存的面板")
                .font(.headline)
            Spacer()
            Button("刷新", systemImage: "arrow.clockwise") { store.load() }
                .labelStyle(.iconOnly)
            Button("新建面板") {
                editorTarget = .new
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.panels.isEmpty {
                    ContentUnavailableView(
                        "尚未添加面板",
                        systemImage: "rectangle.on.rectangle.angled",
                        description: Text("点击「新建面板」添加宝塔 / 1Panel 等管理后台。")
                    )
                    .padding(.vertical, 32)
                }
                ForEach(store.panels.sorted(by: { $0.name < $1.name })) { panel in
                    panelRow(panel)
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func panelRow(_ panel: Panel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(panel.name).font(.body.weight(.medium))
                    Text(panel.kind.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if PasswordKeychain.has(alias: "panel:\(panel.id.uuidString)") {
                        Label("已存密码", systemImage: "lock.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("缺密码", systemImage: "lock.slash")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(panel.username) @ \(panel.url)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date = panel.lastUsedAt {
                    Text("最近登录：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                do {
                    try workspace.open(panelID: panel.id)
                    openWindow(id: "panel-workspace")
                } catch {
                    openError = error.localizedDescription
                }
            } label: {
                Label("登录", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!PasswordKeychain.has(alias: "panel:\(panel.id.uuidString)"))
            Menu {
                Button("编辑") { editorTarget = .edit(panel) }
                Button("复制 URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(panel.url, forType: .string)
                }
                Divider()
                Button("删除", role: .destructive) { deleteCandidate = panel }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 36)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Text("\(store.panels.count) 个面板")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }
}

struct PanelEditorTarget: Identifiable {
    let id: String
    let panel: Panel?

    static let new = PanelEditorTarget(id: "__new__", panel: nil)

    static func edit(_ panel: Panel) -> PanelEditorTarget {
        PanelEditorTarget(id: panel.id.uuidString, panel: panel)
    }
}
