import AppKit
import SwiftUI
import MarkdownEngine

enum MarkdownCommand: CaseIterable, Identifiable, Hashable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    case quote
    case unorderedList
    case orderedList
    case todoList

    var id: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .inlineCode: return "inlineCode"
        case .link: return "link"
        case .quote: return "quote"
        case .unorderedList: return "unorderedList"
        case .orderedList: return "orderedList"
        case .todoList: return "todoList"
        }
    }

    var help: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .inlineCode: return "Inline code"
        case .link: return "Link"
        case .quote: return "Quote"
        case .unorderedList: return "Bulleted list"
        case .orderedList: return "Numbered list"
        case .todoList: return "Todo list"
        }
    }
}

@MainActor
final class EditorInteractionState: ObservableObject {
    @Published private(set) var isDraggingSelection = false
    @Published private(set) var activeInlineCommands: Set<MarkdownCommand> = []
    @Published private(set) var mixedInlineCommands: Set<MarkdownCommand> = []
    var onSelectionChange: ((NSRange) -> Void)?

    private weak var textView: NSTextView?
    private weak var observedSelectionTextView: NSTextView?
    private var selectionObserver: NSObjectProtocol?
    private var didStartInEditor = false
    private var pendingFocus = false
    private var pendingSelectionRange: NSRange?
    private var focusAttemptsRemaining = 0
    private var layoutRefreshGeneration = 0
    private var selectionRestoreGeneration = 0

    func bind(containerView: NSView?, textView: NSTextView?) {
        if let textView {
            self.textView = textView
            observeSelectionChanges(in: textView)
            applyPendingSelectionRestore()
            refreshFormattingState()
        }

        if pendingFocus {
            focusEditor()
        }
    }

    func requestFocus(searchingIn rootView: NSView?) {
        refreshTextView(searchingIn: rootView)
        pendingFocus = true
        focusAttemptsRemaining = 8

        retryFocus(searchingIn: rootView)
    }

    func resetSelectionToDocumentStart(searchingIn rootView: NSView? = nil) {
        restoreSelection(NSRange(location: 0, length: 0), searchingIn: rootView)
    }

    func restoreSelection(
        _ range: NSRange,
        searchingIn rootView: NSView? = nil,
        reveal: Bool = true
    ) {
        pendingSelectionRange = range
        if let rootView {
            refreshTextView(searchingIn: rootView)
        }

        selectionRestoreGeneration += 1
        let generation = selectionRestoreGeneration
        scheduleSelectionRestore(
            range: range,
            generation: generation,
            remainingPasses: 4,
            searchingIn: rootView,
            reveal: reveal
        )
    }

    func requestLayoutRefresh(searchingIn rootView: NSView? = nil, resetScroll: Bool = false) {
        if let rootView {
            refreshTextView(searchingIn: rootView)
        }

        layoutRefreshGeneration += 1
        let generation = layoutRefreshGeneration
        scheduleLayoutRefresh(generation: generation, remainingPasses: 4, searchingIn: rootView, resetScroll: resetScroll)
    }

    func currentSelectionRange() -> NSRange? {
        guard let textView else { return nil }
        return safeSelectedRange(in: textView)
    }

    func applyMarkdownCommand(_ command: MarkdownCommand) {
        guard let textView else { return }

        focusEditor()

        let inlineStyle: MarkdownFormatting.InlineStyle?
        switch command {
        case .bold: inlineStyle = .bold
        case .italic: inlineStyle = .italic
        case .strikethrough: inlineStyle = .strikethrough
        case .inlineCode: inlineStyle = .code
        default: inlineStyle = nil
        }
        if let inlineStyle, MarkdownFormatting.apply(inlineStyle, in: textView) {
            refreshFormattingState()
            requestLayoutRefresh()
            return
        }
        let blockStyle: MarkdownFormatting.BlockStyle?
        switch command {
        case .quote: blockStyle = .quote
        case .unorderedList: blockStyle = .unorderedList
        case .orderedList: blockStyle = .orderedList
        case .todoList: blockStyle = .taskList
        default: blockStyle = nil
        }
        if let blockStyle, MarkdownFormatting.applyBlock(blockStyle, in: textView) {
            requestLayoutRefresh()
            return
        }

        switch command {
        case .bold:
            applyInlineFormatting(.bold, marker: "**", placeholder: "bold", in: textView)
        case .italic:
            applyInlineFormatting(.italic, marker: "*", placeholder: "italic", in: textView)
        case .strikethrough:
            applyInlineFormatting(.strikethrough, marker: "~~", placeholder: "strikethrough", in: textView)
        case .inlineCode:
            applyInlineFormatting(.code, marker: "`", placeholder: "code", in: textView)
        case .link:
            applyLink(in: textView)
        case .quote:
            prefixSelectedLines(with: "> ", in: textView)
        case .unorderedList:
            prefixSelectedLines(with: "- ", in: textView)
        case .orderedList:
            prefixSelectedLines(in: textView) { index in "\(index + 1). " }
        case .todoList:
            prefixSelectedLines(with: "- [ ] ", in: textView)
        }

        requestLayoutRefresh()
    }

    func handleMouseEvent(_ event: NSEvent, searchingIn rootView: NSView?) {
        switch event.type {
        case .leftMouseDown:
            refreshTextView(searchingIn: rootView)
            didStartInEditor = contains(event)
            isDraggingSelection = false
            if didStartInEditor {
                focusEditor()
            }
        case .leftMouseDragged:
            noteMouseDragged()
        case .leftMouseUp:
            resetDragState()
        default:
            break
        }
    }

    func noteGlobalMouseDragged() {
        noteMouseDragged()
    }

    func noteGlobalMouseUp() {
        resetDragState()
    }

    private func noteMouseDragged() {
        guard didStartInEditor else { return }
        isDraggingSelection = true
    }

    private func focusEditor() {
        guard let textView else {
            return
        }

        pendingFocus = false
        focusAttemptsRemaining = 0
        NSApp.activate(ignoringOtherApps: true)
        textView.window?.makeKeyAndOrderFront(nil)
        textView.window?.makeFirstResponder(textView)
    }

    private func observeSelectionChanges(in textView: NSTextView) {
        guard observedSelectionTextView !== textView else { return }

        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }

        observedSelectionTextView = textView
        selectionObserver = NotificationCenter.default.addObserver(
            forName: nil,
            object: textView,
            queue: .main
        ) { [weak self] notification in
            guard [NSTextView.didChangeSelectionNotification, NSText.didChangeNotification,
                   MarkdownFormatting.didChangeNotification].contains(notification.name) else { return }
            Task { @MainActor in
                guard let self, let range = self.currentSelectionRange() else { return }
                self.refreshFormattingState()
                self.onSelectionChange?(range)
            }
        }
    }

    private func refreshFormattingState() {
        guard let textView else { return }
        let styles: [(MarkdownCommand, MarkdownFormatting.InlineStyle)] = [
            (.bold, .bold), (.italic, .italic), (.strikethrough, .strikethrough), (.inlineCode, .code)
        ]
        var active = Set<MarkdownCommand>(), mixed = Set<MarkdownCommand>()
        let states = MarkdownFormatting.selectionStates(in: textView)
        for (command, style) in styles {
            switch states[style] ?? .off {
            case .on: active.insert(command)
            case .mixed: mixed.insert(command)
            case .off: break
            }
        }
        if activeInlineCommands != active { activeInlineCommands = active }
        if mixedInlineCommands != mixed { mixedInlineCommands = mixed }
    }

    private func applyPendingSelectionRestore() {
        guard let pendingSelectionRange else { return }
        applySelection(pendingSelectionRange, reveal: false)
    }

    private func wrapSelection(prefix: String, suffix: String, placeholder: String, in textView: NSTextView) {
        let range = safeSelectedRange(in: textView)
        let selectedText = (textView.string as NSString).substring(with: range)
        let content = selectedText.isEmpty ? placeholder : selectedText
        let replacement = prefix + content + suffix
        let selection = NSRange(location: range.location + prefix.utf16.count, length: content.utf16.count)
        replaceText(in: textView, range: range, with: replacement, selectionAfter: selection)
    }

    private func applyInlineFormatting(_ style: MarkdownFormatting.InlineStyle, marker: String,
                                       placeholder: String, in textView: NSTextView) {
        let range = safeSelectedRange(in: textView)
        guard range.length > 0 else {
            wrapSelection(prefix: marker, suffix: marker, placeholder: placeholder, in: textView)
            return
        }
        let source = textView.string as NSString
        let selected = source.substring(with: range)
        guard MarkdownFormatting.canFormat(range, in: textView.string, style: style) else { return }
        // The previous command leaves the content selected, excluding markers.
        if let span = MarkdownFormatting.spans(in: textView.string, style: style).first(where: { $0.contentRange == range }) {
            replaceText(in: textView, range: span.range,
                         with: selected, selectionAfter: NSRange(location: span.range.location, length: range.length))
            return
        }

        // A delimiter next to whitespace (or across a newline) is not a valid
        // inline token. Wrap each nonempty line's content, keeping whitespace
        // outside the delimiters and preserving blank lines verbatim.
        let lines = selected.components(separatedBy: "\n")
        let contents = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func isWrapped(_ content: String) -> Bool {
            MarkdownFormatting.spans(in: content, style: style)
                .contains { $0.range == NSRange(location: 0, length: content.utf16.count) }
        }
        let nonempty = contents.filter { !$0.isEmpty }
        guard !nonempty.isEmpty else { return }
        let removing = nonempty.allSatisfy(isWrapped)
        let replacement = zip(lines, contents).map { line, content -> String in
            guard !content.isEmpty else { return line }
            let nsLine = line as NSString
            let bodyRange = nsLine.range(of: content)
            let body: String
            if removing {
                let span = MarkdownFormatting.spans(in: content, style: style).first { $0.range.length == content.utf16.count }!
                body = (content as NSString).substring(with: span.contentRange)
            } else {
                let normalized = NSMutableString(string: content)
                // Merge complete spans rather than nesting delimiters.
                let markers = MarkdownFormatting.spans(in: content, style: style).flatMap(\.markerRanges)
                for range in Set(markers).sorted(by: { $0.location > $1.location }) {
                    normalized.deleteCharacters(in: range)
                }
                body = marker + (normalized as String) + marker
            }
            return nsLine.replacingCharacters(in: bodyRange, with: body)
        }.joined(separator: "\n")
        let selection: NSRange
        if lines.count == 1 {
            let content = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyRange = (replacement as NSString).range(of: content)
            let markerLength = isWrapped(content) ? marker.utf16.count : 0
            selection = NSRange(location: range.location + bodyRange.location + markerLength,
                                length: bodyRange.length - markerLength * 2)
        } else {
            selection = NSRange(location: range.location, length: replacement.utf16.count)
        }
        replaceText(in: textView, range: range, with: replacement, selectionAfter: selection)
    }

    private func applyLink(in textView: NSTextView) {
        let range = safeSelectedRange(in: textView)
        let selectedText = (textView.string as NSString).substring(with: range)
        let label = selectedText.isEmpty ? "link text" : selectedText
        let replacement = "[\(label)](url)"
        let selection: NSRange

        if selectedText.isEmpty {
            selection = NSRange(location: range.location + 1, length: label.utf16.count)
        } else {
            selection = NSRange(location: range.location + label.utf16.count + 3, length: 3)
        }

        replaceText(in: textView, range: range, with: replacement, selectionAfter: selection)
    }

    private func prefixSelectedLines(with prefix: String, in textView: NSTextView) {
        prefixSelectedLines(in: textView) { _ in prefix }
    }

    private func prefixSelectedLines(in textView: NSTextView, prefixForLine: (Int) -> String) {
        let nsString = textView.string as NSString
        let selectedRange = safeSelectedRange(in: textView)
        let lineRange = nsString.lineRange(for: selectedRange)
        let original = nsString.substring(with: lineRange)
        let hasTrailingNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")

        if hasTrailingNewline {
            lines.removeLast()
        }

        if lines.isEmpty {
            lines = [""]
        }

        let replacementBody = lines.enumerated()
            .map { index, line in prefixForLine(index) + line }
            .joined(separator: "\n")
        let replacement = replacementBody + (hasTrailingNewline ? "\n" : "")
        let selection = NSRange(location: lineRange.location, length: replacement.utf16.count)
        replaceText(in: textView, range: lineRange, with: replacement, selectionAfter: selection)
    }

    private func replaceText(in textView: NSTextView, range: NSRange, with replacement: String, selectionAfter: NSRange) {
        MarkdownFormatting.replaceSource(in: textView, range: range, with: replacement, selectionAfter: selectionAfter)
    }

    private func safeSelectedRange(in textView: NSTextView) -> NSRange {
        let fullLength = (textView.string as NSString).length
        let selectedRange = textView.selectedRange()
        let location = min(max(selectedRange.location, 0), fullLength)
        let length = min(max(selectedRange.length, 0), fullLength - location)
        return NSRange(location: location, length: length)
    }

    private func scheduleSelectionRestore(
        range: NSRange,
        generation: Int,
        remainingPasses: Int,
        searchingIn rootView: NSView?,
        reveal: Bool
    ) {
        let delay: TimeInterval = remainingPasses == 4 ? 0.02 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak rootView] in
            guard let self, self.selectionRestoreGeneration == generation else { return }
            if let rootView {
                self.refreshTextView(searchingIn: rootView)
            }
            self.applySelection(range, reveal: reveal && remainingPasses == 1)

            guard remainingPasses > 1 else {
                self.pendingSelectionRange = nil
                return
            }

            self.scheduleSelectionRestore(
                range: range,
                generation: generation,
                remainingPasses: remainingPasses - 1,
                searchingIn: rootView,
                reveal: reveal
            )
        }
    }

    private func applySelection(_ range: NSRange, reveal: Bool) {
        guard let textView else { return }
        let safeRange = clampedRange(range, in: textView)
        let preservedScrollOrigin = reveal
            ? nil
            : textView.enclosingScrollView?.contentView.bounds.origin
        textView.setSelectedRange(safeRange)
        if reveal {
            textView.scrollRangeToVisible(safeRange)
        } else if let scrollView = textView.enclosingScrollView,
                  let preservedScrollOrigin {
            scrollView.contentView.scroll(to: preservedScrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func clampedRange(_ range: NSRange, in textView: NSTextView) -> NSRange {
        let fullLength = (textView.string as NSString).length
        let location = min(max(range.location, 0), fullLength)
        let length = min(max(range.length, 0), fullLength - location)
        return NSRange(location: location, length: length)
    }

    private func scheduleLayoutRefresh(
        generation: Int,
        remainingPasses: Int,
        searchingIn rootView: NSView?,
        resetScroll: Bool
    ) {
        let delay: TimeInterval = remainingPasses == 4 ? 0.02 : 0.06
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak rootView] in
            guard let self, self.layoutRefreshGeneration == generation else { return }
            if let rootView {
                self.refreshTextView(searchingIn: rootView)
            }
            self.applyLayoutRefresh(resetScroll: resetScroll && remainingPasses == 4)

            guard remainingPasses > 1 else { return }
            self.scheduleLayoutRefresh(
                generation: generation,
                remainingPasses: remainingPasses - 1,
                searchingIn: rootView,
                resetScroll: false
            )
        }
    }

    private func applyLayoutRefresh(resetScroll: Bool) {
        guard let textView else { return }

        textView.layoutSubtreeIfNeeded()

        if let textLayoutManager = textView.textLayoutManager {
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)

            let documentEnd = textLayoutManager.documentRange.endLocation
            textLayoutManager.ensureLayout(for: NSTextRange(location: documentEnd))
        }

        if let scrollView = textView.enclosingScrollView {
            if resetScroll {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            scrollView.layoutSubtreeIfNeeded()
            scrollView.contentView.needsDisplay = true
        }

        textView.needsDisplay = true
        textView.setNeedsDisplay(textView.visibleRect)
        textView.window?.displayIfNeeded()
    }

    private func retryFocus(searchingIn rootView: NSView?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak rootView] in
            guard let self, self.pendingFocus else { return }
            self.refreshTextView(searchingIn: rootView)

            if self.textView != nil {
                self.focusEditor()
                return
            }

            self.focusAttemptsRemaining -= 1
            guard self.focusAttemptsRemaining > 0 else {
                self.pendingFocus = false
                return
            }

            self.retryFocus(searchingIn: rootView)
        }
    }

    private func refreshTextView(searchingIn rootView: NSView?) {
        guard let rootView,
              let freshTextView = rootView.firstDescendant(ofType: NSTextView.self) else {
            return
        }

        textView = freshTextView
    }

    private func resetDragState() {
        didStartInEditor = false
        isDraggingSelection = false
    }

    private func contains(_ event: NSEvent) -> Bool {
        guard let textView,
              let window = textView.window,
              event.window === window else {
            return false
        }

        let location = textView.convert(event.locationInWindow, from: nil)
        return textView.bounds.contains(location)
    }

}

struct EditorFocusBinder: NSViewRepresentable {
    let state: EditorInteractionState

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        bind(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        bind(from: view)
    }

    private func bind(from view: NSView) {
        DispatchQueue.main.async {
            let container = view.superview
            let textView = container?.firstDescendant(ofType: NSTextView.self)
                ?? view.firstAncestorDescendant(ofType: NSTextView.self)
            state.bind(containerView: container, textView: textView)
        }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }

        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }

        return nil
    }

    func firstAncestorDescendant<T: NSView>(ofType type: T.Type) -> T? {
        var current: NSView? = self

        while let view = current {
            if let match = view.firstDescendant(ofType: type) {
                return match
            }
            current = view.superview
        }

        return nil
    }
}
