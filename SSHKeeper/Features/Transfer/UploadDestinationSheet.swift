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
