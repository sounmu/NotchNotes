import Foundation
import AppKit

/// Formatting ranges shared by editor commands and the renderer.
public enum MarkdownFormatting {
    public enum SelectionState { case off, on, mixed }
    public static let didChangeNotification = Notification.Name("MarkdownEngine.formattingDidChange")

    public static func selectionState(_ style: InlineStyle, in view: NSTextView) -> SelectionState {
        selectionStates(in: view)[style] ?? .off
    }

    public static func selectionStates(in view: NSTextView) -> [InlineStyle: SelectionState] {
        let range = view.selectedRange()
        if range.length == 0 {
            let coordinator = view.delegate as? NativeTextViewCoordinator
            let styles = coordinator?.formattedTypingState?.styles(in: view)
                ?? MarkdownFormattedEditing.styles(at: range.location, in: view.string,
                    tokens: coordinator?.parsedDocument(for: view.string).tokens)
            return Dictionary(uniqueKeysWithValues: InlineStyle.allCases.map { ($0, styles.contains($0) ? .on : .off) })
        }
        return MarkdownFormattedEditing.selectionStates(in: view.string, range: range)
    }
    public static func visibleText(in source: String) -> String {
        let result = NSMutableString(string: source)
        let tokens = MarkdownTokenizer.parseTokens(in: source)
        var hidden = IndexSet()
        for range in MarkdownInlineEditing.hiddenMarkerRanges(in: source, tokens: tokens) {
            hidden.insert(integersIn: range.location..<NSMaxRange(range))
        }
        for run in hidden.rangeView.reversed() { result.deleteCharacters(in: NSRange(run)) }
        return result as String
    }
    /// Apply an explicit Markdown command without reinterpreting its source
    /// replacement as a user's visible-text edit. Native undo still records it.
    @discardableResult
    public static func replaceSource(in textView: NSTextView, range: NSRange,
                                     with text: String, selectionAfter: NSRange) -> Bool {
        guard textView.isEditable, !textView.hasMarkedText(),
              range.location != NSNotFound, NSMaxRange(range) <= (textView.string as NSString).length else { return false }
        let coordinator = textView.delegate as? NativeTextViewCoordinator
        let wasProgrammatic = coordinator?.isProgrammaticEdit ?? false
        coordinator?.isProgrammaticEdit = true
        defer { coordinator?.isProgrammaticEdit = wasProgrammatic }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: text) else { return false }
        coordinator?.pendingEditedRange = NSRange(location: range.location, length: text.utf16.count)
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        textView.setSelectedRange(selectionAfter)
        textView.breakUndoCoalescing()
        return true
    }

    public enum InlineStyle: Hashable, CaseIterable {
        case bold, italic, strikethrough, code
    }

    /// Formatted-mode commands edit visible content, or arm the next insertion.
    /// Returning false leaves the upstream live-preview command path in charge.
    @discardableResult
    public static func apply(_ style: InlineStyle, in textView: NSTextView) -> Bool {
        guard let coordinator = textView.delegate as? NativeTextViewCoordinator,
              coordinator.configuration.inlineEditingMode == .formatted else { return false }
        defer { NotificationCenter.default.post(name: didChangeNotification, object: textView) }
        guard textView.isEditable, !textView.hasMarkedText(),
              !coordinator.isWritingToolsActive,
              textView.undoManager?.isUndoing != true,
              textView.undoManager?.isRedoing != true else { return true }
        let range = textView.selectedRange()
        if MarkdownDetection.isInsideCodeContext(location: range.location, in: textView.string),
           !spans(in: textView.string, style: .code).contains(where: {
               range.location >= $0.contentRange.location && range.location <= NSMaxRange($0.contentRange)
           }) { return true }
        if range.length == 0 {
            var styles = coordinator.formattedTypingState?.styles(in: textView)
                ?? MarkdownFormattedEditing.styles(at: range.location, in: textView.string)
            if style != .code && styles.contains(.code) { return true }
            if styles.contains(style) { styles.remove(style) } else { styles.insert(style) }
            coordinator.formattedTypingState = .init(source: textView.string, caret: range.location, styles: styles)
            textView.breakUndoCoalescing()
            coordinator.updateSelectionStates(textView)
        } else if let edit = MarkdownFormattedEditing.toggle(style, in: textView.string, range: range) {
            coordinator.formattedTypingState = nil
            replaceSource(in: textView, range: edit.range, with: edit.replacement, selectionAfter: edit.selection)
        }
        return true
    }

    public struct Span {
        public let range: NSRange
        public let contentRange: NSRange
        public let markerRanges: [NSRange]
    }

    public static func spans(in text: String, style: InlineStyle) -> [Span] {
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let code = tokens.filter { $0.kind == .codeBlock || (style != .code && $0.kind == .inlineCode) }
        return tokens.filter { token in
            let matches: Bool
            switch style {
            case .bold: matches = token.kind == .bold
            case .italic: matches = token.kind == .italic
            case .strikethrough: matches = token.kind == .strikethrough
            case .code: matches = token.kind == .inlineCode
            }
            return matches && !code.contains { NSIntersectionRange($0.range, token.range) == token.range }
        }.map { Span(range: $0.range, contentRange: $0.contentRange, markerRanges: $0.markerRanges) }
    }

    /// Do not rewrite a fragment of a delimiter pair or format inside code.
    public static func canFormat(_ selection: NSRange, in text: String, style: InlineStyle) -> Bool {
        for token in MarkdownTokenizer.parseTokens(in: text) {
            guard NSIntersectionRange(selection, token.range).length > 0 else { continue }
            if token.kind == .codeBlock { return false }
            if token.kind == .inlineCode && style != .code { return false }
            if token.markerRanges.contains(where: { NSIntersectionRange(selection, $0).length > 0 }),
               NSIntersectionRange(selection, token.range) != token.range {
                return false
            }
        }
        return !spans(in: text, style: style).contains {
            NSIntersectionRange(selection, $0.range).length > 0
                && NSIntersectionRange(selection, $0.range) != $0.range
                && selection != $0.contentRange
        }
    }

    public static func strikethroughContentRanges(in text: String) -> [NSRange] {
        spans(in: text, style: .strikethrough).map(\.contentRange)
    }
}
