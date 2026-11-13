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
        // ServerAliveInterval=30 + CountMax=4：ssh 每 30s 发一次心跳，4 次无响应才断 = 2 分钟容忍。
        // 防 NAT 超时 / 服务端 ClientAliveInterval 把空闲 session 踢掉。大文件上传时 terminal 闲置，
        // 没心跳的话 server / NAT 会关 channel，session 显示 exited。
        terminal.startProcess(
            executable: "/usr/bin/ssh",
            args: [
                "-tt",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=4",
                alias
            ],
            environment: envArray
        )

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
}
