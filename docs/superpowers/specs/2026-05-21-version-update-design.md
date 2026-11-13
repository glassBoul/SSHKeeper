# 版本更新 — 设计

- 日期: 2026-05-21
- 状态: Draft（待用户复核）
- 作者: Claude（与 long 协同 brainstorm）
- 范围: `0505-SSHKeeper`

## 1. 背景

SSHKeeper 当前 `1.0.0`，发布通过 `web/` 静态站点（含 DMG）托管在 `https://sshkeeper.feilian.cc`。用户安装后无任何方式知道新版本——必须主动回访站点对比版本号。需要应用内更新提示能力。

## 2. 目标

零新依赖、最小心智实现：

- App 启动后静默检查；菜单"检查更新…"手动触发
- 检查源：自建 `https://sshkeeper.feilian.cc/version.json`
- 体验：发现新版本 → 弹 sheet 显示 release notes → 用户点"下载" → 调系统浏览器打开 DMG URL → 用户手工装

## 3. 非目标

- DMG SHA256 校验
- 应用内下载 + 自动安装（需要复杂的 .app 替换 + 重启 + 签名校验逻辑）
- 强制更新 / 最低支持版本（minimum 字段）
- 多 channel（beta / stable）
- 引入 Sparkle 框架
- 增量 / 差异更新

## 4. version.json schema

部署到 `https://sshkeeper.feilian.cc/version.json`，每次发布同时更新此文件：

```json
{
  "latest": "1.0.1",
  "downloadUrl": "https://sshkeeper.feilian.cc/SSHKeeper-1.0.1.dmg",
  "releaseNotes": "- 修了 X\n- 加了 Y\n- 改进了 Z"
}
```

字段语义：
- `latest`（必填）：语义化版本字符串，将与本机 `CFBundleShortVersionString` (= `MARKETING_VERSION`，当前 `1.0.0`) 比较
- `downloadUrl`（必填）：DMG 完整 URL；后期支持换分发域名
- `releaseNotes`（必填）：纯文本（可含 `\n` 换行），UI 用 `Text` 渲染（不解析 Markdown）

未来扩展字段（向后兼容，旧 client 忽略）：`minimum`、`publishedAt`、`sha256`、`channel` 等。

## 5. 行为规约

### 5.1 启动检查

App 启动后延迟 3 秒（避免阻塞冷启动 / 与用户首屏交互竞争）：

```
fetch version.json (timeout = 8s)
  → 解析 VersionInfo
  → 比较 latest 与本机版本
  → 若 latest > 本机版本：
      若 UploadMemory.skippedVersion != latest:
          弹 update sheet
  → 若 fetch / 解析失败：静默吞（不打扰用户）
```

### 5.2 菜单"检查更新…"

`SSHKeeperApp` `.commands { ... }` 注册 macOS 标准 App menu 下的 "检查更新…"。点击：

```
fetch version.json
  → 成功 + 有新版本：弹 update sheet（无视 skippedVersion）
  → 成功 + 已是最新：弹"已是最新版本（1.0.0）"小提示 sheet
  → 失败：弹错误 sheet "无法获取更新信息: <localized error>"
```

### 5.3 Update Sheet UI

```
[App 图标 / "发现新版本"]
当前版本：1.0.0
最新版本：1.0.1

[releaseNotes 滚动区]
- 修了 X
- 加了 Y

[跳过此版本] [稍后]              [下载]
```

按钮：
- **下载**（主按钮，回车）：调 `NSWorkspace.shared.open(URL(downloadUrl))` → 系统浏览器打开 → sheet 关
- **稍后**（Esc）：sheet 关，不记跳过；下次启动还弹
- **跳过此版本**：`UpdateMemory.skippedVersion = latest`，sheet 关；下次启动同版本不再弹（菜单手动触发仍能弹）

### 5.4 "已是最新版本"小 sheet

简单提示，单按钮"好"关闭：

```
[✓ 图标]
SSHKeeper 已是最新版本

当前版本：1.0.0

                                  [好]
```

### 5.5 错误 sheet（仅菜单触发）

```
[⚠ 图标]
无法获取更新信息

<localized error 比如 "网络连接已断开" / "找不到 server">

                                  [好]
```

## 6. 版本比较算法

字符串语义版本，按 `.` 分段比 Int：

```swift
static func compare(_ a: String, _ b: String) -> ComparisonResult {
    let aParts = a.split(separator: ".").map { Int($0) ?? -1 }
    let bParts = b.split(separator: ".").map { Int($0) ?? -1 }
    let maxLen = max(aParts.count, bParts.count)
    for i in 0..<maxLen {
        let av = i < aParts.count ? aParts[i] : 0
        let bv = i < bParts.count ? bParts[i] : 0
        // 任一段非数字 (-1) → fallback localizedStandardCompare
        if av == -1 || bv == -1 {
            return a.localizedStandardCompare(b)
        }
        if av < bv { return .orderedAscending }
        if av > bv { return .orderedDescending }
    }
    return .orderedSame
}
```

- 段数不同：短的补 0
- 任一段非纯数字（如 `1.0.0-beta`）：fallback `localizedStandardCompare`（macOS 内置语义比较）
- 不依赖第三方版本库

## 7. 架构

### 7.1 文件结构

**SSHKeeperCore 新增**（纯逻辑，可单测，跟现有 `Auth/`、`Database/` 同级）：

```
SSHKeeperCore/Features/Updates/
├── VersionInfo.swift       # struct VersionInfo: Codable + parse(_ data: Data)
└── VersionChecker.swift    # static fetch(url:) async throws -> VersionInfo
                            # static compare(_ a: String, _ b: String) -> ComparisonResult
                            # static isNewer(remote: String, than local: String) -> Bool
```

**SSHKeeper 新增**（UI + 状态）：

```
SSHKeeper/Features/Updates/
├── UpdateMemory.swift      # UserDefaults: skippedVersion
├── UpdateCoordinator.swift # @Observable @MainActor: 拉数据 + 弹 sheet 状态机
├── UpdateSheet.swift       # SwiftUI sheet UI（含新版 / 最新 / 错误 三态）
└── UpdateCommands.swift    # 菜单 "检查更新…"
```

**修改**：

- `SSHKeeper/App/SSHKeeperApp.swift`：
  - 加 `@State updateCoordinator: UpdateCoordinator`
  - WindowGroup body 加 `.environment(updateCoordinator)` 和 `.focusedSceneValue(\.updateCoordinator, updateCoordinator)`
  - `.commands { ... UpdateCommands() }`
  - WindowGroup root `.task` 内调 `updateCoordinator.checkOnLaunch()`（延迟 3s 在 coordinator 内做）
- `SSHKeeper/App/MainView.swift`：
  - `@Environment(UpdateCoordinator.self) private var updateCoordinator`
  - sheet 路由：`coordinator.presentation` 是 enum `.hidden / .newVersion(info) / .latest(current) / .error(msg)`

### 7.2 配置项

URL 写死在常量，方便集中改：

```swift
enum UpdateConfig {
    static let manifestURL = URL(string: "https://sshkeeper.feilian.cc/version.json")!
    static let launchCheckDelay: TimeInterval = 3.0
    static let fetchTimeout: TimeInterval = 8.0
}
```

放 `SSHKeeperCore/Features/Updates/VersionChecker.swift` 内或单独文件。

## 8. 错误处理

- **启动检查**：全部静默吞（不弹 sheet 也不打 alert）。日志走 `OSLog`（subsystem `com.sshkeeper.app` category `update`），用户用 Console.app 可查
- **菜单手动**：错误转人话：
  - URLError.notConnectedToInternet → "网络未连接"
  - URLError.timedOut → "请求超时"
  - URLError.cannotFindHost → "无法访问更新服务器"
  - HTTP 非 200 → "更新服务器返回错误（status code）"
  - JSON 解析错 → "更新信息格式异常"
  - 其他 → `error.localizedDescription`

## 9. UpdateCoordinator 状态机

```swift
@Observable @MainActor
final class UpdateCoordinator {
    enum Presentation: Equatable {
        case hidden
        case newVersion(VersionInfo)
        case latest(currentVersion: String)
        case error(message: String)
    }
    private(set) var presentation: Presentation = .hidden

    /// 启动后调，内部延迟 + 静默
    func checkOnLaunch() async { ... }

    /// 菜单手动触发，错误显示
    func checkManually() async { ... }

    /// Sheet 按钮回调
    func download() { ... }
    func skipThisVersion() { ... }
    func dismiss() { ... }
}
```

`checkOnLaunch`:
1. `try? await Task.sleep(for: .seconds(3))`
2. `guard let info = try? await VersionChecker.fetch(url: UpdateConfig.manifestURL) else { return }`
3. `guard VersionChecker.isNewer(remote: info.latest, than: Self.currentVersion) else { return }`
4. `guard UpdateMemory.skippedVersion != info.latest else { return }`
5. `presentation = .newVersion(info)`

`checkManually`:
1. `do { let info = try await VersionChecker.fetch(...) } catch { presentation = .error(...) ; return }`
2. `if VersionChecker.isNewer(...) { presentation = .newVersion(info) }`
3. `else { presentation = .latest(currentVersion: Self.currentVersion) }`

`Self.currentVersion`:
```swift
static var currentVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
}
```

## 10. 菜单位置

macOS 标准：App menu 第一段（在 "关于 SSHKeeper" 下方、"设置…" 上方）。SwiftUI 用 `CommandGroup(after: .appInfo)` 注入。

```swift
struct UpdateCommands: Commands {
    @FocusedValue(\.updateCoordinator) private var coordinator: UpdateCoordinator?
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                Task { await coordinator?.checkManually() }
            }
            .disabled(coordinator == nil)
        }
    }
}
```

## 11. 测试

### 11.1 单元测试（SSHKeeperTests）

`VersionCheckerTests`:
- `compare("1.0.0", "1.0.1")` == .orderedAscending
- `compare("1.0.10", "1.0.2")` == .orderedDescending（注意 10 > 2）
- `compare("1.0", "1.0.0")` == .orderedSame（补段）
- `compare("1.0.0", "1.0.0")` == .orderedSame
- `compare("1.0.0-beta", "1.0.0")` 走 fallback；具体方向看 localizedStandardCompare 实现，断 `!= .orderedSame`
- `isNewer(remote: "1.0.1", than: "1.0.0")` == true
- `isNewer(remote: "1.0.0", than: "1.0.0")` == false

`VersionInfoTests`:
- 解析完整 JSON → 字段对
- 缺 `latest` → throw
- 缺 `downloadUrl` → throw
- 缺 `releaseNotes` → 用默认空字符串（不算错；let UI 显示"无说明"）—— 设计决策：releaseNotes 必填 → 缺则 throw
- JSON 是数组 / 非对象 → throw

`UpdateMemoryTests`:
- get / set / 不同版本号
- clear

### 11.2 手动验证

1. 部署 `web/version.json`（latest: 1.0.1），启动 App（当前 1.0.0）→ 3s 后弹 sheet
2. Sheet 显示当前 1.0.0 / 最新 1.0.1 / release notes
3. 点"下载" → 默认浏览器打开 `https://sshkeeper.feilian.cc/SSHKeeper-1.0.1.dmg`
4. 点"稍后" → sheet 关，重启 App → 3s 后再弹
5. 点"跳过此版本" → sheet 关，重启 App → 不弹；菜单"检查更新…"仍能弹
6. 把 version.json 改成 latest: 1.0.0（与当前同） → 菜单"检查更新…" → 弹"已是最新版本"
7. 把 version.json 改成无效 JSON → 启动检查静默；菜单触发 → 弹错误
8. server 不可达（关闭 web server） → 启动检查静默；菜单触发 → 弹"无法访问更新服务器"

## 12. 风险

| 风险 | 缓解 |
|---|---|
| 域名 sshkeeper.feilian.cc 暂未上线 | 启动检查全静默，无负面体验；上线 + version.json 部署后自动生效 |
| 用户跳过版本后即使更新更新仍隐藏 | 菜单"检查更新…"无视跳过记忆 |
| version.json 字段误写（如 downloadUrl 拼错） | 解析阶段尽量宽松（必填字段缺 → 错误处理；多余字段 → 忽略） |
| 公司防火墙挡 sshkeeper.feilian.cc | 启动静默 + 菜单手动报错；用户可手工去 web/index.html 下载 |
| 用户离线启动 N 次 → 累积"跳过"或"稍后" | 不影响；菜单仍可触发；网络恢复后自动检查 |

## 13. 部署步骤（你的发版工作流）

1. 跑 `Tools/build_release.sh` 产 `SSHKeeper.dmg`
2. 改名 `SSHKeeper-1.0.1.dmg`，丢到 `web/`
3. 改 `project.yml` 的 `MARKETING_VERSION: "1.0.1"`、`CURRENT_PROJECT_VERSION: "2"`
4. 改 `web/index.html` 下载链接 → `SSHKeeper-1.0.1.dmg`
5. 创建 / 更新 `web/version.json`：

```json
{
  "latest": "1.0.1",
  "downloadUrl": "https://sshkeeper.feilian.cc/SSHKeeper-1.0.1.dmg",
  "releaseNotes": "..."
}
```

6. `rsync web/ → server`
7. 旧版本用户启动后 3s 自动收到提示
