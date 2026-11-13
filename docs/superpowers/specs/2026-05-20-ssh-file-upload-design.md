# SSH 文件上传 — 设计

- 日期: 2026-05-20
- 状态: Draft（待用户复核）
- 作者: Claude（与 long 协同 brainstorm）
- 范围: `0505-SSHKeeper`，新增 `SSHKeeper/Features/Transfer/`，少量改 `SSHTerminalView.swift` / `MainView.swift` / `SessionCommands.swift`

## 1. 背景与现状

SSHKeeper 现有 SSH 连接走 `/usr/bin/ssh` 子进程，由 SwiftTerm 包装；密码主机靠 `SSH_ASKPASS` + `PasswordKeychain` 提供。alias 是 OpenSSH ssh_config 里的 Host 别名。

没有任何文件传输能力。用户需要从本地把文件传到已连接的远端，目前只能在终端里手敲 scp / rz / curl，与"图形化 SSH 工具"的体验不匹配。

## 2. 目标

为已配置的 SSH 主机加文件上传能力，**复用现有 askpass / Keychain / alias 体系，零新 Swift 依赖**：

- 三种入口：拖拽到终端窗口、⌘⇧U、工具栏"传输"按钮（仅看任务）
- 支持单 / 多文件 + 目录递归
- 上传过程独立于 SSH session：取消、重试、查看历史
- 远端路径用户输入，按主机记忆最近一次

## 3. 非目标

- 下载（远端 → 本地）
- 远端目录浏览（依赖 sftp，独立 feature）
- 续传 / 断点续传
- 多 task 并发（MVP 串行）
- 上传速率限制 / 通道复用 / 进度内部百分比（单文件级粗粒度即够）
- 拖拽到主机侧边栏（仅终端窗口接收）

## 4. 关键决策

| 项 | 决策 | 备选 / 理由 |
|---|---|---|
| 传输工具 | `/usr/bin/scp -r -p -O` | sftp batch 适合远端浏览未来 feature；NIO-SSH 引入大依赖否决 |
| 密码 | 复用 `SSH_ASKPASS` + `PasswordKeychain` | 与现有 ssh 启动同款 |
| 进度粒度 | 文件级（每文件起一次 scp） | 跳过 pty + progress meter 复杂度；MVP 简单可靠 |
| 多 task | 串行（一次跑一个 task） | 多并发后期再加 `maxConcurrent` |
| 单 task 内多文件 | 串行（一次 scp 一个文件） | 同上 |
| 同名冲突 | 默认覆盖（scp 原生行为）| 检查需要额外 SSH 调用，增 UI 流程 |
| 历史持久化 | 仅内存，App 退出即丢 | 路径记忆 (UserDefaults) 单独存 |

## 5. 行为规约

### 5.1 入口

| 触发 | 行为 |
|---|---|
| 拖文件 / 文件夹 → SSH 终端窗口 (`SSHTerminalView`) | 提取 fileURLs；调 `UploadCoordinator.beginUpload(alias: pane.alias, items: urls)` |
| ⌘⇧U（active session 存在） | 弹 `NSOpenPanel`（allowsMultipleSelection, allowsDirectories）选 → `beginUpload`；alias 取 active session 的 active pane 的 alias（split 时即焦点 pane） |
| ⌘⇧U（无 active session） | 不响应（按钮 disabled 即可，无提示） |
| 顶部工具栏"传输"按钮 | 弹 popover 显示任务面板，不直接发起上传 |

### 5.2 上传目标路径对话框 (`UploadDestinationSheet`)

- 显示项：
  - 目标主机 alias（不可改）
  - 待传项列表：每条本地 path / size / 是否目录
  - 远端目录输入框，默认填 `UploadDestinationMemory[alias]`（首次为 `~/`）
- 按钮："取消" / "上传"
- 回车 = 上传
- 上传提交时：
  - 写回 memory
  - 调 `TransferEngine.enqueue(items:, to:, remoteDir:)`
  - 关闭对话框

### 5.3 任务面板 (`TransferPanelView`，popover)

工具栏按钮：
- 图标：`arrow.up.doc`（无任务）/ 带计数 badge（有 running）
- 按钮底部一条 1px 微指示器，按全部 running task 的 `transferredBytes / totalBytes` 填充
- 点击 → popover

popover 内容：
- 上方："进行中"区，每条：alias / currentFile / 进度条 / `xKB / yMB` / 取消按钮
- 下方："已完成 / 失败"区（最近 50），失败显示错误摘要 + 重试按钮 + 删除按钮
- 底部："清除已完成" 按钮

### 5.4 任务状态机

```
pending → running → succeeded
                  → failed(message)
                  → cancelled

retry: failed | cancelled → pending → running → ...
```

- `running` 中按取消 → 子进程 `terminate()` → 状态置 `cancelled`
- 失败时：当前文件可能在远端残留，错误消息里附"远端 `<currentFile>` 可能不完整"
- 串行队列：同时只跑一个 task；多个 task 按 enqueue 顺序排队

## 6. 架构

```
MainView (toolbar 按 button: TransferToolbarButton)
  ├─ @State transferEngine: TransferEngine
  ├─ @State uploadCoordinator: UploadCoordinator
  └─ .commands { UploadCommands(coordinator: ...) }     // ⌘⇧U
        ↓
TabbedSessionContainer
  └─ SSHTerminalView(alias:)
        ├─ registerForDraggedTypes([.fileURL])
        └─ onDrop → coordinator.beginUpload(alias:, items:)

UploadCoordinator (@MainActor)
  ├─ beginUpload(alias:, items: [URL])      // 来自拖拽
  ├─ beginUploadForActiveSession()           // ⌘⇧U
  └─ 内部：弹 UploadDestinationSheet → enqueue TransferEngine

TransferEngine (@Observable @MainActor)
  ├─ tasks: [TransferTask]
  ├─ enqueue / cancel / retry / remove / clearCompleted
  └─ 私有 runLoop：找下一个 pending → 起 ScpProcess → 等结束 → 找下一个

ScpProcess
  ├─ start(alias:, localFile: URL, remoteDir: String, onExit:)
  ├─ cancel()
  └─ 内部：Process + 构造 args + 注入 askpass env + 收 stderr 末 N 行

TransferPanelView (popover)
  └─ List(transferEngine.tasks) → row UI / cancel / retry / remove
```

## 7. 数据模型

```swift
struct TransferTask: Identifiable, Equatable {
    let id: UUID
    let alias: String
    let localItems: [URL]            // 用户一次提交的所有项（含目录展开）
    let remoteDir: String
    let totalBytes: Int64            // enqueue 时预算
    var transferredBytes: Int64
    var currentFile: URL?            // 当前正在传的具体文件
    var status: TransferStatus
    let createdAt: Date
    var endedAt: Date?
    var failureMessage: String?
}

enum TransferStatus: Equatable {
    case pending
    case running
    case succeeded
    case failed       // 详情在 task.failureMessage
    case cancelled

    var isRunning: Bool { self == .running }
    var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
}
```

`localItems` 在 `enqueue` 时展开：若是目录，遍历得到全部文件 + 目录大小，记进 `totalBytes`；scp 调用时仍以原始路径（含目录）调，让 scp 自己 -r 递归（避免重建目录结构的麻烦），传完该顶层项一次性增加 `transferredBytes`。

> **简化决策**：MVP 不细到目录内部每文件进度，目录作为一个"单位"处理。一次 scp 调用 = 一个 localItems 元素 = 一次 transferredBytes 增量。`totalBytes` 仍按目录递归算总大小，进度条直观。

## 8. ScpProcess 详细

### 8.1 命令构造

**最终 args**（决策固化）：

```
scp -r -p -O -q \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    -- <local> <alias>:<remoteDir>/
```

| flag | 作用 |
|---|---|
| `-r` | 递归（顶层是文件也无害） |
| `-p` | 保留 mtime / 权限 |
| `-O` | 强制走传统 SCP 协议，避开 SFTP 协议在非 tty 下进度行为不一致 |
| `-q` | 静默 progress（粗粒度不需要，少噪音） |
| `-o StrictHostKeyChecking=accept-new` | 首次新主机自动 TOFU（OpenSSH 7.6+，macOS 14 满足） |
| `-o ConnectTimeout=15` | 防止挂死 |

**不加 `-B`**：`-B` (batch mode) 禁用所有 ssh 交互式 prompts，与 `SSH_ASKPASS_REQUIRE=force` 的语义存在历史上的灰色地带；现有 SSHTerminalView 也不加 `-B`，保持一致。密码主机靠 askpass 通道喂，已知可工作。

### 8.2 askpass 注入（同 SSHTerminalView）

```swift
if PasswordKeychain.has(alias: alias),
   let appExecutable = Bundle.main.executablePath {
    env["SSH_ASKPASS"] = appExecutable
    env["SSH_ASKPASS_REQUIRE"] = "force"
    env["DISPLAY"] = env["DISPLAY"] ?? ":0"
    env[AskpassMain.triggerEnvVar] = "1"
    env[AskpassMain.aliasEnvVar] = alias
}
```

### 8.3 stderr 收集

scp 失败时把 stderr 全部读完，取最后 5 行作为 `failureMessage`。stdout 通常为空（粗粒度不解析）。

### 8.4 取消

`process.terminate()` (SIGTERM)；scp 会断开 ssh 连接；远端可能残留部分写入的当前文件（spec 中明示，不试图清理）。

## 9. UploadDestinationMemory

```swift
enum UploadDestinationMemory {
    private static let key = "uploadDestinationByAlias.v1"
    static func get(alias: String) -> String { UserDefaults...[alias] ?? "~/" }
    static func set(alias: String, path: String) { ... }
}
```

无清理 UI（与现有 user prefs 风格一致：纯隐式记忆，无管理界面）。

## 10. 拖拽接入

`SSHTerminalView.makeNSView`：

```swift
view.registerForDraggedTypes([.fileURL])
context.coordinator.terminalView = view
// 给 view 设 NSDraggingDestination delegate（通过 subclass 或在 Coordinator 上实现）
```

`Coordinator` 实现 `NSDraggingDestination`：
- `draggingEntered`: 返回 `.copy`，高亮 view（可选叠加 overlay 显"放下以上传"）
- `performDragOperation`: 抽 fileURLs → 主线程 `onDrop(alias, urls)`

`onDrop` 由 `SSHTerminalView` 的初始化 param 注入；`TabbedSessionContainer` 拿到 `UploadCoordinator`（通过 `@Environment` 或显式注入）→ 调 `coordinator.beginUpload(alias:, items:)`。

> **拦截位置**：SwiftTerm 的 `LocalProcessTerminalView` 自己也可能注册了 fileURL drop（粘贴文件路径）。在 SSHKeeper 这一层 register + 实现 delegate，优先级高于 SwiftTerm 默认。如果 SwiftTerm 用 first responder 链处理，需要在 view subclass 里实现 `prepareForDragOperation` / `performDragOperation` 直接吃掉。

## 11. ⌘⇧U Commands

新增 `UploadCommands` `CommandMenu` 或 `CommandGroup`，挂到 `App` body。响应：

```swift
.commands {
    CommandGroup(after: .toolbar) {
        Button("上传文件到当前主机…") {
            uploadCoordinator.beginUploadForActiveSession()
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .disabled(sessionEngine.activeSession == nil)
    }
}
```

如果 `sessionEngine.activeSession?.primaryAlias` 不能从 SwiftUI Commands 直接拿，则在 `UploadCoordinator` 内部读 `SessionEngine`（注入），active session 为 nil 时方法直接 no-op。

## 12. 错误本地化

`TransferTask.localizedFailureMessage` 计算属性：

```swift
var localized: String {
    guard let raw = failureMessage else { return "未知错误" }
    if raw.contains("Host key verification failed") {
        return "主机密钥校验失败（known_hosts 未信任）。请先用终端 ssh 一次以接受指纹。"
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
```

## 13. 测试

### 13.1 单元测试

- `ScpProcessTests`
  - args 构造正确（含 alias / remoteDir / `--` 分隔）
  - askpass env 仅在 `PasswordKeychain.has(alias)` 时注入
  - 不实跑 scp（用 dependency injection 把 Process 换成 mock；或仅断 args/env 拼装）
- `TransferEngineTests`
  - enqueue 后状态 = pending
  - mock ScpProcess：success → 状态 succeeded、transferredBytes = totalBytes
  - mock ScpProcess：failure → 状态 failed、failureMessage 非空
  - cancel：状态 cancelled、之后的 pending task 不动
  - retry：failed → pending → mock success → succeeded
  - 串行：同时只有一个 running
- `UploadDestinationMemoryTests`
  - get / set / 不同 alias 隔离

### 13.2 手动验证

1. 拖单文件到终端 → 弹对话框 → 上传 → popover 看进度 → 完成
2. 拖多文件 / 目录 → 全传 → 完成
3. 拖到非 SSH 窗口（数据库窗口）→ 无反应
4. ⌘⇧U（有 active session）→ NSOpenPanel → 选文件 → 弹对话框 → 上传
5. ⌘⇧U（无 active session）→ 不响应
6. 工具栏按钮：无任务时图标素净；running 时带 badge / 微进度条
7. 取消：进度过半按 X → scp 进程被杀 → 状态 cancelled
8. 失败重试：填错路径上传 → 失败 → 改对路径 retry → 成功
9. 路径记忆：传到 `/tmp` 后再拖，对话框默认填 `/tmp`
10. 密码主机 / 密钥主机均能传（askpass 路径生效）
11. 关闭对话框前不 enqueue；点取消 task 列表不增
12. 大文件（≥100MB）：UI 不卡，可继续在终端操作

## 14. 文件结构

新增：
```
SSHKeeper/Features/Transfer/
├── TransferEngine.swift
├── TransferTask.swift
├── ScpProcess.swift
├── UploadCoordinator.swift
├── UploadDestinationSheet.swift
├── UploadDestinationMemory.swift
├── TransferPanelView.swift
└── TransferToolbarButton.swift   // 含 badge + 微进度条的工具栏按钮
```

修改：
- `SSHKeeper/Features/Sessions/SSHTerminalView.swift`：注册 drag types + delegate + `onDrop` 回调 param
- `SSHKeeper/Features/Sessions/TabbedSessionContainer.swift`：把 `onDrop` 接到 `UploadCoordinator`
- `SSHKeeper/App/MainView.swift`：注入 `TransferEngine` / `UploadCoordinator` 到 environment；toolbar 加 `TransferToolbarButton`；popover 状态
- `SSHKeeper/App/SSHKeeperApp.swift`：`.commands` 加 `UploadCommands`

`SSHKeeperCore` 暂不动（scp 子进程的具体实现可以放 App 层；如果未来想跨复用，再下沉到 Core）。

## 15. 风险

| 风险 | 缓解 |
|---|---|
| scp `-B` 与 `SSH_ASKPASS_REQUIRE=force` 不兼容 | 默认不加 -B；首次新主机走 `StrictHostKeyChecking=accept-new` |
| 旧远端 sshd 不支持 `-O`（强制 SCP 协议被拒） | 失败错误消息明确；用户可通过 ~/.ssh/config 个例处理；MVP 不自动降级 |
| SwiftTerm 默认 fileURL drop 行为冲突（被吃掉粘成路径文本） | 在 NSView subclass / coordinator 拦 `performDragOperation` 直接返回 true，不传给 SwiftTerm |
| 大目录 totalBytes 预算耗时（递归 stat） | 后台 `Task` 算；预算完成前 UI 显示 `…`；首次 enqueue 慢可接受 |
| askpass 在 scp 路径上未被实际验证 | 实现后立即手测密码主机的 case，作为 acceptance gate |
| 远端残留部分文件（取消 / 失败） | 错误 / cancel 消息里附"远端可能残留 currentFile"；不主动清理（清理需要再起一次 ssh，引入额外失败面） |
| ⌘⇧U 与其他 macOS 系统快捷键冲突 | 现有 ⌘⇧E / ⌘⇧P / ⌘⇧K 都用了 .shift+.command，⌘⇧U 与 Safari/Mail 内的快捷键冲突仅在那些 App 内才生效，App-local 无冲突 |
