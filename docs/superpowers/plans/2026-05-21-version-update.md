# Version Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App 启动后静默 + 菜单"检查更新…"手动两条路径，从 `https://sshkeeper.feilian.cc/version.json` 拉新版本元信息，发现新版则弹 sheet 显示 release notes + 跳转浏览器下载 DMG。

**Architecture:** SSHKeeperCore 放纯逻辑（VersionInfo / VersionChecker / UpdateConfig），可单测。SSHKeeper app target 放 UI 与状态机（UpdateMemory / UpdateCoordinator / UpdateSheet / UpdateCommands）。App 启动后 3s 延迟检查；菜单 `CommandGroup(after: .appInfo)` 注入"检查更新…"。

**Tech Stack:** Swift 6（strict concurrency）、SwiftUI macOS 14、Foundation URLSession、AppKit NSWorkspace、XCTest。零新依赖。

**Repository note:** 当前工作目录非 git 仓库；不做 `git commit`。每个 Task 末尾用 build + test 通过作为里程碑。

**Reference spec:** `docs/superpowers/specs/2026-05-21-version-update-design.md`

**Build/Verify 模板：**

```bash
cd .
xcodegen generate >/dev/null
xcodebuild build -project SSHKeeper.xcodeproj -scheme SSHKeeper -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: exit 0.

**Test 模板：**

```bash
cd .
xcodebuild test -project SSHKeeper.xcodeproj -scheme SSHKeeper -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -20
```

Expected: `Test Suite 'All tests' passed`（或行尾 `** TEST SUCCEEDED **`）。

---

## File Structure（新增 / 修改）

**新增 (SSHKeeperCore)：**

| 文件 | 职责 |
|---|---|
| `SSHKeeperCore/Features/Updates/VersionInfo.swift` | `struct VersionInfo: Codable, Sendable, Equatable` + `static parse(_ data: Data) throws -> VersionInfo` |
| `SSHKeeperCore/Features/Updates/UpdateConfig.swift` | `enum UpdateConfig` 常量：manifestURL / launchCheckDelay / fetchTimeout |
| `SSHKeeperCore/Features/Updates/VersionChecker.swift` | 纯函数：`compare(_:_:)` / `isNewer(remote:than:)`；`static func fetch(url:) async throws -> VersionInfo` |

**新增 (SSHKeeper)：**

| 文件 | 职责 |
|---|---|
| `SSHKeeper/Features/Updates/UpdateMemory.swift` | `enum UpdateMemory` 用 UserDefaults 存 skippedVersion |
| `SSHKeeper/Features/Updates/UpdateCoordinator.swift` | `@Observable @MainActor` 状态机 + `checkOnLaunch / checkManually / download / skipThisVersion / dismiss` |
| `SSHKeeper/Features/Updates/UpdateSheet.swift` | SwiftUI sheet UI（3 态 newVersion / latest / error） |
| `SSHKeeper/Features/Updates/UpdateCommands.swift` | `FocusedValues.updateCoordinator` + `CommandGroup(after: .appInfo)` 注入"检查更新…" |

**新增 (SSHKeeperTests)：**

| 文件 | 职责 |
|---|---|
| `SSHKeeperTests/VersionInfoTests.swift` | parse 单测 |
| `SSHKeeperTests/VersionCheckerTests.swift` | compare / isNewer 单测 |

**修改：**

| 文件 | 改动 |
|---|---|
| `SSHKeeper/App/SSHKeeperApp.swift` | 注入 UpdateCoordinator / focusedSceneValue / `.commands { UpdateCommands() }` / WindowGroup root `.task` 调 checkOnLaunch |
| `SSHKeeper/App/MainView.swift` | `@Environment(UpdateCoordinator.self)` + sheet 路由 |

---

### Task 1: `VersionInfo` 数据模型 + parse + 单测

**Files:**
- Create: `SSHKeeperCore/Features/Updates/VersionInfo.swift`
- Create: `SSHKeeperTests/VersionInfoTests.swift`

- [ ] **Step 1: 创建目录**

```bash
mkdir -p ./SSHKeeperCore/Features/Updates
```

- [ ] **Step 2: 先写失败测试**

Create `./SSHKeeperTests/VersionInfoTests.swift`:

```swift
import XCTest
@testable import SSHKeeperCore

final class VersionInfoTests: XCTestCase {
    func testParseFullJSON() throws {
        let json = """
        {
          "latest": "1.0.1",
          "downloadUrl": "https://sshkeeper.feilian.cc/SSHKeeper-1.0.1.dmg",
          "releaseNotes": "- 修了 X\\n- 加了 Y"
        }
        """.data(using: .utf8)!
        let info = try VersionInfo.parse(json)
        XCTAssertEqual(info.latest, "1.0.1")
        XCTAssertEqual(info.downloadUrl.absoluteString, "https://sshkeeper.feilian.cc/SSHKeeper-1.0.1.dmg")
        XCTAssertEqual(info.releaseNotes, "- 修了 X\n- 加了 Y")
    }

    func testParseRejectsMissingLatest() {
        let json = """
        { "downloadUrl": "https://x/y.dmg", "releaseNotes": "" }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try VersionInfo.parse(json))
    }

    func testParseRejectsMissingDownloadUrl() {
        let json = """
        { "latest": "1.0.1", "releaseNotes": "" }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try VersionInfo.parse(json))
    }

    func testParseRejectsMissingReleaseNotes() {
        let json = """
        { "latest": "1.0.1", "downloadUrl": "https://x/y.dmg" }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try VersionInfo.parse(json))
    }

    func testParseRejectsInvalidDownloadUrl() {
        let json = """
        { "latest": "1.0.1", "downloadUrl": "not a url ::", "releaseNotes": "" }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try VersionInfo.parse(json))
    }

    func testParseRejectsNonObject() {
        let json = "[\"a\", \"b\"]".data(using: .utf8)!
        XCTAssertThrowsError(try VersionInfo.parse(json))
    }

    func testParseIgnoresExtraFields() throws {
        let json = """
        {
          "latest": "1.0.1",
          "downloadUrl": "https://x/y.dmg",
          "releaseNotes": "ok",
          "publishedAt": "2026-05-21T10:00:00Z",
          "minimum": "1.0.0"
        }
        """.data(using: .utf8)!
        let info = try VersionInfo.parse(json)
        XCTAssertEqual(info.latest, "1.0.1")
    }
}
```

- [ ] **Step 3: 运行测试验证失败**

```bash
cd . && xcodegen generate >/dev/null
xcodebuild test -project SSHKeeper.xcodeproj -scheme SSHKeeper -destination 'platform=macOS,arch=arm64' -only-testing:SSHKeeperTests/VersionInfoTests -quiet 2>&1 | tail -10
```

Expected: 编译失败（`VersionInfo` 未定义）。

- [ ] **Step 4: 写最小实现**

Create `./SSHKeeperCore/Features/Updates/VersionInfo.swift`:

```swift
import Foundation

/// 版本元信息，从远端 version.json 解析得到。
/// 字段必须全部存在；多余字段忽略以便未来扩展（minimum / publishedAt / sha256）。
public struct VersionInfo: Codable, Sendable, Equatable {
    public let latest: String
    public let downloadUrl: URL
    public let releaseNotes: String

    public init(latest: String, downloadUrl: URL, releaseNotes: String) {
        self.latest = latest
        self.downloadUrl = downloadUrl
        self.releaseNotes = releaseNotes
    }

    /// 解析 JSON 数据。失败 throw `VersionInfoError` 或 Codable 原生错误。
    public static func parse(_ data: Data) throws -> VersionInfo {
        let decoder = JSONDecoder()
        return try decoder.decode(VersionInfo.self, from: data)
    }
}

public enum VersionInfoError: Error, LocalizedError {
    case invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return "更新信息格式异常: \(msg)"
        }
    }
}
```

> Codable 默认对必填字段缺失 / URL 解析失败都会 throw，所以不需要手写 `init(from:)`。

- [ ] **Step 5: 运行测试验证通过**

```bash
xcodebuild test -project SSHKeeper.xcodeproj -scheme SSHKeeper -destination 'platform=macOS,arch=arm64' -only-testing:SSHKeeperTests/VersionInfoTests -quiet 2>&1 | tail -10
```

Expected: `Test Suite 'VersionInfoTests' passed`。所有 7 个测试 PASS。

---

### Task 2: `VersionChecker` 版本比较 + isNewer + 单测

**Files:**
- Create: `SSHKeeperCore/Features/Updates/VersionChecker.swift`
- Create: `SSHKeeperTests/VersionCheckerTests.swift`

- [ ] **Step 1: 写失败测试**

Create `./SSHKeeperTests/VersionCheckerTests.swift`:

```swift
import XCTest
@testable import SSHKeeperCore

final class VersionCheckerTests: XCTestCase {

    // MARK: compare

    func testCompareEqual() {
        XCTAssertEqual(VersionChecker.compare("1.0.0", "1.0.0"), .orderedSame)
    }

    func testCompareMinorAscending() {
        XCTAssertEqual(VersionChecker.compare("1.0.0", "1.0.1"), .orderedAscending)
    }

    func testCompareMajorDescending() {
        XCTAssertEqual(VersionChecker.compare("2.0.0", "1.99.99"), .orderedDescending)
    }

    func testCompareDoubleDigitPatch() {
        // 1.0.10 > 1.0.2 数字比较，不是字典序
        XCTAssertEqual(VersionChecker.compare("1.0.10", "1.0.2"), .orderedDescending)
    }

    func testComparePadShorter() {
        // 1.0 == 1.0.0（短的补 0）
        XCTAssertEqual(VersionChecker.compare("1.0", "1.0.0"), .orderedSame)
    }

    func testComparePadShorterAscending() {
        // 1.0 < 1.0.1
        XCTAssertEqual(VersionChecker.compare("1.0", "1.0.1"), .orderedAscending)
    }

    func testCompareNonNumericFallback() {
        // 任一段非数字 → fallback localizedStandardCompare；至少不等
        XCTAssertNotEqual(VersionChecker.compare("1.0.0-beta", "1.0.0"), .orderedSame)
    }

    // MARK: isNewer

    func testIsNewerTrue() {
        XCTAssertTrue(VersionChecker.isNewer(remote: "1.0.1", than: "1.0.0"))
    }

    func testIsNewerFalseWhenSame() {
        XCTAssertFalse(VersionChecker.isNewer(remote: "1.0.0", than: "1.0.0"))
    }

    func testIsNewerFalseWhenOlder() {
        XCTAssertFalse(VersionChecker.isNewer(remote: "0.9.9", than: "1.0.0"))
    }
}
```

- [ ] **Step 2: 运行验证失败**

```bash
xcodebuild test -project SSHKeeper.xcodeproj -scheme SSHKeeper -destination 'platform=macOS,arch=arm64' -only-testing:SSHKeeperTests/VersionCheckerTests -quiet 2>&1 | tail -10
```

Expected: 编译失败（`VersionChecker` 未定义）。

- [ ] **Step 3: 写最小实现（仅 compare + isNewer，fetch 下个 Task 加）**

Create `./SSHKeeperCore/Features/Updates/VersionChecker.swift`:

```swift
import Foundation

/// 版本检查：比较 + 远端拉取。所有方法 static / 无状态。
public enum VersionChecker {

    /// 比较两个语义化版本字符串：按 `.` 分段比 Int；短的补 0；
    /// 任一段非数字（如 `1.0.0-beta`）→ fallback `localizedStandardCompare`。
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").map { Int($0) ?? -1 }
        let bParts = b.split(separator: ".").map { Int($0) ?? -1 }
        // 任一段非数字 → fallback
        if aParts.contains(-1) || bParts.contains(-1) {
            return a.localizedStandardCompare(b)
        }
        let maxLen = max(aParts.count, bParts.count)
        for i in 0..<maxLen {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    /// remote 比 local 更新返回 true。
    public static func isNewer(remote: String, than local: String) -> Bool {
        compare(remote, local) == .orderedDescending
    }
}
```

- [ ] **Step 4: 运行验证通过**

```bash
xcodebuild test -project SSHKeeper.xcodeproj -scheme SSHKeeper -destination 'platform=macOS,arch=arm64' -only-testing:SSHKeeperTests/VersionCheckerTests -quiet 2>&1 | tail -10
```

Expected: 10 个 case 全 PASS。

---

### Task 3: `UpdateConfig` + `VersionChecker.fetch`

**Files:**
- Create: `SSHKeeperCore/Features/Updates/UpdateConfig.swift`
- Modify: `SSHKeeperCore/Features/Updates/VersionChecker.swift`（追加 `fetch`）

- [ ] **Step 1: 创建 UpdateConfig.swift**

Create `./SSHKeeperCore/Features/Updates/UpdateConfig.swift`:

```swift
import Foundation

/// 版本更新相关配置常量。集中放此处便于将来改 host / 调时长。
public enum UpdateConfig {
    /// 远端 version.json URL（与 DMG 同目录托管）。
    public static let manifestURL: URL = URL(string: "https://sshkeeper.feilian.cc/version.json")!
    /// App 启动后延迟多久才发起检查（秒），避免阻塞冷启动。
    public static let launchCheckDelay: TimeInterval = 3.0
    /// URLSession 请求超时（秒）。
    public static let fetchTimeout: TimeInterval = 8.0
}
```

- [ ] **Step 2: 给 VersionChecker 追加 fetch**

打开 `./SSHKeeperCore/Features/Updates/VersionChecker.swift`。在 `public static func isNewer(...) -> Bool` 后追加：

```swift
    /// 从 URL 拉 version.json 并解析。
    /// 网络 / 状态码 / 解析失败都抛错；调用方决定如何展示。
    public static func fetch(url: URL = UpdateConfig.manifestURL) async throws -> VersionInfo {
        var request = URLRequest(url: url)
        request.timeoutInterval = UpdateConfig.fetchTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VersionCheckError.httpStatus(http.statusCode)
        }
        return try VersionInfo.parse(data)
    }
}

public enum VersionCheckError: Error, LocalizedError {
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "更新服务器返回错误（HTTP \(code)）"
        }
    }
}
```

> 注意原文件末尾的 `}` 是 `enum VersionChecker` 的关闭；上面 `fetch` 函数体内的 `}` 之后再 `}` 关闭 enum；然后才是 `public enum VersionCheckError`。逐字添加，不删除现有内容。

- [ ] **Step 3: 验证编译 + 现有测试不破**

```bash
cd .
xcodegen generate >/dev/null
xcodebuild build -project SSHKeeper.xcodeproj -scheme SSHKeeper -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: exit 0。

```bash
xcodebuild test -project SSHKeeper.xcodeproj -scheme SSHKeeper -destination 'platform=macOS,arch=arm64' -only-testing:SSHKeeperTests/VersionCheckerTests -only-testing:SSHKeeperTests/VersionInfoTests -quiet 2>&1 | tail -10
```

Expected: 全部 PASS（17 个 case）。

> 不为 `fetch` 写单测：依赖网络 + 真实 URL；手动验证阶段（Task 10）走完整链路。

---

### Task 4: `UpdateMemory` UserDefaults 包装

**Files:**
- Create: `SSHKeeper/Features/Updates/UpdateMemory.swift`

- [ ] **Step 1: 创建目录 + 文件**

```bash
mkdir -p ./SSHKeeper/Features/Updates
```

Create `./SSHKeeper/Features/Updates/UpdateMemory.swift`:

```swift
import Foundation

/// 持久化用户对版本更新的偏好：当前只记一个"跳过的版本号"。
/// 用户在更新弹窗点"跳过此版本" → 写入；启动检查命中相同 latest 时不再弹（菜单手动触发仍弹）。
enum UpdateMemory {
    private static let skippedVersionKey = "updateSkippedVersion.v1"

    static var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: skippedVersionKey) }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: skippedVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: skippedVersionKey)
            }
        }
    }
}
```

- [ ] **Step 2: 验证编译**

```bash
cd .
xcodegen generate >/dev/null
xcodebuild build -project SSHKeeper.xcodeproj -scheme SSHKeeper -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: exit 0。

---

### Task 5: `UpdateCoordinator` 状态机

**Files:**
- Create: `SSHKeeper/Features/Updates/UpdateCoordinator.swift`

- [ ] **Step 1: 创建文件**

Create `./SSHKeeper/Features/Updates/UpdateCoordinator.swift`:

```swift
import Foundation
import AppKit
import Observation
import OSLog
import SSHKeeperCore

/// 版本更新协调者：拉 version.json + 维护弹窗状态 + 处理按钮回调。
/// 启动检查走静默路径（所有错误吞）；菜单手动触发走错误显示路径。
@Observable
@MainActor
final class UpdateCoordinator {

    /// Sheet 的呈现态。`hidden` 不弹；其余三个对应 spec §5 的三种 sheet。
    enum Presentation: Equatable {
        case hidden
        case newVersion(VersionInfo)
        case latest(currentVersion: String)
        case error(message: String)
    }

    private(set) var presentation: Presentation = .hidden

    private let log = Logger(subsystem: "com.sshkeeper.app", category: "update")

    /// 本机 App 版本（CFBundleShortVersionString）；fallback "0.0.0" 避免 nil。
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// App 启动后调（自带 3s 延迟）。所有失败静默，不打扰用户。
    /// 命中 skippedVersion 不弹。
    func checkOnLaunch() async {
        try? await Task.sleep(for: .seconds(UpdateConfig.launchCheckDelay))
        do {
            let info = try await VersionChecker.fetch()
            guard VersionChecker.isNewer(remote: info.latest, than: Self.currentVersion) else {
                log.info("启动检查：当前已是最新（local=\(Self.currentVersion, privacy: .public)）")
                return
            }
            if UpdateMemory.skippedVersion == info.latest {
                log.info("启动检查：用户已跳过版本 \(info.latest, privacy: .public)")
                return
            }
            presentation = .newVersion(info)
        } catch {
            log.error("启动检查失败（静默）：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 菜单"检查更新…"调；错误转人话弹错误 sheet。
    func checkManually() async {
        do {
            let info = try await VersionChecker.fetch()
            if VersionChecker.isNewer(remote: info.latest, than: Self.currentVersion) {
                presentation = .newVersion(info)
            } else {
                presentation = .latest(currentVersion: Self.currentVersion)
            }
        } catch {
            presentation = .error(message: Self.localizedFetchError(error))
        }
    }

    /// Sheet "下载" 按钮：调系统浏览器打开 DMG URL，sheet 关。
    func download() {
        if case .newVersion(let info) = presentation {
            NSWorkspace.shared.open(info.downloadUrl)
        }
        presentation = .hidden
    }

    /// "跳过此版本" 按钮：记当前 latest，sheet 关；下次启动同版本不再弹。
    func skipThisVersion() {
        if case .newVersion(let info) = presentation {
            UpdateMemory.skippedVersion = info.latest
        }
        presentation = .hidden
    }

    /// "稍后" / Esc / "好" 按钮：sheet 关，不记跳过。
    func dismiss() {
        presentation = .hidden
    }

    /// 把 URLSession / VersionChecker 抛的错误翻译成中文展示。
    private static func localizedFetchError(_ error: Error) -> String {
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .notConnectedToInternet: return "网络未连接"
            case .timedOut: return "请求超时"
            case .cannotFindHost, .dnsLookupFailed: return "无法访问更新服务器"
            case .cannotConnectToHost: return "无法连接更新服务器"
            default: return urlErr.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
```

- [ ] **Step 2: 验证编译**

```bash
xcodebuild build -project SSHKeeper.xcodeproj -scheme SSHKeeper -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: exit 0。

---

### Task 6: `UpdateSheet` SwiftUI UI

**Files:**
- Create: `SSHKeeper/Features/Updates/UpdateSheet.swift`

- [ ] **Step 1: 创建文件**

Create `./SSHKeeper/Features/Updates/UpdateSheet.swift`:

```swift
import SwiftUI
import SSHKeeperCore

/// 更新弹窗。根据 coordinator.presentation 切换 3 种内容。
struct UpdateSheet: View {
    let presentation: UpdateCoordinator.Presentation
    let onDownload: () -> Void
    let onSkip: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Group {
            switch presentation {
            case .hidden:
                EmptyView()  // 实际不渲染；sheet 路由层用 isPresented 决定
            case .newVersion(let info):
                newVersionView(info: info)
            case .latest(let current):
                latestView(currentVersion: current)
            case .error(let msg):
                errorView(message: msg)
            }
        }
        .frame(minWidth: 460, idealWidth: 520)
    }

    private func newVersionView(info: VersionInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("发现新版本")
                        .font(.headline)
                    Text("当前 \(UpdateCoordinator.currentVersion) → 最新 \(info.latest)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("更新说明")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(info.releaseNotes)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
            }

            HStack {
                Button("跳过此版本") { onSkip() }
                Spacer()
                Button("稍后") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("下载") { onDownload() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private func latestView(currentVersion: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text("已是最新版本")
                .font(.headline)
            Text("当前版本：\(currentVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("好") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text("无法获取更新信息")
                    .font(.headline)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("好") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}
```

- [ ] **Step 2: 验证编译**

```bash
xcodebuild build -project SSHKeeper.xcodeproj -scheme SSHKeeper -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: exit 0。

---

### Task 7: `UpdateCommands` ⌘ 菜单"检查更新…"

**Files:**
- Create: `SSHKeeper/Features/Updates/UpdateCommands.swift`

- [ ] **Step 1: 创建文件**

Create `./SSHKeeper/Features/Updates/UpdateCommands.swift`:

```swift
import SwiftUI

/// FocusedValues 注入 UpdateCoordinator，让 Commands 能拿到当前 scene 的实例。
struct FocusedUpdateCoordinatorKey: FocusedValueKey {
    typealias Value = UpdateCoordinator
}

extension FocusedValues {
    var updateCoordinator: UpdateCoordinator? {
        get { self[FocusedUpdateCoordinatorKey.self] }
        set { self[FocusedUpdateCoordinatorKey.self] = newValue }
    }
}

/// App menu 的"检查更新…"，放在"关于 SSHKeeper"下方（macOS 标准位置）。
struct UpdateCommands: Commands {
    @FocusedValue(\.updateCoordinator) private var coordinator: UpdateCoordinator?

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                guard let coordinator else { return }
                Task { await coordinator.checkManually() }
            }
            .disabled(coordinator == nil)
        }
    }
}
```

- [ ] **Step 2: 验证编译**

```bash
xcodebuild build -project SSHKeeper.xcodeproj -scheme SSHKeeper -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: exit 0。

---

### Task 8: 把 UpdateCoordinator 接入 `SSHKeeperApp`

**Files:**
- Modify: `SSHKeeper/App/SSHKeeperApp.swift`

- [ ] **Step 1: 加 `@State` 字段**

打开 `SSHKeeper/App/SSHKeeperApp.swift`。定位 `@State` 字段块（在 `struct SSHKeeperApp: App {` 内，找到 `transferEngine` / `uploadCoordinator` 那几行；这是上次 SSH 上传 plan 加过的）。

在 `uploadCoordinator` 字段下面追加：

```swift
    @State private var uploadCoordinator: UploadCoordinator
    @State private var updateCoordinator: UpdateCoordinator = UpdateCoordinator()
```

> `UpdateCoordinator()` 无依赖，可用默认初始化。

- [ ] **Step 2: WindowGroup body 注入 environment + focusedSceneValue + 启动 task**

定位 `WindowGroup("SSHKeeper") { MainView() ... }` 块。当前应该已经链了一堆 `.environment(...)` 和 2 个 `.focusedSceneValue`。在 `.environment(uploadCoordinator)` 后插入 1 个 environment，在 `.focusedSceneValue(\.uploadCoordinator, uploadCoordinator)` 后插入 1 个：

```swift
                .environment(uploadCoordinator)
                .environment(updateCoordinator)
                .focusedSceneValue(\.sessionEngine, sessionEngine)
                .focusedSceneValue(\.uploadCoordinator, uploadCoordinator)
                .focusedSceneValue(\.updateCoordinator, updateCoordinator)
```

在 `MainView()` 的 `.task { ... }` 块内（现有 `.task { appDelegate.sidecar = sidecar; store.load(); ... }`）末尾追加启动检查（用独立 Task，避免阻塞已有 startup 逻辑）：

```swift
                .task {
                    appDelegate.sidecar = sidecar
                    store.load()
                    panelStore.load()
                    databaseStore.load()
                    Task { await updateCoordinator.checkOnLaunch() }
                }
```

- [ ] **Step 3: commands 加 UpdateCommands**

定位 `.commands { ... }` 块（应已有 `SessionCommands()` + `UploadCommands()`）。追加：

```swift
        .commands {
            SessionCommands()
            UploadCommands()
            UpdateCommands()
        }
```

- [ ] **Step 4: 验证编译**

```bash
xcodebuild build -project SSHKeeper.xcodeproj -scheme SSHKeeper -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: exit 0。

---

### Task 9: `MainView` 加 sheet 路由

**Files:**
- Modify: `SSHKeeper/App/MainView.swift`

- [ ] **Step 1: 加 @Environment 字段**

打开 `SSHKeeper/App/MainView.swift`。定位 `@Environment` 字段块（顶部）。当前应有 `store / engine / sidecar / uploadCoordinator`。在 `uploadCoordinator` 下面追加：

```swift
    @Environment(UploadCoordinator.self) private var uploadCoordinator
    @Environment(UpdateCoordinator.self) private var updateCoordinator
```

- [ ] **Step 2: 在 body 末尾加 sheet 路由**

定位 body 内的 `.sheet(item: Binding(...)) { prompt in UploadDestinationSheet(...) }` 块（上次 SSH 上传 plan 加的）。在它**之后**追加：

```swift
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
```

- [ ] **Step 3: 验证编译**

```bash
xcodebuild build -project SSHKeeper.xcodeproj -scheme SSHKeeper -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
```

Expected: exit 0。

---

### Task 10: 手动验证全流程

**Files:** 无新改动。需要部署一个 `web/version.json` 用作 mock 源。

- [ ] **Step 1: 创建测试版 `web/version.json`**

Create `./web/version.json`:

```json
{
  "latest": "1.0.1",
  "downloadUrl": "https://sshkeeper.feilian.cc/SSHKeeper-1.0.1.dmg",
  "releaseNotes": "- 新增 SSH 文件上传\n- 数据库行内编辑\n- 加版本更新检查"
}
```

把 `web/` 同步到 `sshkeeper.feilian.cc`（用你的发布流程；如 rsync）。或者本地起 `python3 -m http.server 8080 -d ./web` 然后**临时**把 `UpdateConfig.manifestURL` 改成 `http://localhost:8080/version.json` 验证（验证完改回）。

> 如果 `sshkeeper.feilian.cc` 还没部署，可以**先用 `localhost` 验证流程跑通**，然后再改回正式 URL 部署。

- [ ] **Step 2: 跑测试**

```bash
cd .
xcodebuild test -project SSHKeeper.xcodeproj -scheme SSHKeeper -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -10
```

Expected: 全部 PASS（包括 VersionInfoTests / VersionCheckerTests 17 个新 case + 现有所有测试）。

- [ ] **Step 3: build + 重启 + 验证**

```bash
xcodebuild build -project SSHKeeper.xcodeproj -scheme SSHKeeper -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
pkill -x SSHKeeper 2>/dev/null
sleep 1
open ~/Library/Developer/Xcode/DerivedData/SSHKeeper-*/Build/Products/Debug/SSHKeeper.app
```

按 spec §11.2 逐项验证：

1. App 启动 → 等 3 秒 → 应弹更新 sheet（前提：version.json 已部署且 `latest: "1.0.1"`）
2. Sheet 显示当前 1.0.0 / 最新 1.0.1 / release notes 滚动可见
3. 点"下载" → 默认浏览器打开 `https://sshkeeper.feilian.cc/SSHKeeper-1.0.1.dmg`（即使该文件不存在也应弹出浏览器请求）
4. 点"稍后" → sheet 关闭；`pkill SSHKeeper && open ...` 重启 → 3 秒后再弹
5. 点"跳过此版本" → sheet 关；重启不再弹（启动路径）
6. 菜单 SSHKeeper → "检查更新…" → 即使跳过过也仍弹（菜单无视跳过）
7. 把 version.json 改成 `latest: "1.0.0"`（与本机同），同步部署；菜单"检查更新…" → 弹"已是最新版本"小提示
8. 把 version.json 改成无效内容（`{"foo":"bar"}`），同步部署；菜单"检查更新…" → 弹错误 sheet "无法获取更新信息：更新信息格式异常 ..." 类似
9. 关闭/暂停 web server；菜单"检查更新…" → 弹错误 sheet "无法连接更新服务器"
10. 启动时无网络（关闭 wifi）→ 不应弹任何 sheet（静默吞）

任一失败 → 记症状回报，我修。

全部通过 → 版本更新功能完成。最后清理 `web/version.json` 用正确版本号，部署到 `https://sshkeeper.feilian.cc/version.json`。
