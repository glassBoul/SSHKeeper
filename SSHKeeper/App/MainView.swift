import SwiftUI
import SSHKeeperCore

struct MainView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionEngine.self) private var engine
    @Environment(SidecarController.self) private var sidecar
    @Environment(UploadCoordinator.self) private var uploadCoordinator
    @Environment(UpdateCoordinator.self) private var updateCoordinator

    @State private var selection: String?
    @State private var lastSeenFlushError: String?
    @State private var searchText: String = ""
    @State private var editorTarget: HostEditorTarget?
    @State private var showingGroupEditor = false
    @State private var includeConsent: IncludeBootstrap?
    @State private var showingKeyManager = false
    @State private var showingPanelManager = false
    @State private var showingDatabaseManager = false
    @State private var bannerMessage: BannerMessage?

    var body: some View {
        @Bindable var engineBinding = engine
        return NavigationSplitView {
            HostListSidebar(
                selection: $selection,
                searchText: $searchText,
                onAddHost: { editorTarget = .new },
                onAddGroup: { showingGroupEditor = true }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            detailContent(engine: engineBinding)
        }
        .sheet(item: $editorTarget) { target in
            HostEditorView(editing: target.host)
                .environment(store)
        }
        .sheet(isPresented: $showingGroupEditor) {
            GroupEditorView()
                .environment(store)
        }
        .sheet(item: $includeConsent) { bootstrap in
            IncludeConsentSheet(bootstrap: bootstrap) { result in
                includeConsent = nil
                handleConsentResult(result)
            }
        }
        .sheet(isPresented: $showingKeyManager) {
            KeyManagementSheet()
        }
        .sheet(isPresented: $showingPanelManager) {
            PanelManagerSheet()
        }
        .sheet(isPresented: $showingDatabaseManager) {
            DatabaseManagerSheet()
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingDatabaseManager = true
                } label: {
                    Label("数据库", systemImage: "cylinder.split.1x2")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingPanelManager = true
                } label: {
                    Label("面板", systemImage: "rectangle.on.rectangle.angled")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingKeyManager = true
                } label: {
                    Label("密钥", systemImage: "key.horizontal")
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .secondaryAction) {
                TransferToolbarButton()
            }
        }
        .sheet(item: Binding(
            get: { uploadCoordinator.pendingPrompt },
            set: { newValue in
                if newValue == nil { uploadCoordinator.cancelPendingPrompt() }
            }
        )) { prompt in
            UploadDestinationSheet(
                alias: prompt.alias,
                items: prompt.items,
                remoteDir: Binding(
                    get: { uploadCoordinator.pendingPrompt?.remoteDir ?? prompt.remoteDir },
                    set: { newValue in
                        if var p = uploadCoordinator.pendingPrompt {
                            p.remoteDir = newValue
                            uploadCoordinator.pendingPrompt = p
                        }
                    }
                ),
                onSubmit: { uploadCoordinator.submitPendingPrompt() },
                onCancel: { uploadCoordinator.cancelPendingPrompt() }
            )
        }
        .sheet(isPresented: Binding(
            get: { updateCoordinator.presentation != .hidden },
            set: { newValue in
                if !newValue { updateCoordinator.dismiss() }
            }
        )) {
            UpdateSheet(
                presentation: updateCoordinator.presentation,
                onDownload: { updateCoordinator.download() },
                onSkip: { updateCoordinator.skipThisVersion() },
                onDismiss: { updateCoordinator.dismiss() }
            )
        }
        .alert(item: $bannerMessage) { message in
            Alert(title: Text(message.title), message: Text(message.body), dismissButton: .default(Text("好")))
        }
        .task { performStartupChecks() }
        .onChange(of: sidecar.lastFlushError) { _, newValue in
            // 元数据落盘失败时弹一次提示，避免静默丢数据；连续相同错误不重复打扰。
            guard let error = newValue, error != lastSeenFlushError else { return }
            lastSeenFlushError = error
            bannerMessage = BannerMessage(title: "元数据保存失败", body: error)
        }
    }

    @ViewBuilder
    private func detailContent(engine: SessionEngine) -> some View {
        if !engine.sessions.isEmpty {
            TabbedSessionContainer(engine: engine)
                .toolbar {
                    if let alias = selection,
                       let host = store.hosts.first(where: { $0.alias == alias }) {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                handleConnect(host)
                            } label: {
                                Label("新会话: \(host.alias)", systemImage: "plus.rectangle.on.rectangle")
                            }
                        }
                    }
                }
        } else if let alias = selection,
                  let host = store.hosts.first(where: { $0.alias == alias }) {
            HostDetailView(
                host: host,
                onEdit: { editorTarget = .edit(host) },
                onDelete: { handleDelete(host) },
                onConnect: { handleConnect(host) }
            )
            .id(host.alias)
        } else {
            ContentUnavailableView(
                "选择主机",
                systemImage: "rectangle.stack",
                description: Text("从左侧选择主机查看详情，或添加新主机。")
            )
        }
    }

    private func performStartupChecks() {
        let bootstrap = IncludeBootstrap()
        if !bootstrap.isAlreadyIncluded() {
            includeConsent = bootstrap
        }
        // metadata.json 启动时读失败不会触发 onChange（值在 init 阶段已设入），
        // 这里同步检查一次。
        if let error = sidecar.lastFlushError, error != lastSeenFlushError {
            lastSeenFlushError = error
            bannerMessage = BannerMessage(title: "元数据加载失败", body: error)
            return
        }
        // import notice：仅 ~/.ssh/config 含 Match 块时出现一次，让用户知情。
        // 优先级低于错误提示；仅在 sidecar 没有 error 时展示，避免覆盖更紧急的 banner。
        if let notice = store.importNotice, bannerMessage == nil {
            bannerMessage = BannerMessage(title: "部分配置未导入", body: notice)
        }
    }

    private func handleConsentResult(_ result: Result<URL?, Error>) {
        switch result {
        case .success(let backup):
            store.load()
            if let backup {
                bannerMessage = BannerMessage(
                    title: "已接管 ~/.ssh/config",
                    body: "原文件备份到：\n\(backup.path)"
                )
            }
        case .failure(let error):
            bannerMessage = BannerMessage(
                title: "无法修改 ~/.ssh/config",
                body: error.localizedDescription
            )
        }
    }

    private func handleDelete(_ host: SSHHost) {
        do {
            try store.remove(alias: host.alias)
            try? PasswordKeychain.delete(alias: host.alias)
            if selection == host.alias { selection = nil }
        } catch {
            bannerMessage = BannerMessage(
                title: "删除失败",
                body: error.localizedDescription
            )
        }
    }

    private func handleConnect(_ host: SSHHost) {
        try? store.touch(alias: host.alias)
        engine.openSession(alias: host.alias)
    }
}

private struct BannerMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

struct HostEditorTarget: Identifiable {
    let id: String
    let host: SSHHost?

    static let new = HostEditorTarget(id: "__new__", host: nil)

    static func edit(_ host: SSHHost) -> HostEditorTarget {
        HostEditorTarget(id: host.alias, host: host)
    }
}
