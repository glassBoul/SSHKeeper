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
