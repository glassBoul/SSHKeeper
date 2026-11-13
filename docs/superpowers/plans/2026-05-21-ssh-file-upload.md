# SSH File Upload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 SSHKeeper 加 SSH 文件上传：拖拽文件到终端 / ⌘⇧U 选文件 → 弹路径对话框 → 调 `/usr/bin/scp` 子进程（复用现有 SSH_ASKPASS + Keychain 通道）→ 顶部工具栏 popover 显进度 / 取消 / 重试。

**Architecture:** 完全复用现有"包系统 ssh 二进制 + askpass + alias"路径，零新依赖。新增 `Features/Transfer/` 一族文件：`TransferTask`（模型）+ `ScpProcess`（Process 包装）+ `TransferEngine`（@MainActor 串行队列）+ `UploadCoordinator`（三入口收口）+ 3 个 SwiftUI View（路径 sheet / 工具栏按钮 / popover 面板）+ `UploadCommands`（⌘⇧U）。`SSHTerminalView` 套一层 wrapper NSView 接 `NSDraggingDestination`。

**Tech Stack:** Swift 6（strict concurrency）、SwiftUI macOS 14、AppKit (NSView/NSWindow/NSOpenPanel/NSPasteboard)、Foundation Process。无新 Swift 包依赖。

**Repository note:** 当前工作目录非 git 仓库；不做 `git commit`。每个 Task 末尾用 `xcodebuild build` 成功作为里程碑。

**Reference spec:** `docs/superpowers/specs/2026-05-20-ssh-file-upload-design.md`

**Testing note:** 与行内编辑 plan 一致，SSHKeeperTests 现只挂 SSHKeeperCore；Transfer 代码全在 App target 且大量涉及 SwiftUI / NSView，难写单测。本 plan 全靠"编译通过 + 手动验证清单"作里程碑。

**Build/Verify 模板：**

```bash
cd .
xcodegen generate >/dev/null
xcodebuild build \
  -project SSHKeeper.xcodeproj \
  -scheme SSHKeeper \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -quiet
```

Expected：exit 0（`** BUILD SUCCEEDED **`，`-quiet` 不打这行 banner）。

---

## File Structure（新增 / 修改一览）

**新增**（全部在 `SSHKeeper/Features/Transfer/`）：

| 文件 | 职责 |
|---|---|
| `TransferTask.swift` | `TransferTask` struct + `TransferStatus` enum |
| `ScpProcess.swift` | 包 `Process`：构造 scp argv、注入 askpass env、`start` / `cancel`、stderr 收集 |
| `TransferEngine.swift` | `@Observable @MainActor` 单例风格类；持有 `[TransferTask]`，串行 runLoop，公开 `enqueue / cancel / retry / remove / clearCompleted` |
| `UploadCoordinator.swift` | `@Observable @MainActor`，把"拖拽 / ⌘⇧U / 路径对话框"粘到 `TransferEngine` |
| `UploadDestinationSheet.swift` | SwiftUI sheet 输入远端路径 |
| `UploadDestinationMemory.swift` | UserDefaults 按 alias 记忆最近一次远端目录 |
| `TransferPanelView.swift` | popover 内容（进行中 / 已完成 / 失败列表 + 按钮） |
| `TransferToolbarButton.swift` | 工具栏按钮：图标 + badge + 微进度条 + popover host |
| `UploadCommands.swift` | `Commands` struct，绑 ⌘⇧U |

**修改：**

| 文件 | 改动 |
|---|---|
| `SSHKeeper/Features/Sessions/SSHTerminalView.swift` | 加 wrapper NSView 套住 `LocalProcessTerminalView`，wrapper 实现 `NSDraggingDestination`；新增 `onDrop` 回调 param |
| `SSHKeeper/Features/Sessions/TabbedSessionContainer.swift` | 把 `onDrop` 接到 `UploadCoordinator.beginUpload(alias:, items:)` |
| `SSHKeeper/App/MainView.swift` | toolbar 加 `TransferToolbarButton`；注入 `TransferEngine` / `UploadCoordinator` 到 environment |
| `SSHKeeper/App/SSHKeeperApp.swift` | 构造 `transferEngine` / `uploadCoordinator` 注入 environment + focusedSceneValue；`.commands { UploadCommands() }` |

**不动：** `SSHKeeperCore/*`（scp 子进程留 App 层；未来要复用再下沉）。

---

### Task 1: `TransferTask` + `TransferStatus` 数据模型

**Files:**
- Create: `SSHKeeper/Features/Transfer/TransferTask.swift`

- [ ] **Step 1: 创建目录 + 文件**

```bash
mkdir -p ./SSHKeeper/Features/Transfer
```

Create `SSHKeeper/Features/Transfer/TransferTask.swift`:

```swift
import Foundation

/// 单个传输任务的状态。
enum TransferStatus: Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed       // 详情在 task.failureMessage
    case cancelled

    var isRunning: Bool { self == .running }
    var isTerminal: Bool {
        self == .succeeded || self == .failed || self == .cancelled
    }
}

/// 一次"上传操作"对应一个 TransferTask：用户一次拖拽 / 一次 ⌘⇧U 选文件 = 一个 task。
/// task 内部按 `localItems` 顺序串行调 scp，每个 item 完成后增加 transferredBytes。
struct TransferTask: Identifiable, Equatable, Sendable {
    let id: UUID
    let alias: String
    /// 用户提交的所有本地项（含文件和顶层目录；目录由 scp -r 递归）。
    let localItems: [URL]
    let remoteDir: String
    /// enqueue 时算出来的预算（含目录递归 stat）。
    let totalBytes: Int64
    /// 当前已传字节（== 已完成 item 的 size 累加）。
    var transferredBytes: Int64
    /// 正在传的具体 item；nil = 还没开始 / 已结束。
    var currentItem: URL?
    var status: TransferStatus
    let createdAt: Date
    var endedAt: Date?
    /// 失败时 scp 的 stderr 末 N 行。
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        alias: String,
        localItems: [URL],
        remoteDir: String,
        totalBytes: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.alias = alias
        self.localItems = localItems
        self.remoteDir = remoteDir
        self.totalBytes = totalBytes
        self.transferredBytes = 0
        self.currentItem = nil
        self.status = .pending
        self.createdAt = createdAt
        self.endedAt = nil
        self.failureMessage = nil
    }

    /// scp 失败时把原始 stderr 翻译成更人话的中文摘要；其他情况返回原文。
    var localizedFailureMessage: String? {
        guard let raw = failureMessage else { return nil }
        if raw.contains("Host key verification failed") {
            return "主机密钥校验失败（known_hosts 未信任）。请先用终端 ssh 一次接受指纹。"
        }
        if raw.contains("Permission denied") {
            return "权限拒绝。检查密码、密钥或目标目录写权限。"
        }
        if raw.contains("No such file or directory") {
            return "远端目录不存在：\(remoteDir)"
        }
        if raw.contains("Connection refused") || raw.contains("Connection timed out") {
            return "连接被拒 / 超时。检查主机是否可达。"
        }
        return raw
    }
}
```

- [ ] **Step 2: 验证编译**

Run Build 模板。

Expected: BUILD SUCCEEDED（文件还未被引用，会有 "never used" 警告？struct/enum 不会警告，OK）。

---

### Task 2: `UploadDestinationMemory` — 按 alias 记忆远端目录

**Files:**
- Create: `SSHKeeper/Features/Transfer/UploadDestinationMemory.swift`

- [ ] **Step 1: 创建文件**

Create `SSHKeeper/Features/Transfer/UploadDestinationMemory.swift`:

```swift
import Foundation

/// 按 SSH alias 持久化最近一次的远端上传目录，写 UserDefaults。
/// 首次使用某 alias 返回 "~/"；用户提交上传后写回。
enum UploadDestinationMemory {
    /// UserDefaults key：版本后缀，方便未来 schema 演进。
    private static let storageKey = "uploadDestinationByAlias.v1"

    static func get(alias: String) -> String {
        let map = (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
        return map[alias] ?? "~/"
    }

    static func set(alias: String, path: String) {
        var map = (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
        map[alias] = path
        UserDefaults.standard.set(map, forKey: storageKey)
    }
}
```

- [ ] **Step 2: 验证编译**

Run Build 模板. Expected: BUILD SUCCEEDED.

---

### Task 3: `ScpProcess` — 包装 `/usr/bin/scp` 子进程

**Files:**
- Create: `SSHKeeper/Features/Transfer/ScpProcess.swift`

- [ ] **Step 1: 创建文件**

Create `SSHKeeper/Features/Transfer/ScpProcess.swift`:

```swift
import Foundation
import SSHKeeperCore

/// 单次 scp 子进程调用：一次只传一个 local item（文件或目录，目录靠 -r 递归）。
/// 不持有 UI 状态；由 TransferEngine 串行调度。
final class ScpProcess: @unchecked Sendable {
    /// 子进程异步结果。
    enum RunOutcome {
        case success
        case failure(message: String)
        case cancelled
    }

    private let process = Process()
    private let stderrPipe = Pipe()
    private var stderrBuffer = Data()
    private let stderrLock = NSLock()
    private var didCancel = false

    /// 启动 scp 进程，传完一个本地 item 后回调。
    /// 注意：调用线程会被 readabilityHandler 回调多次（任意线程）；onCompletion 也可能在任意线程。
    /// 调用方负责 hop 到 MainActor 更新 UI。
    func start(
        alias: String,
        localItem: URL,
        remoteDir: String,
        onCompletion: @escaping @Sendable (RunOutcome) -> Void
    ) {
        process.launchPath = "/usr/bin/scp"
        process.arguments = Self.makeArgs(localItem: localItem, alias: alias, remoteDir: remoteDir)

        let env = Self.makeEnvironment(alias: alias)
        process.environment = env

        process.standardError = stderrPipe
        process.standardOutput = Pipe()  // 吞掉 stdout

        // 持续读 stderr 累积，进程结束时一次性截取末 N 行
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.stderrLock.lock()
            self?.stderrBuffer.append(data)
            self?.stderrLock.unlock()
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            // 排空残余
            let remaining = self.stderrPipe.fileHandleForReading.availableData
            if !remaining.isEmpty {
                self.stderrLock.lock()
                self.stderrBuffer.append(remaining)
                self.stderrLock.unlock()
            }
            let outcome: RunOutcome
            if self.didCancel {
                outcome = .cancelled
            } else if proc.terminationStatus == 0 {
                outcome = .success
            } else {
                outcome = .failure(message: self.tailStderr(lines: 5))
            }
            onCompletion(outcome)
        }

        do {
            try process.run()
        } catch {
            onCompletion(.failure(message: error.localizedDescription))
        }
    }

    /// 用户取消：SIGTERM；terminationHandler 会带 cancelled outcome 回调。
    func cancel() {
        didCancel = true
        if process.isRunning {
            process.terminate()
        }
    }

    /// scp argv 构造。`--` 前后顺序：local（多个就只传一个，因为我们一次只调一个 item） + alias:remoteDir/
    static func makeArgs(localItem: URL, alias: String, remoteDir: String) -> [String] {
        return [
            "-r",
            "-p",
            "-O",
            "-q",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=15",
            "--",
            localItem.path,
            "\(alias):\(remoteDir)/"
        ]
    }

    /// 环境变量：仅当 Keychain 有该 alias 的密码时才注入 askpass env；
    /// 密钥认证不需要注入，让 ssh 走默认 ssh-agent / id 文件。
    static func makeEnvironment(alias: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if PasswordKeychain.has(alias: alias),
           let appExecutable = Bundle.main.executablePath {
            env["SSH_ASKPASS"] = appExecutable
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            env[AskpassMain.triggerEnvVar] = "1"
            env[AskpassMain.aliasEnvVar] = alias
        }
        return env
    }

    /// 取 stderr 末 N 行（按 \n 分），用作失败消息。
    private func tailStderr(lines: Int) -> String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        let text = String(data: stderrBuffer, encoding: .utf8) ?? ""
        let allLines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let suffix = allLines.suffix(lines)
        return suffix.joined(separator: "\n")
    }
}
```

- [ ] **Step 2: 验证编译**

Run Build 模板. Expected: BUILD SUCCEEDED. `AskpassMain` / `PasswordKeychain` 都来自 `SSHKeeperCore`（已 import）。

---

### Task 4: `TransferEngine` — 串行队列 + 状态机

**Files:**
- Create: `SSHKeeper/Features/Transfer/TransferEngine.swift`

- [ ] **Step 1: 创建文件**

Create `SSHKeeper/Features/Transfer/TransferEngine.swift`:

```swift
import Foundation
import Observation

/// 全局传输队列。串行跑：同时只有一个 task 处于 .running。
/// 每个 task 内部按 localItems 顺序串行 scp 一个 item。
@Observable
@MainActor
final class TransferEngine {
    /// 所有 task（pending / running / 已完成 / 失败 / 取消），按 createdAt 升序。
    private(set) var tasks: [TransferTask] = []

    /// 是否有 running task；UI 工具栏按钮的微进度条 / badge 用。
    var activeCount: Int { tasks.filter { $0.status.isRunning }.count }

    /// 进行中 task 的总进度 [0, 1]；用于工具栏按钮底部微进度条。
    /// 没有进行中任务时返回 nil。
    var aggregateProgress: Double? {
        let runners = tasks.filter { $0.status.isRunning }
        guard !runners.isEmpty else { return nil }
        let total = runners.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done = runners.reduce(Int64(0)) { $0 + $1.transferredBytes }
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    /// 当前正在跑的 task（如果有）。
    private var currentProcess: ScpProcess?

    /// 入队一次上传。立即返回，后台串行处理。
    /// items 已知道每个 size（由调用方在 enqueue 前 stat 算 totalBytes）。
    @discardableResult
    func enqueue(items: [URL], to alias: String, remoteDir: String, totalBytes: Int64) -> TransferTask {
        let task = TransferTask(
            alias: alias,
            localItems: items,
            remoteDir: remoteDir,
            totalBytes: totalBytes
        )
        tasks.append(task)
        kickRunLoop()
        return task
    }

    /// 取消一个 task：
    /// - pending → 直接转 cancelled
    /// - running → SIGTERM scp，currentProcess 的 terminationHandler 会拉回 cancelled
    /// - 已终态 → no-op
    func cancel(_ taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        switch tasks[idx].status {
        case .pending:
            tasks[idx].status = .cancelled
            tasks[idx].endedAt = Date()
        case .running:
            currentProcess?.cancel()
            // 状态由 runItem 的 outcome 回调写入
        case .succeeded, .failed, .cancelled:
            return
        }
    }

    /// 重试：把失败 / 取消的 task 重置为 pending，重新入串行队列。
    func retry(_ taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[idx].status == .failed || tasks[idx].status == .cancelled else { return }
        tasks[idx].status = .pending
        tasks[idx].transferredBytes = 0
        tasks[idx].currentItem = nil
        tasks[idx].endedAt = nil
        tasks[idx].failureMessage = nil
        kickRunLoop()
    }

    /// 删除一个终态 task。
    func remove(_ taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[idx].status.isTerminal else { return }
        tasks.remove(at: idx)
    }

    /// 清掉所有终态 task。
    func clearCompleted() {
        tasks.removeAll { $0.status.isTerminal }
    }

    // MARK: - 内部串行调度

    private func kickRunLoop() {
        // 已有 running task → 串行约束 → 不动
        if tasks.contains(where: { $0.status.isRunning }) { return }
        // 找下一个 pending
        guard let nextIdx = tasks.firstIndex(where: { $0.status == .pending }) else { return }
        tasks[nextIdx].status = .running
        let taskID = tasks[nextIdx].id
        // 启动第 0 个 item
        runItem(taskID: taskID, itemIdx: 0)
    }

    private func runItem(taskID: UUID, itemIdx: Int) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let task = tasks[idx]
        guard itemIdx < task.localItems.count else {
            // 所有 item 都传完了 → succeeded
            tasks[idx].status = .succeeded
            tasks[idx].endedAt = Date()
            tasks[idx].currentItem = nil
            currentProcess = nil
            kickRunLoop()
            return
        }

        let item = task.localItems[itemIdx]
        tasks[idx].currentItem = item

        let proc = ScpProcess()
        currentProcess = proc
        proc.start(
            alias: task.alias,
            localItem: item,
            remoteDir: task.remoteDir,
            onCompletion: { [weak self] outcome in
                Task { @MainActor in
                    self?.handleItemOutcome(taskID: taskID, itemIdx: itemIdx, item: item, outcome: outcome)
                }
            }
        )
    }

    private func handleItemOutcome(taskID: UUID, itemIdx: Int, item: URL, outcome: ScpProcess.RunOutcome) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        switch outcome {
        case .success:
            // 增加 transferredBytes（用 stat 算 item 的总大小，目录递归算）
            tasks[idx].transferredBytes += Self.bytesOf(item)
            // 继续下一个 item
            runItem(taskID: taskID, itemIdx: itemIdx + 1)
        case .failure(let message):
            tasks[idx].status = .failed
            tasks[idx].failureMessage = message
            tasks[idx].endedAt = Date()
            tasks[idx].currentItem = nil
            currentProcess = nil
            kickRunLoop()
        case .cancelled:
            tasks[idx].status = .cancelled
            tasks[idx].endedAt = Date()
            tasks[idx].currentItem = nil
            currentProcess = nil
            kickRunLoop()
        }
    }

    // MARK: - 工具

    /// 文件大小 / 目录递归大小。Bool 取的是 allocatedSize。
    /// 失败返回 0，进度可能略微不准但不阻塞流程。
    static func bytesOf(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? 0
        }
        // 目录：递归累加
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                   let size = values.totalFileAllocatedSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    /// 一组 URL 的总字节数 = 每个 bytesOf 之和。enqueue 前调用。
    static func totalBytes(of urls: [URL]) -> Int64 {
        urls.reduce(0) { $0 + bytesOf($1) }
    }
}
```

- [ ] **Step 2: 验证编译**

Run Build 模板. Expected: BUILD SUCCEEDED.

---

### Task 5: `UploadDestinationSheet` — 路径输入弹窗

**Files:**
- Create: `SSHKeeper/Features/Transfer/UploadDestinationSheet.swift`

- [ ] **Step 1: 创建文件**

Create `SSHKeeper/Features/Transfer/UploadDestinationSheet.swift`:

```swift
import SwiftUI

/// 上传目标路径输入 sheet。
/// 由 UploadCoordinator 弹出；用户填路径回车 → 调 onSubmit；点取消 → 调 onCancel。
struct UploadDestinationSheet: View {
    let alias: String
    let items: [URL]
    @Binding var remoteDir: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var pathFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(Color.accentColor)
                Text("上传到 \(alias)")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("远端目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("~/", text: $remoteDir)
                    .textFieldStyle(.roundedBorder)
                    .focused($pathFocused)
                    .onSubmit { onSubmit() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("待传项（\(items.count)）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: isDirectory(url) ? "folder" : "doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if isDirectory(url) {
                                    Text("（目录递归）")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
            }

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("上传") { onSubmit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(remoteDir.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 420, idealWidth: 480)
        .onAppear { pathFocused = true }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }
}
```

- [ ] **Step 2: 验证编译**

Run Build 模板. Expected: BUILD SUCCEEDED.

---

### Task 6: `TransferPanelView` — 工具栏 popover 内容

**Files:**
- Create: `SSHKeeper/Features/Transfer/TransferPanelView.swift`

- [ ] **Step 1: 创建文件**

Create `SSHKeeper/Features/Transfer/TransferPanelView.swift`:

```swift
import SwiftUI

/// 工具栏"传输"按钮点开后的 popover 内容。
/// 上半：running tasks；下半：终态 tasks。
struct TransferPanelView: View {
    @Environment(TransferEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("传输")
                    .font(.headline)
                Spacer()
                Button("清除已完成") {
                    engine.clearCompleted()
                }
                .font(.caption)
                .disabled(!hasTerminal)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let running = engine.tasks.filter { $0.status.isRunning || $0.status == .pending }
                    let terminal = engine.tasks.filter { $0.status.isTerminal }

                    if !running.isEmpty {
                        sectionHeader("进行中")
                        ForEach(running) { task in
                            TransferRowView(task: task)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            Divider()
                        }
                    }

                    if !terminal.isEmpty {
                        sectionHeader("已结束")
                        ForEach(terminal) { task in
                            TransferRowView(task: task)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            Divider()
                        }
                    }

                    if running.isEmpty && terminal.isEmpty {
                        Text("暂无任务")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 420)
    }

    private var hasTerminal: Bool {
        engine.tasks.contains { $0.status.isTerminal }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.06))
    }
}

/// 单个 task 行：alias / currentItem / 进度 / 字节 / 操作按钮。
struct TransferRowView: View {
    @Environment(TransferEngine.self) private var engine
    let task: TransferTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusIcon
                Text(task.alias)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text("→ \(task.remoteDir)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                actionButtons
            }

            if let item = task.currentItem {
                Text(item.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if task.status.isRunning || task.status == .pending {
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                Text(byteText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let err = task.localizedFailureMessage, task.status == .failed {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
    }

    private var statusIcon: some View {
        Group {
            switch task.status {
            case .pending:   Image(systemName: "clock").foregroundStyle(.secondary)
            case .running:   Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.accentColor)
            case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .cancelled: Image(systemName: "slash.circle").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch task.status {
        case .pending, .running:
            Button {
                engine.cancel(task.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("取消")
        case .failed, .cancelled:
            Button {
                engine.retry(task.id)
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }
            .buttonStyle(.borderless)
            .help("重试")
            Button {
                engine.remove(task.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除")
        case .succeeded:
            Button {
                engine.remove(task.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除")
        }
    }

    private var progressFraction: Double {
        guard task.totalBytes > 0 else { return 0 }
        return Double(task.transferredBytes) / Double(task.totalBytes)
    }

    private var byteText: String {
        "\(Self.formatBytes(task.transferredBytes)) / \(Self.formatBytes(task.totalBytes))"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1024 / 1024) }
        return String(format: "%.2f GB", Double(bytes) / 1024 / 1024 / 1024)
    }
}
```

- [ ] **Step 2: 验证编译**

Run Build 模板. Expected: BUILD SUCCEEDED.

---

### Task 7: `TransferToolbarButton` — 工具栏按钮 + popover 宿主

**Files:**
- Create: `SSHKeeper/Features/Transfer/TransferToolbarButton.swift`

- [ ] **Step 1: 创建文件**

Create `SSHKeeper/Features/Transfer/TransferToolbarButton.swift`:

```swift
import SwiftUI

/// 工具栏"传输"按钮：图标随状态变 + 底部微进度条 + 点击弹 popover 显示任务面板。
struct TransferToolbarButton: View {
    @Environment(TransferEngine.self) private var engine
    @State private var popoverShown: Bool = false

    var body: some View {
        Button {
            popoverShown.toggle()
        } label: {
            label
        }
        .popover(isPresented: $popoverShown, arrowEdge: .bottom) {
            TransferPanelView()
        }
        .help(helpText)
    }

    private var label: some View {
        ZStack(alignment: .bottom) {
            Image(systemName: iconName)
                .font(.system(size: 16))

            if let progress = engine.aggregateProgress {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * progress, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if engine.activeCount > 0 {
                Text("\(engine.activeCount)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .offset(x: 6, y: -4)
            }
        }
    }

    private var iconName: String {
        engine.activeCount > 0 ? "arrow.up.doc.fill" : "arrow.up.doc"
    }

    private var helpText: String {
        if engine.activeCount > 0 {
            return "传输（\(engine.activeCount) 个进行中）"
        }
        return "传输"
    }
}
```

- [ ] **Step 2: 验证编译**

Run Build 模板. Expected: BUILD SUCCEEDED.

---

### Task 8: `UploadCoordinator` — 三入口收口 + 弹 sheet

**Files:**
- Create: `SSHKeeper/Features/Transfer/UploadCoordinator.swift`

- [ ] **Step 1: 创建文件**

Create `SSHKeeper/Features/Transfer/UploadCoordinator.swift`:

```swift
import SwiftUI
import AppKit
import Observation

/// 三入口（拖拽 / ⌘⇧U / 未来扩展）的收口。
/// 状态机：idle → showingSheet(alias, items, remoteDir) → 上传 → idle。
/// 由 MainView 注入 environment，SSHTerminalView 的拖拽 / UploadCommands 的 ⌘⇧U 都调它。
@Observable
@MainActor
final class UploadCoordinator {
    private let engine: TransferEngine
    /// 当前要弹的 sheet 内容；nil = 不弹。
    var pendingPrompt: Prompt?

    struct Prompt: Identifiable, Equatable {
        let id = UUID()
        let alias: String
        let items: [URL]
        var remoteDir: String
    }

    init(engine: TransferEngine) {
        self.engine = engine
    }

    /// 拖拽入口：alias + 已抽出的 fileURLs。
    func beginUpload(alias: String, items: [URL]) {
        guard !items.isEmpty else { return }
        let initialPath = UploadDestinationMemory.get(alias: alias)
        pendingPrompt = Prompt(alias: alias, items: items, remoteDir: initialPath)
    }

    /// ⌘⇧U 入口：弹 NSOpenPanel 选文件后走 beginUpload。
    /// alias 由 caller 提供（active session 的 active pane alias）。
    func beginUploadForActiveSession(alias: String?) {
        guard let alias else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要上传的文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        beginUpload(alias: alias, items: urls)
    }

    /// Sheet 内"上传"按钮：把当前 prompt 入队 TransferEngine。
    func submitPendingPrompt() {
        guard let prompt = pendingPrompt else { return }
        let trimmedDir = prompt.remoteDir.trimmingCharacters(in: .whitespaces)
        guard !trimmedDir.isEmpty else { return }
        UploadDestinationMemory.set(alias: prompt.alias, path: trimmedDir)
        let total = TransferEngine.totalBytes(of: prompt.items)
        engine.enqueue(items: prompt.items, to: prompt.alias, remoteDir: trimmedDir, totalBytes: total)
        pendingPrompt = nil
    }

    /// Sheet 内"取消"按钮 / Esc。
    func cancelPendingPrompt() {
        pendingPrompt = nil
    }
}
```

- [ ] **Step 2: 验证编译**

Run Build 模板. Expected: BUILD SUCCEEDED.

---

### Task 9: `UploadCommands` — ⌘⇧U 快捷键

**Files:**
- Create: `SSHKeeper/Features/Transfer/UploadCommands.swift`

- [ ] **Step 1: 创建文件**

Create `SSHKeeper/Features/Transfer/UploadCommands.swift`:

```swift
import SwiftUI

/// 给 App.body.commands { } 注册的 ⌘⇧U 上传命令。
/// 通过 focusedSceneValue 拿当前窗口的 SessionEngine + UploadCoordinator。
struct FocusedUploadCoordinatorKey: FocusedValueKey {
    typealias Value = UploadCoordinator
}

extension FocusedValues {
    var uploadCoordinator: UploadCoordinator? {
        get { self[FocusedUploadCoordinatorKey.self] }
        set { self[FocusedUploadCoordinatorKey.self] = newValue }
    }
}

struct UploadCommands: Commands {
    @FocusedValue(\.sessionEngine) private var sessionEngine: SessionEngine?
    @FocusedValue(\.uploadCoordinator) private var coordinator: UploadCoordinator?

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("上传文件到当前主机…") {
                let alias = activeAlias()
                coordinator?.beginUploadForActiveSession(alias: alias)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(activeAlias() == nil || coordinator == nil)
        }
    }

    /// active session 的 active pane 的 alias；找不到返回 nil → 命令 disabled。
    private func activeAlias() -> String? {
        guard let session = sessionEngine?.activeSession,
              let paneID = session.activePaneID,
              let pane = session.panes.first(where: { $0.id == paneID }) else {
            return nil
        }
        return pane.alias
    }
}
```

- [ ] **Step 2: 验证编译**

Run Build 模板. Expected: BUILD SUCCEEDED.

---

### Task 10: 注入 engine / coordinator + 工具栏按钮接 popover + sheet 路由

**Files:**
- Modify: `SSHKeeper/App/SSHKeeperApp.swift`（构造、environment、commands、focusedSceneValue）
- Modify: `SSHKeeper/App/MainView.swift`（toolbar 加按钮、sheet 挂在 MainView 上）

- [ ] **Step 1: 修改 `SSHKeeperApp.swift`**

定位 `@State private var sessionEngine: SessionEngine = SessionEngine()` 这一行（在 `struct SSHKeeperApp: App` 内）。在它**之下**添加：

```swift
    @State private var sessionEngine: SessionEngine = SessionEngine()
    @State private var transferEngine: TransferEngine = TransferEngine()
    @State private var uploadCoordinator: UploadCoordinator
```

然后在 `init() {` 内、`_databaseStore = State(initialValue: DatabaseStore(sidecar: shared))` 之后追加：

```swift
        _databaseStore = State(initialValue: DatabaseStore(sidecar: shared))
        let initialEngine = TransferEngine()
        _transferEngine = State(initialValue: initialEngine)
        _uploadCoordinator = State(initialValue: UploadCoordinator(engine: initialEngine))
```

在 `body` 内 `WindowGroup("SSHKeeper") { MainView() ... }` 块里，链上更多 `.environment` 和 `.focusedSceneValue`。找到现有的：

```swift
            MainView()
                .environment(store)
                .environment(sessionEngine)
                .environment(panelStore)
                .environment(databaseStore)
                .environment(databaseWorkspace)
                .environment(panelWorkspace)
                .environment(sidecar)
                .focusedSceneValue(\.sessionEngine, sessionEngine)
```

改为（追加 2 个 `.environment` + 1 个 `.focusedSceneValue`，保留原有）：

```swift
            MainView()
                .environment(store)
                .environment(sessionEngine)
                .environment(panelStore)
                .environment(databaseStore)
                .environment(databaseWorkspace)
                .environment(panelWorkspace)
                .environment(sidecar)
                .environment(transferEngine)
                .environment(uploadCoordinator)
                .focusedSceneValue(\.sessionEngine, sessionEngine)
                .focusedSceneValue(\.uploadCoordinator, uploadCoordinator)
```

定位 `.commands { SessionCommands() }` 那一段。改为追加 `UploadCommands()`：

```swift
        .commands {
            SessionCommands()
            UploadCommands()
        }
```

- [ ] **Step 2: 修改 `MainView.swift` — 加 toolbar 按钮 + sheet**

定位 `.toolbar {` 块。在最后一个 `ToolbarItem(placement: .secondaryAction) { ... }`（密钥按钮）**之后**追加新的 ToolbarItem：

```swift
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
```

在 MainView 的 body 末尾找 `.alert(item: $bannerMessage) { ... }`。在它**之前**插入路径 sheet 路由：

```swift
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
```

注意 `uploadCoordinator` 来源：在 MainView 的字段区加。

定位 `MainView.swift` 顶部的 `@Environment` 字段块（line 5-7）：

```swift
struct MainView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionEngine.self) private var engine
    @Environment(SidecarController.self) private var sidecar
```

在 `@Environment(SidecarController.self) private var sidecar` 下面追加：

```swift
    @Environment(SidecarController.self) private var sidecar
    @Environment(UploadCoordinator.self) private var uploadCoordinator
```

- [ ] **Step 3: 验证编译**

Run Build 模板. Expected: BUILD SUCCEEDED.

- [ ] **Step 4: 手动验证（无拖拽，仅工具栏 + ⌘⇧U）**

```bash
pkill -x SSHKeeper 2>/dev/null
sleep 1
open ~/Library/Developer/Xcode/DerivedData/SSHKeeper-*/Build/Products/Debug/SSHKeeper.app
```

测试：

1. 主窗口右上工具栏应见新的"传输"按钮（向上箭头文档图标）；点开 → popover 显示"暂无任务"
2. 打开一个 SSH session（任意主机），保证 active session 存在
3. 按 ⌘⇧U → 应弹 NSOpenPanel；选一个本地小文件 → 应弹"上传到 \<alias>"sheet；点取消 → sheet 消失
4. 再 ⌘⇧U → 选文件 → 在 sheet 里填 `/tmp` → 点"上传"
5. popover 应出现一个 task；进度短暂后变 succeeded
6. 在 ssh session 里 `ls /tmp/<filename>` 验证文件到了

如果上面 5/6 失败：scp 走 askpass 路径可能在密码主机上不通。记下错误消息（task 行的红字），告诉我，再修。

---

### Task 11: SSHTerminalView 加 wrapper NSView 接拖拽

**Files:**
- Modify: `SSHKeeper/Features/Sessions/SSHTerminalView.swift`（替换 makeNSView / dismantleNSView，加 DropTargetView）
- Modify: `SSHKeeper/Features/Sessions/TabbedSessionContainer.swift`（如果 SSHTerminalView 构造方需要传 onDrop）

- [ ] **Step 1: 改 `SSHTerminalView.swift` — 新增 wrapper + drop delegate**

把现有 `SSHTerminalView` 的 `makeNSView` / `dismantleNSView` 和 `Coordinator` 改造。下面是**整个文件**的目标内容（替换整文件）：

```swift
import SwiftUI
import AppKit
import SwiftTerm
import SSHKeeperCore

struct SSHTerminalView: NSViewRepresentable {
    let alias: String
    let onTitleChange: (String) -> Void
    let onProcessExit: (Int32?) -> Void
    /// 拖拽文件到终端窗口时回调，传出 URL 列表（仅 fileURL；非文件 drop 不触发）。
    var onDrop: (([URL]) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onTitleChange: onTitleChange, onProcessExit: onProcessExit, onDrop: onDrop)
    }

    func makeNSView(context: Context) -> DropTargetView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["COLORTERM"] = "truecolor"

        if PasswordKeychain.has(alias: alias),
           let appExecutable = Bundle.main.executablePath {
            env["SSH_ASKPASS"] = appExecutable
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            env[AskpassMain.triggerEnvVar] = "1"
            env[AskpassMain.aliasEnvVar] = alias
        }

        let envArray = env.map { "\($0.key)=\($0.value)" }
        terminal.startProcess(executable: "/usr/bin/ssh", args: ["-tt", alias], environment: envArray)

        let wrapper = DropTargetView()
        wrapper.coordinator = context.coordinator
        wrapper.terminal = terminal
        wrapper.addSubview(terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: wrapper.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        ])
        wrapper.registerForDraggedTypes([.fileURL])
        return wrapper
    }

    func updateNSView(_ nsView: DropTargetView, context: Context) {
        context.coordinator.onDrop = onDrop
        nsView.coordinator = context.coordinator
    }

    @MainActor
    static func dismantleNSView(_ nsView: DropTargetView, coordinator: Coordinator) {
        // 杀掉 ssh 子进程，让 channel cleanup
        nsView.terminal?.process.terminate()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
        let onTitleChange: (String) -> Void
        let onProcessExit: (Int32?) -> Void
        var onDrop: (([URL]) -> Void)?

        init(
            onTitleChange: @escaping (String) -> Void,
            onProcessExit: @escaping (Int32?) -> Void,
            onDrop: (([URL]) -> Void)?
        ) {
            self.onTitleChange = onTitleChange
            self.onProcessExit = onProcessExit
            self.onDrop = onDrop
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            onTitleChange(title)
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
            onProcessExit(exitCode)
        }
    }
}

/// SwiftTerm 的 LocalProcessTerminalView 自身可能也注册了 fileURL drop（粘 path）。
/// 套一层 DropTargetView：它在 SwiftTerm view 之上接 drop，吃掉 fileURL 后就不再传下去。
/// 鼠标事件 / 键盘事件不受影响（hitTest 默认走 subview）。
final class DropTargetView: NSView {
    weak var coordinator: SSHTerminalView.Coordinator?
    weak var terminal: LocalProcessTerminalView?

    /// 总是允许 copy operation；拒绝其它 op（move 会让源被剪走）。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return urls(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return urls(from: sender).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return !urls(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = urls(from: sender)
        guard !urls.isEmpty else { return false }
        // hop 到主线程；coordinator.onDrop 由 SwiftUI 写的闭包，应在主线程
        DispatchQueue.main.async { [weak self] in
            self?.coordinator?.onDrop?(urls)
        }
        return true
    }

    /// 把 pasteboard 里的 fileURL 抽出来。只接受 `public.file-url`。
    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let pb = sender.draggingPasteboard
        guard let items = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return []
        }
        return items
    }

    /// hitTest 默认行为：交给子 view 处理鼠标 / 键盘。drag 事件不走 hitTest 路径，
    /// 直接由 dragging delegate methods 接，所以这里不用 override。
}
```

> 这一步会把现有 `SSHTerminalView.swift` 整文件替换。

- [ ] **Step 2: 验证编译**

Run Build 模板. Expected: **会失败** —— `TabbedSessionContainer.swift` 调用 `SSHTerminalView(alias:onTitleChange:onProcessExit:)`，新签名 `onDrop:` 是可选默认 nil，应该向后兼容 → 实际**应该不失败**。但旧调用类型为 `LocalProcessTerminalView`，dismantleNSView 签名变了，调用方应该自动适配（NSViewRepresentable 由编译器走 protocol）。

如果编译失败，原因可能是 `dismantleNSView` 签名变化外部不可见、应该不受影响。报错则把错误贴回。

- [ ] **Step 3: 修改 `TabbedSessionContainer.swift` — 接 onDrop 到 UploadCoordinator**

定位文件内 `private struct PaneView: View {` 块（约 line 92）。当前结构：

```swift
private struct PaneView: View {
    let engine: SessionEngine
    let session: Session
    let pane: Pane

    var body: some View {
        ZStack {
            Color.black
            SSHTerminalView(
                alias: pane.alias,
                onTitleChange: { title in
                    engine.updatePaneTitle(sessionID: session.id, paneID: pane.id, title: title)
                },
                onProcessExit: { code in
                    engine.markPaneExited(sessionID: session.id, paneID: pane.id, code: code)
                }
            )
```

在 `let pane: Pane` 下面追加一个 `@Environment` 字段，并在 `SSHTerminalView(...)` 末尾追加 `onDrop:` 参数。改造后：

```swift
private struct PaneView: View {
    let engine: SessionEngine
    let session: Session
    let pane: Pane
    @Environment(UploadCoordinator.self) private var uploadCoordinator

    var body: some View {
        ZStack {
            Color.black
            SSHTerminalView(
                alias: pane.alias,
                onTitleChange: { title in
                    engine.updatePaneTitle(sessionID: session.id, paneID: pane.id, title: title)
                },
                onProcessExit: { code in
                    engine.markPaneExited(sessionID: session.id, paneID: pane.id, code: code)
                },
                onDrop: { urls in
                    uploadCoordinator.beginUpload(alias: pane.alias, items: urls)
                }
            )
```

其余 PaneView 内容（exitedOverlay / activeIndicator / .frame / .onTapGesture 等）不动。

- [ ] **Step 4: 验证编译 + 手动跑**

Run Build 模板. Expected: BUILD SUCCEEDED.

重启 App：

```bash
pkill -x SSHKeeper 2>/dev/null
sleep 1
open ~/Library/Developer/Xcode/DerivedData/SSHKeeper-*/Build/Products/Debug/SSHKeeper.app
```

测试：

1. 打开 SSH session
2. 从 Finder 拖一个本地文件到终端窗口区域 → 应弹"上传到 \<alias>"sheet
3. 填路径 `/tmp` → 上传 → popover 显示 task 推进 → succeeded
4. 远端 `ls /tmp/<filename>` 验证
5. 拖一个目录 → sheet 显示"（目录递归）" → 上传 → succeeded → 远端验证递归内容
6. 拖多个文件 → sheet 显示多项 → 上传 → 串行跑（一个一个，popover currentItem 切换）

如果拖拽不响应：可能 SwiftTerm view 在 hitTest 上吃掉了 drag。报现象给我。

---

### Task 12: 全量手动验证清单

**Files:** 无新改动。

- [ ] **Step 1: 按 spec §13.2 逐条手动验证**

```bash
pkill -x SSHKeeper 2>/dev/null
sleep 1
xcodebuild build -project SSHKeeper.xcodeproj -scheme SSHKeeper -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
open ~/Library/Developer/Xcode/DerivedData/SSHKeeper-*/Build/Products/Debug/SSHKeeper.app
```

逐条过：

1. 拖单文件到终端 → 弹对话框 → 上传 → popover 看进度 → 完成
2. 拖多文件 / 目录 → 全传 → 完成
3. 拖到非 SSH 窗口（数据库窗口）→ 无反应
4. ⌘⇧U（有 active session）→ NSOpenPanel → 选文件 → 弹对话框 → 上传
5. ⌘⇧U（无 active session）→ 不响应（菜单 disabled）
6. 工具栏按钮：无任务时图标 `arrow.up.doc`；running 时带 badge + 微进度条
7. 取消：进度过半按 X → scp 进程被杀 → 状态 cancelled
8. 失败重试：填错路径上传 → 失败 → 改对路径 retry → 成功
9. 路径记忆：传到 `/tmp` 后再拖，对话框默认填 `/tmp`
10. 密码主机（Keychain 里有密码的 alias）+ 密钥主机 都能传
11. 关闭对话框前不 enqueue；点取消 task 列表不增
12. 大文件（≥100MB）：UI 不卡，可继续在终端操作

任一项失败 → 记下症状反馈给我，再开 follow-up Task 修。

全部通过 → SSH 上传功能完成。
