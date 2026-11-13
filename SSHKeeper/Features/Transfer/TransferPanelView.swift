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

            if let line = currentFileLine {
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if task.status.isRunning || task.status == .pending {
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                Text(statsText)
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

    /// 文件名行：优先 scp 报告的子文件（目录递归时），fallback 顶层 item.lastPathComponent。
    private var currentFileLine: String? {
        if let sub = task.currentSubItem, !sub.isEmpty {
            // sub 已经是 scp 输出的相对路径（如 `ssl/foo.txt`），直接显示
            return sub
        }
        return task.currentItem?.lastPathComponent
    }

    /// 进度 + 速度行：`39.5 MB / 219.8 MB · 5.2 MB/s`。
    private var statsText: String {
        let prefix = "\(Self.formatBytes(task.transferredBytes)) / \(Self.formatBytes(task.totalBytes))"
        guard let speed = task.currentSpeedBytesPerSec, speed > 0 else { return prefix }
        return "\(prefix) · \(Self.formatBytes(speed))/s"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1024 / 1024) }
        return String(format: "%.2f GB", Double(bytes) / 1024 / 1024 / 1024)
    }
}
