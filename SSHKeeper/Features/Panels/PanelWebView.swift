import SwiftUI
import WebKit
import SSHKeeperCore

struct PanelWebView: NSViewRepresentable {
    // macOS 12+ 起 WKWebView 已自动跨实例复用 web content process，
    // 但 URLCache 仍由我们调大，覆盖整个 App 的 HTTP 缓存。
    @MainActor static let cacheConfigured: Void = {
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024
        )
    }()

    let panel: Panel
    let password: String
    let onTitleChange: (String) -> Void
    let onStatusChange: (PanelLoginStatus) -> Void
    let onProgressChange: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            username: panel.username,
            password: password,
            kind: panel.kind,
            onTitleChange: onTitleChange,
            onStatusChange: onStatusChange,
            onProgressChange: onProgressChange
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        _ = Self.cacheConfigured

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.suppressesIncrementalRendering = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // 注册 JS → Swift 回调通道，让页面里的 MutationObserver 在找到表单时通知我们
        config.userContentController.add(context.coordinator, name: "sshkeeper")

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        // Allow right-click → "Inspect Element" via Safari Web Inspector for debugging.
        if #available(macOS 13.3, *) {
            view.isInspectable = true
        }
        // 监听加载进度，给 UI 一个细的进度条
        context.coordinator.attachProgressObservation(to: view)
        if let url = URL(string: panel.url) {
            view.load(URLRequest(url: url))
        } else {
            onStatusChange(.error("URL 无效：\(panel.url)"))
        }
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.detachProgressObservation()
        coordinator.cancelRetries()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "sshkeeper")
        nsView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let username: String
        let password: String
        let kind: PanelKind
        let onTitleChange: (String) -> Void
        let onStatusChange: (PanelLoginStatus) -> Void
        let onProgressChange: (Double) -> Void
        var hasAutoFilled = false

        private var progressObservation: NSKeyValueObservation?

        init(
            username: String,
            password: String,
            kind: PanelKind,
            onTitleChange: @escaping (String) -> Void,
            onStatusChange: @escaping (PanelLoginStatus) -> Void,
            onProgressChange: @escaping (Double) -> Void
        ) {
            self.username = username
            self.password = password
            self.kind = kind
            self.onTitleChange = onTitleChange
            self.onStatusChange = onStatusChange
            self.onProgressChange = onProgressChange
        }

        func attachProgressObservation(to webView: WKWebView) {
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                guard let self, let value = change.newValue else { return }
                Task { @MainActor in self.onProgressChange(value) }
            }
        }

        func detachProgressObservation() {
            progressObservation?.invalidate()
            progressObservation = nil
        }

        func cancelRetries() {
            // 旧的 Swift 端 retry task 已移除（改成 JS 内部 MutationObserver 自驱动）
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onStatusChange(.loading)
            onProgressChange(0.05)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            onStatusChange(.error("导航失败：\((error as NSError).localizedDescription)"))
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            onStatusChange(.error("加载失败：\((error as NSError).localizedDescription)"))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let title = webView.title, !title.isEmpty {
                onTitleChange(title)
            }
            onProgressChange(1.0)
            // 宝塔等 SPA 面板的登录表单可能在 didFinish 之后好几秒才被 JS 渲染出来。
            // 注入一段会自我重试 + MutationObserver 监听 DOM 的脚本，找到表单立刻填，
            // 通过 webkit.messageHandlers.sshkeeper 回报状态。
            let js = LoginInjection.script(username: username, password: password)
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: - JS → Swift 回调
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "sshkeeper" else { return }
            let body = message.body as? [String: Any]
            let status = (body?["status"] as? String) ?? "unknown"
            switch status {
            case "submitted":
                hasAutoFilled = true
                onStatusChange(.submitted)
            case "no_button":
                onStatusChange(.filledNoButton)
            case "timeout":
                if !hasAutoFilled {
                    onStatusChange(.noForm)
                }
            default:
                break
            }
        }

        // 信任自签证书（宝塔常用 https + 自签）
        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.performDefaultHandling, nil)
        }

        // 让 target=_blank 的链接在同窗口打开
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

enum PanelLoginStatus: Equatable {
    case loading
    case submitted
    case filledNoButton
    case noForm
    case error(String)
}

private enum LoginInjection {
    /// 这段脚本：
    /// 1. 立即检查一次表单
    /// 2. 找到 → 填 + 提交 → postMessage('submitted') → 自我清理停止
    /// 3. 没找到 → 装 MutationObserver 持续监听 DOM；新元素出现就再试一次
    /// 4. 30 秒兜底超时 → postMessage('timeout')
    /// 5. 一次成功后用 window 标志位防重复填
    static func script(username: String, password: String) -> String {
        let u = jsString(username)
        let p = jsString(password)
        return """
        (function() {
          if (window.__sshkeeperInjected) {
            // 已经装过观察器，直接重试一次（用于 SPA 路由切回登录页）
            window.__sshkeeperTry && window.__sshkeeperTry();
            return;
          }
          window.__sshkeeperInjected = true;

          function notify(status) {
            try {
              window.webkit.messageHandlers.sshkeeper.postMessage({ status: status });
            } catch (e) {}
          }

          function findUser() {
            return document.querySelector('input[name="username"]')
              || document.querySelector('#username')
              || document.querySelector('input[autocomplete="username"]')
              || (function() {
                   var inputs = Array.from(document.querySelectorAll('input'));
                   return inputs.find(function(el) {
                     var t = (el.type || 'text').toLowerCase();
                     return t === 'text' || t === 'email';
                   });
                 })();
          }
          function findPass() {
            return document.querySelector('input[name="password"]')
              || document.querySelector('#password')
              || document.querySelector('input[type="password"]');
          }
          function setNative(el, value) {
            try {
              var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
              setter.call(el, value);
            } catch (e) {
              el.value = value;
            }
          }
          function fire(el, type) {
            el.dispatchEvent(new Event(type, { bubbles: true, cancelable: true }));
          }

          var observer = null;
          var timeoutId = null;
          var done = false;

          function cleanup() {
            done = true;
            if (observer) { observer.disconnect(); observer = null; }
            if (timeoutId) { clearTimeout(timeoutId); timeoutId = null; }
          }

          function tryFill() {
            if (done) return false;
            var u = findUser(), p = findPass();
            if (!u || !p) return false;
            setNative(u, \(u));
            setNative(p, \(p));
            ['input', 'change', 'blur'].forEach(function(t){ fire(u, t); fire(p, t); });
            var btn = document.querySelector('button[type="submit"]')
              || document.querySelector('input[type="submit"]')
              || document.querySelector('.login-btn')
              || document.querySelector('.btn-success')
              || document.querySelector('.el-button--primary')
              || document.querySelector('form button')
              || document.querySelector('button');
            if (btn) {
              try { btn.click(); } catch(e) {}
              cleanup();
              notify('submitted');
              return true;
            }
            var form = u.closest('form') || p.closest('form');
            if (form) {
              try { form.submit(); cleanup(); notify('submitted'); return true; } catch(e) {}
            }
            cleanup();
            notify('no_button');
            return true;
          }

          window.__sshkeeperTry = tryFill;

          if (tryFill()) return;

          // 表单还没渲染：装 observer 等
          if (document.body) {
            observer = new MutationObserver(function() { tryFill(); });
            observer.observe(document.body, { childList: true, subtree: true });
          }
          // 30 秒兜底：再没出来就报 timeout
          timeoutId = setTimeout(function() {
            if (done) return;
            cleanup();
            notify('timeout');
          }, 30000);
        })();
        """
    }

    private static func jsString(_ s: String) -> String {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(s)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}
