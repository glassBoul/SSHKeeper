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
