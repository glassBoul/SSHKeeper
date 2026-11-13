import SwiftUI
import AppKit

struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedText: String
    var completionProvider: ((_ prefix: String, _ contextBefore: String) -> [String])? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            selectedText: $selectedText,
            completionProvider: completionProvider
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        textView.string = text
        if let storage = textView.textStorage {
            SQLHighlighter.apply(to: storage)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.completionProvider = completionProvider
        guard textView.string != text else { return }
        let selected = textView.selectedRange()
        textView.string = text
        if let storage = textView.textStorage {
            SQLHighlighter.apply(to: storage)
        }
        let newLen = (text as NSString).length
        if selected.location <= newLen {
            textView.setSelectedRange(NSRange(location: min(selected.location, newLen), length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let selectedText: Binding<String>
        var completionProvider: ((_ prefix: String, _ contextBefore: String) -> [String])?
        private var isApplyingHighlight = false
        private var suppressAutoComplete = false
        private var highlightTask: Task<Void, Never>?
        private var lastReportedSelection: String = ""

        init(
            text: Binding<String>,
            selectedText: Binding<String>,
            completionProvider: ((_ prefix: String, _ contextBefore: String) -> [String])?
        ) {
            self.text = text
            self.selectedText = selectedText
            self.completionProvider = completionProvider
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            // 无选区直接推空（且仅在上次也不是空时才推），避免每次光标移动都生成 substring
            guard range.length > 0 else {
                if !lastReportedSelection.isEmpty {
                    lastReportedSelection = ""
                    selectedText.wrappedValue = ""
                }
                return
            }
            let str = textView.string as NSString
            guard range.location >= 0,
                  range.location + range.length <= str.length else {
                return
            }
            let selected = str.substring(with: range)
            guard selected != lastReportedSelection else { return }
            lastReportedSelection = selected
            selectedText.wrappedValue = selected
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isApplyingHighlight else { return }

            let newValue = textView.string
            // 文本立即同步给 SwiftUI（用户输入不能延迟）
            text.wrappedValue = newValue

            // 高亮 debounce：120ms 内连续按键只在最后一次生效
            highlightTask?.cancel()
            let storage = textView.textStorage
            highlightTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                if Task.isCancelled { return }
                guard let self, let storage else { return }
                self.isApplyingHighlight = true
                SQLHighlighter.apply(to: storage)
                self.isApplyingHighlight = false
            }

            // 输入字母/数字/. 后自动弹补全（按 Esc 或方向键移动可关掉）
            guard !suppressAutoComplete else { suppressAutoComplete = false; return }
            if shouldAutoComplete(textView: textView) {
                textView.complete(nil)
            }
        }

        private func shouldAutoComplete(textView: NSTextView) -> Bool {
            let str = textView.string as NSString
            let cursor = textView.selectedRange().location
            guard cursor > 0, cursor <= str.length else { return false }
            let lastChar = str.character(at: cursor - 1)
            // 字母/数字/下划线/点号触发
            let isLetter = (lastChar >= 0x41 && lastChar <= 0x5A) || (lastChar >= 0x61 && lastChar <= 0x7A)
            let isDigit = lastChar >= 0x30 && lastChar <= 0x39
            let isUnderscore = lastChar == 0x5F
            let isDot = lastChar == 0x2E
            return isLetter || isDigit || isUnderscore || isDot
        }

        // Esc 关掉自动弹（NSTextView 自带，但确保下次输入不重新弹）
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                suppressAutoComplete = true
                return false
            case #selector(NSResponder.moveLeft(_:)),
                 #selector(NSResponder.moveRight(_:)),
                 #selector(NSResponder.moveUp(_:)),
                 #selector(NSResponder.moveDown(_:)):
                suppressAutoComplete = true
                return false
            case #selector(NSResponder.insertTab(_:)):
                // Tab 主动触发补全
                textView.complete(nil)
                return true
            default:
                return false
            }
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            guard let provider = completionProvider else { return words }
            let str = textView.string as NSString
            let prefix = str.substring(with: charRange)
            // 取前面 64 字符做上下文（识别 "tablename." 这种）
            let contextStart = max(0, charRange.location - 64)
            let contextRange = NSRange(location: contextStart, length: charRange.location - contextStart)
            let contextBefore = str.substring(with: contextRange)
            let candidates = provider(prefix, contextBefore)
            index?.pointee = -1   // 不预选
            return candidates
        }
    }
}
