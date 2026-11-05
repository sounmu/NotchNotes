//
//  NativeTextViewCoordinator+TextDelegate.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  The hot NSTextViewDelegate path: keystroke handling, selection-change
//  reaction, link-click forwarding, and the typing-attributes shim that
//  prevents AppKit from leaking heading paragraphStyle into the trailing
//  extra-line fragment. Restyle scoping (which paragraphs to re-tokenize on
//  each event) lives here too — it sets up the inputs that
//  `+Restyling.swift` then consumes.
//

import AppKit

extension NativeTextViewCoordinator {

    /// Force base typingAttributes on every change so AppKit's auto-inheritance
    /// can't bleed a heading paragraphStyle into the trailing extra-line
    /// fragment's metrics.
    public func textView(
        _ textView: NSTextView,
        shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
        toAttributes newTypingAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        let (baseFont, baseParagraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )
        var result = newTypingAttributes
        result[.paragraphStyle] = baseParagraphStyle
        result[.font] = baseFont
        result[.foregroundColor] = configuration.theme.bodyText
        return result
    }

    public func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        let wtActive = isWritingToolsActive
        if wtActive, wtDetectedMode == .unknown {
            let firstEditLen = tv.textStorage?.editedRange.length ?? 0
            if let sel = wtInitialSelectionRange, sel.length > 0 {
                let threshold = max(10, Int(Double(sel.length) * 0.6))
                wtDetectedMode = firstEditLen >= threshold ? .rewrite : .proofread
            } else {
                wtDetectedMode = .rewrite
            }
        }
        if wtActive && wtDetectedMode == .proofread { return }


        let rawSelRange = tv.selectedRange()
        let fullLength = (tv.string as NSString).length
        guard !tv.hasMarkedText() else { return }
        let safeLocation = min(rawSelRange.location, fullLength)
        let safeSelRange = NSRange(location: safeLocation, length: 0)
        previousCaretLocation = safeSelRange.location
        if !wtActive {
            let storageState = WikiLinkService.makeStorageState(
                from: tv.string,
                existingMetadata: self.wikiLinkMetadata,
                textStorage: tv.textStorage
            )
            self.wikiLinkMetadata = storageState.metadata
            // An earlier change may still be queued even when this value equals
            // lastSyncedText (type, then undo in the same event). Queue the final
            // snapshot too, and deduplicate against the captured binding at delivery.
            do {
                let binding = self.$text
                let editedDocumentID = self.documentId
                DispatchQueue.main.async {
                    if self.documentId == editedDocumentID {
                        self.lastSyncedText = storageState.storage
                    }
                    if binding.wrappedValue != storageState.storage {
                        binding.wrappedValue = storageState.storage
                    }
                }
            }
        }

        let fullText = tv.string as NSString
        let paragraphRange = fullText.paragraphRange(for: safeSelRange)
        let documentLength = fullText.length
        let nextLocation = min(documentLength, NSMaxRange(paragraphRange))
        let previousParagraph = paragraphRange.location > 0
            ? fullText.paragraphRange(for: NSRange(location: max(0, paragraphRange.location - 1), length: 0))
            : NSRange(location: NSNotFound, length: 0)
        let nextParagraph = nextLocation < documentLength
            ? fullText.paragraphRange(for: NSRange(location: nextLocation, length: 0))
            : NSRange(location: NSNotFound, length: 0)
        let editedRange = pendingEditedRange ?? tv.textStorage?.editedRange ?? safeSelRange
        pendingEditedRange = nil
        let wtEditedFallback: NSRange? = {
            guard wtActive, let sel = wtInitialSelectionRange else { return nil }
            let docLength = fullText.length
            let loc = min(sel.location, docLength)
            let len = min(sel.length, docLength - loc)
            return NSRange(location: loc, length: len)
        }()
        let safeEditedRange: NSRange = {
            if let wtRange = wtEditedFallback { return wtRange }
            return editedRange.location == NSNotFound ? safeSelRange : editedRange
        }()
        let editedParagraphs = paragraphRanges(in: fullText, intersecting: safeEditedRange)
        let paragraphCandidates: [NSRange] = [
            previousParagraph,
            paragraphRange,
            nextParagraph
        ] + editedParagraphs

        let backtickCount = tv.string.components(separatedBy: "```").count - 1
        let codeBlockStructureChanged = backtickCount != previousBacktickCount
        previousBacktickCount = backtickCount

        let parsed = parsedDocument(for: tv.string)
        let tokens = parsed.tokens
        let codeTokens = parsed.codeTokens
        let latexTokens = parsed.latexTokens
        let blockLatexTokens = parsed.blockLatexTokens
        let preEditActiveTokenIndices = pendingPreEditActiveTokenIndices ?? previousActiveTokenIndices
        pendingPreEditActiveTokenIndices = nil

        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: safeSelRange,
            tokens: tokens,
            in: fullText
        )
        filterImageEmbedActiveTokens(parsed: parsed, text: fullText, selectionLocation: safeSelRange.location)
        updateAutocorrectSettings(
            tv,
            caretLocation: safeSelRange.location,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            allTokens: tokens
        )

        var effectiveParagraphCandidates = paragraphCandidates
        if codeBlockStructureChanged {
            effectiveParagraphCandidates = [NSRange(location: 0, length: fullText.length)]
        }
        // Always restyle paragraphs containing latex/imageEmbed tokens to avoid stale raw text.
        let latexParagraphs = (latexTokens + blockLatexTokens + parsed.imageEmbedTokens).map { fullText.paragraphRange(for: $0.range) }
        effectiveParagraphCandidates.append(contentsOf: latexParagraphs)
        effectiveParagraphCandidates.append(contentsOf: tokenRestyleParagraphs(
            in: fullText,
            tokens: tokens,
            currentActiveTokenIndices: activeTokenIndices,
            previousActiveTokenIndices: preEditActiveTokenIndices
        ))

        restyleTextView(tv, paragraphCandidates: effectiveParagraphCandidates, tokens: tokens)
        updateCodeBlockSelection(textView: tv, tokens: tokens)
        if wtActive {
            previousActiveTokenIndices = activeTokenIndices
            return
        }
        if let bottomTextView = tv as? NativeTextView,
           let scrollView = tv.enclosingScrollView {
            bottomTextView.recalcOverscroll(for: scrollView, debugTag: "textDidChange")
            (scrollView as? ClampedScrollView)?.clampToInsets()
        }
        previousActiveTokenIndices = activeTokenIndices
    }

    public func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
                         toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
        guard !isProgrammaticEdit, !isWritingToolsActive, !textView.hasMarkedText(),
              textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true,
              configuration.inlineEditingMode == .formatted || MarkdownInlineEditing.navigationSteps[ObjectIdentifier(textView)] != nil else {
            return newSelectedCharRange
        }
        let characterStep = MarkdownInlineEditing.navigationSteps[ObjectIdentifier(textView)] ?? false
        return MarkdownInlineEditing.selection(in: textView.string as NSString, from: oldSelectedCharRange,
                                               to: newSelectedCharRange, tokens: parsedDocument(for: textView.string).tokens,
                                               characterStep: characterStep,
                                               formatted: configuration.inlineEditingMode == .formatted)
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        // Do not restyle while an IME (e.g. Korean) is composing; the marked
        // text owns the selection and must not be disturbed.
        guard !tv.hasMarkedText() else { return }
        if isWritingToolsActive { return }
        if !isProgrammaticEdit, formattedTypingState?.styles(in: tv) == nil {
            formattedTypingState = nil
        }
        let selRange = tv.selectedRange()
        let currentEventType = NSApp.currentEvent?.type
        // Mouse-/Wake-Fokus auf Link: kein Preview, erst Navigation. Gilt für alle Nicht-Key-Events.
        if currentEventType != .keyDown,
           selRange.location < (tv.string as NSString).length,
           tv.textStorage?.attribute(.link, at: selRange.location, effectiveRange: nil) != nil {
            isImageEmbedActive = false
            isWikiLinkActive = false
            onInlineSelectionChange?(nil)
            return
        }
        updateSelectionStates(tv)
        let selLoc = selRange.location

        let parsed = parsedDocument(for: tv.string)
        let tokens = parsed.tokens
        let codeTokens = parsed.codeTokens
        let latexTokens = parsed.latexTokens
        let blockLatexTokens = parsed.blockLatexTokens
        let nsText = tv.string as NSString

        let prevActive = activeTokenIndices
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(selectionRange: selRange, tokens: tokens, in: nsText)
        filterImageEmbedActiveTokens(parsed: parsed, text: nsText, selectionLocation: selRange.location)
        updateAutocorrectSettings(
            tv,
            caretLocation: selLoc,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            allTokens: tokens
        )
        let caretLoc = selRange.location
        let paragraphRange = nsText.paragraphRange(for: NSRange(location: caretLoc, length: 0))

        var paragraphCandidates: [NSRange] = [paragraphRange]
        if paragraphRange.length == 0 && caretLoc > 0 {
            paragraphCandidates.append(nsText.paragraphRange(for: NSRange(location: max(0, caretLoc - 1), length: 0)))
        }
        if let prevLoc = previousCaretLocation, prevLoc != caretLoc {
            let safePrev = min(prevLoc, nsText.length)
            let prevPara = nsText.paragraphRange(for: NSRange(location: safePrev, length: 0))
            paragraphCandidates.append(prevPara)
        }
        // Also restyle paragraphs containing latex/imageEmbed tokens to refresh rendering.
        let latexParagraphs = (latexTokens + blockLatexTokens + parsed.imageEmbedTokens).map { nsText.paragraphRange(for: $0.range) }
        paragraphCandidates.append(contentsOf: latexParagraphs)
        paragraphCandidates.append(contentsOf: tokenRestyleParagraphs(
            in: nsText,
            tokens: tokens,
            currentActiveTokenIndices: activeTokenIndices,
            previousActiveTokenIndices: previousActiveTokenIndices
        ))

        let shouldSkipSelectionRestyle = pendingEditedRange != nil
        let tokensChanged = activeTokenIndices != prevActive
        if shouldSkipSelectionRestyle {
            // textDidChange performs the pending restyle for this edit cycle.
        } else if tokensChanged {
            restyleTextView(tv, paragraphCandidates: paragraphCandidates, tokens: tokens)
        }

        // Auto-select content when clicking (mouse) into a rendered (previously inactive) latex or image embed
        if selRange.length == 0,
           let eventType = currentEventType,
           eventType == .leftMouseUp || eventType == .leftMouseDown {
            let newlyActive = activeTokenIndices.subtracting(previousActiveTokenIndices)
            for idx in newlyActive {
                let token = tokens[idx]
                guard token.kind == .inlineLatex
                    || token.kind == .blockLatex
                    || token.kind == .imageEmbed else {
                    continue
                }
                let selectRange = token.contentRange
                if selectRange.length > 0 {
                    tv.setSelectedRange(selectRange)
                    break
                }
            }
        }

        let nsString = tv.string as NSString
        let selLocation = tv.selectedRange().location
        let inlineContext = inlineTokenContext(
            at: selLocation,
            parsed: parsed,
            codeTokens: codeTokens,
            text: nsText
        )
        let isInsideImageEmbed = {
            guard case .imageEmbed = inlineContext else { return false }
            return true
        }()
        // Preview must only trigger inside the `![[…]]` content area
        let isInsideImageEmbedContent: Bool = {
            guard case .imageEmbed(let token) = inlineContext else { return false }
            let start = token.range.location + 3
            let end = NSMaxRange(token.range) - 2
            return selLocation >= start && selLocation <= end
        }()

        let isTyping = currentEventType == .keyDown
        let imageEmbedShowsInlinePreview = isInsideImageEmbedContent && isTyping
        var inlineSelectionState: InlineSelectionState? = nil
        if let inlineContext {
            let openingMarkerLength = inlineContext.selectionKind == .imageEmbed ? 3 : 2
            let displayRange = selectionDisplayRange(for: inlineContext.token, openingMarkerLength: openingMarkerLength)
            let placeholder = nsString.substring(with: displayRange)
            let storageRange = inlineContext.selectionKind == .wikiLink
                ? storageRange(containingDisplayLocation: selLocation) ?? storageRange(forDisplayRange: displayRange)
                : nil
            let previewRect = tv.viewRect(forCharacterRange: displayRange, using: layoutBridge)
                ?? tv.viewRect(forCharacterRange: tv.selectedRange(), using: layoutBridge)

            let shouldShowInlinePreview =
                inlineContext.selectionKind == .wikiLink
                || (inlineContext.selectionKind == .imageEmbed && imageEmbedShowsInlinePreview)
            if shouldShowInlinePreview, let previewRect {
                let selection = WikiLinkSelection(
                    displayRange: displayRange,
                    storageRange: storageRange,
                    placeholder: placeholder
                )
                inlineSelectionState = InlineSelectionState(kind: inlineContext.selectionKind, selection: selection)
                DispatchQueue.main.async {
                    self.onCaretRectChange?(previewRect)
                }
            }
        }

        DispatchQueue.main.async {
            self.isWikiLinkActive = inlineSelectionState?.kind == .wikiLink
            self.isImageEmbedActive = isInsideImageEmbed
            self.onInlineSelectionChange?(inlineSelectionState)
        }

        self.previousActiveTokenIndices = self.activeTokenIndices
        self.previousCaretLocation = caretLoc

        // Track code blocks for button overlay (reuse tokens)
        updateCodeBlockSelection(textView: tv, tokens: tokens)
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        observeEditingUndo(in: textView)
        if isProgrammaticEdit { return true }
        if isWritingToolsActive { return true }
        // Let the input method commit/replace marked text untouched.
        if textView.hasMarkedText() { return true }
        pendingEditedRange = NSRange(location: affectedCharRange.location, length: replacementString?.utf16.count ?? 0)
        let currentLen = (textView.string as NSString).length
        let maxR = affectedCharRange.location + affectedCharRange.length
        if affectedCharRange.location > currentLen || maxR > currentLen {
            pendingPreEditActiveTokenIndices = nil
            return false
        }
        if textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true {
            pendingPreEditActiveTokenIndices = nil
            return true
        }
        let parsed = parsedDocument(for: textView.string)
        if configuration.inlineEditingMode == .formatted, replacementString == "\t",
           !MarkdownLists.handleInsertion(textView: textView, affectedCharRange: affectedCharRange, replacementString: "\t") {
            return false
        }
        if configuration.inlineEditingMode == .formatted, replacementString == "\n",
           insertFormattedBreak(in: textView, range: affectedCharRange, hard: false) { return false }
        if configuration.inlineEditingMode == .formatted,
           let replacementString, !replacementString.isEmpty {
            let pending = affectedCharRange == textView.selectedRange() ? formattedTypingState?.styles(in: textView) : nil
            let styles = pending ?? MarkdownFormattedEditing.replacementStyles(in: textView.string, range: affectedCharRange, tokens: parsed.tokens)
            if pending != nil || !styles.isEmpty || (affectedCharRange.length > 0 &&
                MarkdownInlineEditing.formats(in: parsed.tokens).contains(where: {
                    NSIntersectionRange($0.range, affectedCharRange).length > 0
                })) {
                if let edit = MarkdownFormattedEditing.insertion(in: textView.string, range: affectedCharRange,
                                                                 replacement: replacementString, styles: styles, tokens: parsed.tokens) {
                    applyFormattedEdit(edit, to: textView, styles: styles)
                    return false
                }
            }
        }
        if let replacementString, affectedCharRange.length > 0 {
            var semanticRange = affectedCharRange
            let selection = textView.selectedRange()
            // Direct deleteBackward/deleteForward calls can bypass doCommandBy.
            let markers = configuration.inlineEditingMode == .formatted
                ? MarkdownInlineEditing.hiddenMarkerRanges(in: textView.string, tokens: parsed.tokens)
                : MarkdownInlineEditing.formats(in: parsed.tokens).flatMap(\.markerRanges)
            let touchesMarker = markers.contains { NSIntersectionRange($0, affectedCharRange).length > 0 }
            if replacementString.isEmpty && selection.length == 0 && touchesMarker
                && affectedCharRange.length == 1 {
                let backward = NSMaxRange(affectedCharRange) <= selection.location
                if let character = MarkdownInlineEditing.characterRange(
                    in: textView.string as NSString, at: selection.location,
                    backward: backward, tokens: parsed.tokens,
                    formatted: configuration.inlineEditingMode == .formatted
                ) {
                    semanticRange = character
                } else {
                    return false
                }
            }
            if let edit = MarkdownInlineEditing.edit(in: textView.string, range: semanticRange,
                                                      replacement: replacementString, tokens: parsed.tokens,
                                                      formatted: configuration.inlineEditingMode == .formatted) {
                applyInlineEdit(edit, to: textView)
                return false
            }
            if semanticRange != affectedCharRange {
                applyInlineEdit(.init(range: semanticRange, replacement: replacementString,
                                      caret: semanticRange.location + replacementString.utf16.count), to: textView)
                return false
            }
        }
        pendingPreEditActiveTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(),
            tokens: parsed.tokens,
            in: textView.string as NSString
        )

        // Block LaTeX auto-wrap: insert newlines to keep $$ on its own line
        if MarkdownInputHandler.handleBlockLatexAutoWrap(
            textView: textView,
            affectedCharRange: affectedCharRange,
            replacementString: replacementString,
            blockLatexTokens: parsed.blockLatexTokens
        ) {
            return false
        }

        if MarkdownInputHandler.handleImageEmbedAutoWrap(
            textView: textView,
            affectedCharRange: affectedCharRange,
            replacementString: replacementString,
            imageEmbedTokens: parsed.imageEmbedTokens
        ) {
            return false
        }

        return MarkdownInputHandler.handleListInsertion(textView: textView, affectedCharRange: affectedCharRange, replacementString: replacementString)
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if !isProgrammaticEdit && !isWritingToolsActive && !textView.hasMarkedText(),
           textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true,
           commandSelector == #selector(NSResponder.deleteBackward(_:))
            || commandSelector == #selector(NSResponder.deleteForward(_:)) {
            let tokens = parsedDocument(for: textView.string).tokens
            var range = textView.selectedRange()
            if range.length == 0 {
                guard let character = MarkdownInlineEditing.characterRange(
                    in: textView.string as NSString, at: range.location,
                    backward: commandSelector == #selector(NSResponder.deleteBackward(_:)), tokens: tokens,
                    formatted: configuration.inlineEditingMode == .formatted
                ) else { return true }
                range = character
            }
            if let edit = MarkdownInlineEditing.edit(in: textView.string, range: range, replacement: "", tokens: tokens,
                                                    formatted: configuration.inlineEditingMode == .formatted) {
                applyInlineEdit(edit, to: textView)
                return true
            }
            if textView.selectedRange().length == 0 {
                let caret = textView.selectedRange().location
                let expected = commandSelector == #selector(NSResponder.deleteBackward(_:)) ? NSMaxRange(range) : range.location
                if expected != caret {
                    applyInlineEdit(.init(range: range, replacement: "", caret: range.location), to: textView)
                    return true
                }
            }
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Shift+Return is delivered as insertNewline:, so inspect the
            // actual key event rather than assuming a plain Return.
            let event = NSApp.currentEvent
            let isShiftPressed = event?.type == .keyDown
                && event?.modifierFlags.contains(.shift) == true
            return MarkdownInputHandler.handleInsertNewline(
                textView: textView,
                isShiftPressed: isShiftPressed
            )
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return handleBacktab(textView)
        }
        return false
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let target = WikiLinkService.resolveIdentifier(link: link, textView: textView, at: charIndex) else {
            return false
        }
        // Direkt deaktivieren, bevor der Navigation-Callback läuft.
        self.isWikiLinkActive = false
        DispatchQueue.main.async {
            self.onLinkClick?(target)
        }
        return true
    }

    private func applyInlineEdit(_ edit: MarkdownInlineEditing.Edit, to textView: NSTextView) {
        let styles: Set<MarkdownFormatting.InlineStyle> = configuration.inlineEditingMode == .formatted
            ? (formattedTypingState?.styles(in: textView)
                ?? MarkdownFormattedEditing.replacementStyles(in: textView.string, range: edit.range)) : []
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        pendingEditedRange = NSRange(location: edit.range.location, length: edit.replacement.utf16.count)
        // AppKit owns the replacement and its inverse, including native undo.
        textView.insertText(edit.replacement, replacementRange: edit.range)
        textView.setSelectedRange(NSRange(location: edit.caret, length: 0))
        if configuration.inlineEditingMode == .formatted {
            formattedTypingState = .init(source: textView.string, caret: edit.caret, styles: styles)
        }
    }

    func applyFormattedEdit(_ edit: MarkdownFormattedEditing.Edit, to textView: NSTextView,
                            styles: Set<MarkdownFormatting.InlineStyle>) {
        let wasProgrammatic = isProgrammaticEdit
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = wasProgrammatic }
        pendingEditedRange = NSRange(location: edit.range.location, length: edit.replacement.utf16.count)
        textView.insertText(edit.replacement, replacementRange: edit.range)
        textView.setSelectedRange(edit.selection)
        formattedTypingState = .init(source: textView.string, caret: edit.selection.location, styles: styles)
    }

    /// Break commands carry structural text (list prefixes), not styled typing.
    /// Serialize the intersecting inline pair once, keeping the new prefix plain.
    func insertFormattedBreak(in view: NSTextView, range: NSRange, hard: Bool) -> Bool {
        guard configuration.inlineEditingMode == .formatted, !view.hasMarkedText(), !isProgrammaticEdit else { return false }
        let styles = formattedTypingState?.styles(in: view)
            ?? MarkdownFormattedEditing.replacementStyles(in: view.string, range: range)
        guard !styles.isEmpty else { return false }
        let source = view.string as NSString
        let lineRange = source.lineRange(for: NSRange(location: range.location, length: 0))
        if !hard, range.length == 0, configuration.lists.helpersEnabled,
           let context = MarkdownLists.listContext(for: source.substring(with: lineRange)),
           (source.substring(with: lineRange) as NSString).substring(from: context.prefixLength)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let handled = MarkdownLists.outdentOrTerminateEmptyItem(textView: view, context: context, lineRange: lineRange)
            if handled { formattedTypingState = .init(source: view.string, caret: view.selectedRange().location, styles: styles) }
            return handled
        }
        var replacement = hard && !styles.contains(.code) ? "  \n" : "\n"
        if configuration.lists.helpersEnabled, !styles.contains(.code), let owning = MarkdownLists.owningListContext(for: source, lineRange: lineRange),
           range.location >= lineRange.location + owning.contentStart,
           NSMaxRange(range) <= NSMaxRange(lineRange) {
            replacement += hard ? owning.context.continuationIndent
                : owning.context.leadingWhitespace + MarkdownLists.continuationText(for: owning.context)
        }
        guard let edit = MarkdownFormattedEditing.insertion(in: view.string, range: range,
            replacement: replacement, styles: styles, literal: true) else { return false }
        applyFormattedEdit(edit, to: view, styles: styles)
        return true
    }

    func updateSelectionStates(_ tv: NSTextView) {
        let nsText = tv.string as NSString
        let selRange = tv.selectedRange()
        let bus = configuration.services.bus
        let center = NotificationCenter.default
        if let name = bus.selectionBoldDidChange {
            center.post(
                name: name, object: nil,
                userInfo: ["isBold": isSelectionBold(in: nsText, range: selRange)]
            )
        }
        if let name = bus.selectionItalicDidChange {
            center.post(
                name: name, object: nil,
                userInfo: ["isItalic": isSelectionItalic(in: nsText, range: selRange)]
            )
        }
    }

    func handleBacktab(_ textView: NSTextView) -> Bool {
        let nsText = textView.string as NSString
        let caretLoc = textView.selectedRange().location
        let lineRange = nsText.lineRange(for: NSRange(location: caretLoc, length: 0))
        let line = nsText.substring(with: lineRange)

        // Outdent a whole Shift+Enter list item, including its continuation
        // lines, in one undoable edit.
        if let block = MarkdownLists.listItemBlock(for: nsText, location: caretLoc) {
            return MarkdownLists.outdentListItemBlock(textView, block: block)
        }

        let pattern = #"^([\t ]*)((\d+|a)\.|-|•)\s"#
        let regex = try? NSRegularExpression(pattern: pattern)
        if let regex = regex,
           let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) {
            let wsRangeLocal = match.range(at: 1)
            let wsString = (line as NSString).substring(with: wsRangeLocal)
            let wsDocStart = lineRange.location + wsRangeLocal.location
            let depth = MarkdownLists.indentLevel(from: wsString)
            if depth == 0 {
                return true
            }

            let markerRange = match.range(at: 2)
            let marker = (line as NSString).substring(with: markerRange)
            let shouldRestoreOrderedMarker = marker == "a."

            guard wsRangeLocal.length > 0 else { return true }

            let removeCount: Int
            if wsString.hasPrefix("\t") {
                removeCount = 1
            } else {
                var leadingSpaces = 0
                for ch in wsString {
                    if ch == " " && leadingSpaces < 2 {
                        leadingSpaces += 1
                    } else {
                        break
                    }
                }
                removeCount = leadingSpaces
            }
            guard removeCount > 0 else { return true }

            // Rebuild the whole indentation-plus-marker prefix so an item with
            // multiple nesting levels keeps the remaining indentation intact.
            let prefixRange = NSRange(
                location: wsDocStart,
                length: wsRangeLocal.length + markerRange.length
            )
            let remainingWhitespace = String(wsString.dropFirst(removeCount))
            let replacementMarker = shouldRestoreOrderedMarker ? "1." : marker
            let replacement = remainingWhitespace + replacementMarker
            let oldCaretOffset = caretLoc - prefixRange.location
            let editDelta = replacement.utf16.count - prefixRange.length
            MarkdownLists.performEdit(textView, replace: prefixRange, with: replacement)
            let newCaretLocation = oldCaretOffset >= prefixRange.length
                ? caretLoc + editDelta
                : max(0, caretLoc + editDelta)
            textView.setSelectedRange(NSRange(location: newCaretLocation, length: 0))
            return true
        }

        if line.hasPrefix("\t") {
            MarkdownLists.performEdit(textView, replace: NSRange(location: lineRange.location, length: 1), with: "")
            textView.setSelectedRange(NSRange(location: max(0, caretLoc - 1), length: 0))
            return true
        }
        return false
    }

}
