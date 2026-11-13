import Foundation
import Observation

public enum HostStoreError: Error {
    /// conf 已写但 metadata 落盘失败 —— 此前已尝试把 conf 回滚到调用前内容。
    /// 关联值是 metadata 失败的 underlying 描述。
    case transactionFailed(String)

    public var localizedDescription: String {
        switch self {
        case .transactionFailed(let reason):
            return "保存失败：\(reason)"
        }
    }
}

@Observable
@MainActor
public final class HostStore {
    public private(set) var hosts: [SSHHost] = []
    public private(set) var groups: [HostGroup] = []
    public private(set) var lastError: String?
    /// load() 时收集到的、需要展示给用户的一次性提示。
    /// 当前唯一来源：~/.ssh/config 里被跳过的 Match 块 —— 用户应当知道这部分配置没被导入。
    public private(set) var importNotice: String?

    private let userConfigURL: URL
    private let managedConfigURL: URL
    private let sidecar: SidecarController

    public init(
        userConfigURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config"),
        managedConfigURL: URL = ConfigBridge.defaultLocation(),
        sidecar: SidecarController
    ) {
        self.userConfigURL = userConfigURL
        self.managedConfigURL = managedConfigURL
        self.sidecar = sidecar
    }

    public func load() {
        let importedResult = loadParsed(from: userConfigURL, source: .imported)
        let managedResult = loadParsed(from: managedConfigURL, source: .appManaged)
        let merged = mergeBySourcePreference(
            imported: importedResult.hosts,
            managed: managedResult.hosts
        )
        self.groups = sidecar.payload.groups
        self.hosts = applyMetadata(merged, metadata: sidecar.payload.hostMetadata)
        self.lastError = nil

        // 只关心用户原 config 里跳过的 Match 块；App 自己写的 sshkeeper.conf 永远没有 Match。
        let skippedCount = importedResult.skippedMatches.count
        self.importNotice = skippedCount > 0
            ? "~/.ssh/config 里有 \(skippedCount) 个 Match 块未导入（条件配置暂不支持）。命令行 ssh 仍按原配置工作，仅 App 列表里看不到对应主机。"
            : nil
    }

    public func upsert(_ host: SSHHost) throws {
        try transactionalHostsMutation { hosts in
            if let index = hosts.firstIndex(where: { $0.alias == host.alias }) {
                hosts[index] = host
            } else {
                hosts.append(host)
            }
        }
    }

    public func remove(alias: String) throws {
        try transactionalHostsMutation { hosts in
            hosts.removeAll { $0.alias == alias }
        }
    }

    public func touch(alias: String, at date: Date = Date()) throws {
        // 频繁调用，走异步 debounce 路径；落盘失败由 sidecar.lastFlushError → UI banner 暴露。
        // 不事务化的代价是极端情况下 lastUsedAt 可能比磁盘领先 150ms，可接受。
        guard let index = hosts.firstIndex(where: { $0.alias == alias }) else { return }
        hosts[index].lastUsedAt = date
        scheduleSidecarFlush()
    }

    public func upsertGroup(_ group: HostGroup) throws {
        try transactionalSidecarMutation {
            if let index = groups.firstIndex(where: { $0.id == group.id }) {
                groups[index] = group
            } else {
                groups.append(group)
            }
        }
    }

    public func removeGroup(id: UUID) throws {
        try transactionalSidecarMutation {
            groups.removeAll { $0.id == id }
            for index in hosts.indices where hosts[index].groupID == id {
                hosts[index].groupID = nil
            }
        }
    }

    /// 完整事务：写 ssh-config + 同步落盘 metadata，原子化。
    /// 失败时把 conf 回滚到调用前的内容（包括"原本不存在则删除"），
    /// 但 hosts/groups 内存的回滚交给上层调用方（见 transactionalHostsMutation）。
    public func persist() throws {
        let bridge = ConfigBridge(fileURL: managedConfigURL)
        let preChangeContents = bridge.currentContents()
        try bridge.write(hosts: hosts)
        do {
            try flushSidecarTransactionally()
        } catch {
            // metadata 失败 → 把 conf 也退回去，避免"看见 conf 改了但元数据没改"的不一致。
            try? bridge.restore(contents: preChangeContents)
            throw HostStoreError.transactionFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func transactionalHostsMutation(
        _ block: (inout [SSHHost]) -> Void
    ) throws {
        let hostsBackup = hosts
        let groupsBackup = groups
        block(&hosts)
        do {
            try persist()
        } catch {
            hosts = hostsBackup
            groups = groupsBackup
            throw error
        }
    }

    private func transactionalSidecarMutation(
        _ block: () -> Void
    ) throws {
        let hostsBackup = hosts
        let groupsBackup = groups
        block()
        do {
            try flushSidecarTransactionally()
        } catch {
            hosts = hostsBackup
            groups = groupsBackup
            throw HostStoreError.transactionFailed(error.localizedDescription)
        }
    }

    private func flushSidecarTransactionally() throws {
        let metadata = buildMetadata()
        let groupsCopy = groups
        try sidecar.mutateAndFlush { payload in
            payload.schemaVersion = 3
            payload.groups = groupsCopy
            payload.hostMetadata = metadata
        }
    }

    private func scheduleSidecarFlush() {
        let metadata = buildMetadata()
        let groupsCopy = groups
        sidecar.mutate { payload in
            payload.schemaVersion = 3
            payload.groups = groupsCopy
            payload.hostMetadata = metadata
        }
    }

    private func buildMetadata() -> [String: HostMetadata] {
        var metadata: [String: HostMetadata] = [:]
        for host in hosts {
            metadata[host.alias] = HostMetadata(
                groupID: host.groupID,
                tags: host.tags,
                colorHex: host.colorHex,
                lastUsedAt: host.lastUsedAt
            )
        }
        return metadata
    }

    private struct ParsedSource {
        let hosts: [SSHHost]
        let skippedMatches: [SkippedMatchBlock]
    }

    private func loadParsed(from url: URL, source: HostSource) -> ParsedSource {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ParsedSource(hosts: [], skippedMatches: [])
        }
        do {
            let parsed = try ConfigParser.parse(fileURL: url)
            let hosts = parsed.hosts.map { host -> SSHHost in
                var copy = host
                copy.source = source
                return copy
            }
            return ParsedSource(hosts: hosts, skippedMatches: parsed.skippedMatchBlocks)
        } catch {
            return ParsedSource(hosts: [], skippedMatches: [])
        }
    }

    private func mergeBySourcePreference(imported: [SSHHost], managed: [SSHHost]) -> [SSHHost] {
        // App-managed takes precedence when an alias appears in both files.
        var byAlias: [String: SSHHost] = [:]
        for host in imported { byAlias[host.alias] = host }
        for host in managed { byAlias[host.alias] = host }
        return byAlias.values.sorted { $0.alias < $1.alias }
    }

    private func applyMetadata(
        _ hosts: [SSHHost],
        metadata: [String: HostMetadata]
    ) -> [SSHHost] {
        hosts.map { host in
            guard let meta = metadata[host.alias] else { return host }
            var copy = host
            copy.groupID = meta.groupID
            copy.tags = meta.tags
            copy.colorHex = meta.colorHex
            copy.lastUsedAt = meta.lastUsedAt
            return copy
        }
    }
}
