import AppKit

extension NativeTextView {
    @objc func applyMarkdownBold(_ sender: Any?) { MarkdownFormatting.apply(.bold, in: self) }
    @objc func applyMarkdownItalic(_ sender: Any?) { MarkdownFormatting.apply(.italic, in: self) }

    override func deleteWordBackward(_ sender: Any?) {
        if !deleteFormattedWord(backward: true) { super.deleteWordBackward(sender) }
    }

    override func deleteWordForward(_ sender: Any?) {
        if !deleteFormattedWord(backward: false) { super.deleteWordForward(sender) }
    }

    private func deleteFormattedWord(backward: Bool) -> Bool {
        guard configuration.inlineEditingMode == .formatted, isEditable, !hasMarkedText(),
              selectedRange().length == 0 else { return false }
        let tokens = MarkdownTokenizer.parseTokens(in: string)
        var hidden = IndexSet()
        for range in MarkdownInlineEditing.hiddenMarkerRanges(in: string, tokens: tokens) {
            hidden.insert(integersIn: range.location..<NSMaxRange(range))
        }
        guard !hidden.isEmpty else { return false }
        let visible = NSMutableString(string: string)
        for run in hidden.rangeView.reversed() { visible.deleteCharacters(in: NSRange(run)) }
        // Let AppKit choose language-aware word boundaries on displayed text.
        let proxy = NSTextView(frame: .zero)
        proxy.string = visible as String
        let caret = selectedRange().location
        proxy.setSelectedRange(NSRange(location: caret - hidden.count(in: 0..<caret), length: 0))
        let oldCaret = proxy.selectedRange().location
        if backward { proxy.deleteWordBackward(nil) } else { proxy.deleteWordForward(nil) }
        let count = visible.length - proxy.string.utf16.count
        guard count > 0 else { return true }
        let start = backward ? proxy.selectedRange().location : oldCaret
        let offsets = (0..<string.utf16.count).filter { !hidden.contains($0) }
        let sourceStart = offsets[start]
        let sourceEnd = offsets[start + count - 1] + 1
        insertText("", replacementRange: NSRange(location: sourceStart, length: sourceEnd - sourceStart))
        return true
    }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard configuration.inlineEditingMode == .formatted,
              type == .string || type == .rtf,
              let storage = textStorage else { return super.writeSelection(to: pasteboard, type: type) }
        let selection = selectedRange()
        guard selection.location != NSNotFound, NSMaxRange(selection) <= storage.length else { return false }
        let visible = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: selection))
        var hidden = IndexSet()
        for marker in MarkdownInlineEditing.hiddenMarkerRanges(in: string, tokens: MarkdownTokenizer.parseTokens(in: string)) {
            let overlap = NSIntersectionRange(selection, marker)
            if overlap.length > 0 {
                hidden.insert(integersIn: (overlap.location - selection.location)..<(NSMaxRange(overlap) - selection.location))
            }
        }
        for range in hidden.rangeView.reversed() {
            visible.deleteCharacters(in: NSRange(location: range.lowerBound, length: range.count))
        }
        if type == .string { return pasteboard.setString(visible.string, forType: type) }
        guard let data = try? visible.data(from: NSRange(location: 0, length: visible.length),
                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return false }
        return pasteboard.setData(data, forType: type)
    }

    /// Snapshot typing intent before AppKit installs the first marked range.
    /// Subsequent syllable updates are exclusively owned by the input method.
    func captureFormattedCompositionIfNeeded(replacementRange: NSRange) {
        guard !hasMarkedText(), let coordinator = delegate as? NativeTextViewCoordinator,
              coordinator.configuration.inlineEditingMode == .formatted,
              !coordinator.isProgrammaticEdit, !coordinator.isWritingToolsActive,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true else { return }
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        coordinator.formattedCompositionStyles = coordinator.formattedTypingState?.styles(in: self)
            ?? MarkdownFormattedEditing.replacementStyles(in: self.string, range: range)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard hasMarkedText(), let coordinator = delegate as? NativeTextViewCoordinator,
              coordinator.configuration.inlineEditingMode == .formatted,
              !coordinator.isProgrammaticEdit, !coordinator.isWritingToolsActive,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true,
              let styles = coordinator.formattedCompositionStyles else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        coordinator.formattedCompositionStyles = nil
        let range = replacementRange.location == NSNotFound ? markedRange() : replacementRange
        let oldLength = self.string.utf16.count
        // Native commit and source-pair materialization form one undo step.
        let undo = undoManager
        undo?.beginUndoGrouping()
        coordinator.isProgrammaticEdit = true
        defer {
            coordinator.isProgrammaticEdit = false
            undo?.endUndoGrouping()
        }
        super.insertText(insertString, replacementRange: replacementRange)
        guard !hasMarkedText() else { return }
        let committedLength = self.string.utf16.count - oldLength + range.length
        guard range.location != NSNotFound, committedLength >= 0,
              range.location + committedLength <= self.string.utf16.count else { return }
        let committedRange = NSRange(location: range.location, length: committedLength)
        if committedLength > 0 {
            let committed = (self.string as NSString).substring(with: committedRange)
            if let edit = MarkdownFormattedEditing.insertion(in: self.string, range: committedRange,
                                                              replacement: committed, styles: styles) {
                super.insertText(edit.replacement, replacementRange: edit.range)
                setSelectedRange(edit.selection)
            }
        }
        coordinator.formattedTypingState = .init(source: self.string, caret: selectedRange().location, styles: styles)
    }

    override func unmarkText() {
        guard hasMarkedText(), let coordinator = delegate as? NativeTextViewCoordinator,
              coordinator.configuration.inlineEditingMode == .formatted,
              !coordinator.isProgrammaticEdit, !coordinator.isWritingToolsActive,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true,
              let styles = coordinator.formattedCompositionStyles else {
            super.unmarkText()
            return
        }
        let range = markedRange()
        coordinator.formattedCompositionStyles = nil
        coordinator.isProgrammaticEdit = true
        let undo = undoManager
        undo?.beginUndoGrouping()
        defer {
            coordinator.isProgrammaticEdit = false
            undo?.endUndoGrouping()
        }
        super.unmarkText()
        guard !hasMarkedText(), range.location != NSNotFound,
              NSMaxRange(range) <= self.string.utf16.count else { return }
        if range.length > 0 {
            let committed = (self.string as NSString).substring(with: range)
            if let edit = MarkdownFormattedEditing.insertion(in: self.string, range: range,
                                                              replacement: committed, styles: styles) {
                super.insertText(edit.replacement, replacementRange: edit.range)
                setSelectedRange(edit.selection)
            }
        }
        coordinator.formattedTypingState = .init(source: self.string, caret: selectedRange().location, styles: styles)
    }
}
