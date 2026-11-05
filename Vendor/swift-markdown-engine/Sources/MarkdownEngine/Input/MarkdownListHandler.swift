//
//  MarkdownListHandler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Makes list editing feel natural by continuing items, handling indentation,
// and applying spacing/alignment that keeps lists easy to read.
import AppKit

struct MarkdownLists {
    static func performEdit(_ textView: NSTextView, replace range: NSRange, with string: String) {
        let ns = textView.string as NSString
        let loc = min(range.location, ns.length)
        let maxLen = ns.length - loc
        let len = min(range.length, max(0, maxLen))
        let safeRange = NSRange(location: loc, length: len)

        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator { coord.isProgrammaticEdit = true }
        defer {
            if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator { coord.isProgrammaticEdit = false }
        }

        guard textView.shouldChangeText(in: safeRange, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: safeRange, with: string)
        textView.didChangeText()
    }

    static let listRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*((?:(\d+)[.)]|[-+*•])(?:[ \t]+\[[ xX]\])?[ \t]+)"#
    )
    static let tabListRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*((?:(\d+|a)[.)]|[-+*•])(?:[ \t]+\[[ xX]\])?[ \t]+)"#
    )
    static let dashNoSpaceRegex = try! NSRegularExpression(pattern: #"^\s*-(?!\s)"#)
    static let numberRegex = try! NSRegularExpression(pattern: #"^\s*(\d+)\.$"#)
    static let leadingWhitespaceRegex = try! NSRegularExpression(pattern: #"^\s*"#)

    static func indentLevel(from leadingWhitespace: String) -> Int {
        let tabCount = leadingWhitespace.filter { $0 == "\t" }.count
        let spaceCount = leadingWhitespace.filter { $0 == " " }.count
        return tabCount + (spaceCount / 2)
    }

    // MARK: - List Line Context

    struct ListLineContext {
        let leadingWhitespace: String
        let marker: String
        let number: Int?
        let hasCheckbox: Bool
        /// UTF-16 length of the complete marker prefix (indent + marker + spaces).
        let prefixLength: Int

        var continuationIndent: String {
            leadingWhitespace + String(repeating: " ", count: prefixLength - leadingWhitespace.utf16.count)
        }
    }

    static func leadingWhitespace(in line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    static func listContext(for line: String) -> ListLineContext? {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard var match = listRegex.firstMatch(in: line, range: range) else { return nil }
        // On an empty hard-broken item, the last two spaces are the break,
        // not marker padding. Keep the continuation indent stable after typing.
        let body = line.trimmingCharacters(in: .newlines) as NSString
        if body.length < nsLine.length,
           match.range.length == body.length, body.hasSuffix("  "),
           body.length >= 2,
           let prefix = listRegex.firstMatch(
               in: body.substring(to: body.length - 2),
               range: NSRange(location: 0, length: body.length - 2)
           ) {
            match = prefix
        }
        let prefix = nsLine.substring(with: match.range(at: 1))
        let leading = leadingWhitespace(in: line)
        let marker = String(prefix.prefix { $0 != " " && $0 != "\t" })
        return ListLineContext(
            leadingWhitespace: leading,
            marker: marker,
            number: marker.hasSuffix(".") || marker.hasSuffix(")") ? Int(marker.dropLast()) : nil,
            hasCheckbox: prefix.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil,
            prefixLength: match.range.length
        )
    }

    /// Marker text for the next item, excluding the leading indentation.
    static func continuationText(for context: ListLineContext) -> String {
        if let number = context.number {
            let next = number == Int.max ? number : number + 1
            let delimiter = context.marker.hasSuffix(")") ? ")" : "."
            return context.hasCheckbox ? "\(next)\(delimiter) [ ] " : "\(next)\(delimiter) "
        }
        let bullet = context.marker
        return context.hasCheckbox ? "\(bullet) [ ] " : "\(bullet) "
    }

    static func endsWithHardBreak(_ line: String) -> Bool {
        var body = line
        while body.hasSuffix("\n") || body.hasSuffix("\r") {
            body.removeLast()
        }
        if body.hasSuffix("\\") {
            // An odd run of trailing backslashes is a hard break; an even run
            // is an escaped backslash and therefore not a break.
            let backslashCount = body.reversed().prefix { $0 == "\\" }.count
            return backslashCount % 2 == 1
        }
        return body.reversed().prefix { $0 == " " }.count >= 2
    }

    /// Resolves the list item that owns `lineRange`. When the caret is on a
    /// continuation line produced by Shift+Enter, this walks back over the
    /// hard-broken lines to the original list item.
    static func owningListContext(
        for nsText: NSString,
        lineRange: NSRange
    ) -> (context: ListLineContext, contentStart: Int, anchorLineRange: NSRange)? {
        let line = nsText.substring(with: lineRange)
        if let context = listContext(for: line) {
            return (context, context.prefixLength, lineRange)
        }

        let currentIndent = leadingWhitespace(in: line)
        var searchLocation = lineRange.location
        while searchLocation > 0 {
            let previousRange = nsText.lineRange(for: NSRange(location: searchLocation - 1, length: 0))
            let previousLine = nsText.substring(with: previousRange)
            if let context = listContext(for: previousLine) {
                guard endsWithHardBreak(previousLine),
                      context.continuationIndent == currentIndent else { return nil }
                return (context, currentIndent.utf16.count, previousRange)
            }
            // A line without a hard break ends the search; a whitespace-only
            // hard-break line is a continuation from an earlier Shift+Enter
            // and is walked over without requiring an exact indent match.
            guard endsWithHardBreak(previousLine) else { return nil }
            if previousLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchLocation = previousRange.location
                continue
            }
            guard leadingWhitespace(in: previousLine) == currentIndent else { return nil }
            searchLocation = previousRange.location
        }
        return nil
    }

    // MARK: - Multi-line List Items

    struct ListItemBlock {
        let context: ListLineContext
        /// Anchor (marker) line first, followed by its hard-broken continuation lines.
        let lineRanges: [NSRange]

        var range: NSRange {
            guard let first = lineRanges.first, let last = lineRanges.last else {
                return NSRange(location: 0, length: 0)
            }
            return NSRange(
                location: first.location,
                length: NSMaxRange(last) - first.location
            )
        }
    }

    /// The whole list item around `location`: its marker line plus every
    /// continuation line created by Shift+Enter. Sibling items are excluded.
    static func listItemBlock(for nsText: NSString, location: Int) -> ListItemBlock? {
        let safeLocation = min(max(0, location), nsText.length)
        let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocation, length: 0))
        let currentLine = nsText.substring(with: currentLineRange)

        let anchorLineRange: NSRange
        if listContext(for: currentLine) != nil {
            anchorLineRange = currentLineRange
        } else if let owning = owningListContext(for: nsText, lineRange: currentLineRange) {
            anchorLineRange = owning.anchorLineRange
        } else if currentLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let anchor = listAnchorBeforeBlankLine(for: nsText, lineRange: currentLineRange) {
            // Repeated Shift+Enter leaves whitespace-only lines whose extra
            // spaces don't match the continuation indent exactly.
            anchorLineRange = anchor
        } else {
            return nil
        }

        guard let context = listContext(for: nsText.substring(with: anchorLineRange)) else {
            return nil
        }

        var lineRanges = [anchorLineRange]
        var lastRange = anchorLineRange
        while endsWithHardBreak(nsText.substring(with: lastRange)) {
            let nextLocation = NSMaxRange(lastRange)
            guard nextLocation < nsText.length else { break }
            let nextRange = nsText.lineRange(for: NSRange(location: nextLocation, length: 0))
            guard nextRange.location > lastRange.location else { break }

            let nextLine = nsText.substring(with: nextRange)
            // A sibling (or nested) item starts its own block.
            if listContext(for: nextLine) != nil { break }

            let trimmed = nextLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               leadingWhitespace(in: nextLine) != context.continuationIndent {
                break
            }

            lineRanges.append(nextRange)
            lastRange = nextRange
        }

        return ListItemBlock(context: context, lineRanges: lineRanges)
    }

    private static func listAnchorBeforeBlankLine(for nsText: NSString, lineRange: NSRange) -> NSRange? {
        var searchLocation = lineRange.location
        while searchLocation > 0 {
            let previousRange = nsText.lineRange(for: NSRange(location: searchLocation - 1, length: 0))
            let previousLine = nsText.substring(with: previousRange)
            guard endsWithHardBreak(previousLine) else { return nil }
            if previousLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchLocation = previousRange.location
                continue
            }
            return owningListContext(for: nsText, lineRange: previousRange)?.anchorLineRange
        }
        return nil
    }

    /// Indents every line of `block` by one tab in a single undoable edit.
    static func indentListItemBlock(_ textView: NSTextView, block: ListItemBlock) -> Bool {
        let nsText = textView.string as NSString
        let blockRange = block.range
        guard blockRange.length > 0, NSMaxRange(blockRange) <= nsText.length else { return false }

        var replacement = ""
        var insertionLocations: [Int] = []
        for lineRange in block.lineRanges {
            insertionLocations.append(lineRange.location)
            replacement += "\t"
            replacement += nsText.substring(with: lineRange)
        }

        let selection = textView.selectedRange()
        MarkdownLists.performEdit(textView, replace: blockRange, with: replacement)
        applySelection(
            in: textView,
            selection: selection,
            map: { mappedInsertionOffset($0, insertions: insertionLocations) }
        )
        return true
    }

    /// Outdents every line of `block` by one level in a single undoable edit.
    static func outdentListItemBlock(_ textView: NSTextView, block: ListItemBlock) -> Bool {
        let nsText = textView.string as NSString
        let blockRange = block.range
        guard blockRange.length > 0, NSMaxRange(blockRange) <= nsText.length else { return false }
        guard indentLevel(from: block.context.leadingWhitespace) > 0 else { return true }

        var replacement = ""
        var deletionRanges: [NSRange] = []
        for lineRange in block.lineRanges {
            let line = nsText.substring(with: lineRange)
            let leading = leadingWhitespace(in: line)
            let removalCount = indentationRemovalCount(from: leading)
            if removalCount > 0 {
                deletionRanges.append(NSRange(location: lineRange.location, length: removalCount))
            }

            replacement += String(line.dropFirst(removalCount))
        }

        let selection = textView.selectedRange()
        MarkdownLists.performEdit(textView, replace: blockRange, with: replacement)
        applySelection(
            in: textView,
            selection: selection,
            map: { mappedDeletionOffset($0, deletions: deletionRanges) }
        )
        return true
    }

    private static func applySelection(
        in textView: NSTextView,
        selection: NSRange,
        map: (Int) -> Int
    ) {
        let length = (textView.string as NSString).length
        let location = min(max(0, map(selection.location)), length)
        let end = min(max(location, map(NSMaxRange(selection))), length)
        textView.setSelectedRange(NSRange(location: location, length: end - location))
    }

    private static func mappedInsertionOffset(_ offset: Int, insertions: [Int]) -> Int {
        var result = offset
        for location in insertions {
            guard offset >= location else { break }
            result += 1
        }
        return result
    }

    private static func mappedDeletionOffset(_ offset: Int, deletions: [NSRange]) -> Int {
        var delta = 0
        for range in deletions {
            let start = range.location
            let end = NSMaxRange(range)
            if offset <= start { break }
            if offset >= end {
                delta -= range.length
            } else {
                delta -= offset - start
                break
            }
        }
        return offset + delta
    }

    static func indentationRemovalCount(from whitespace: String) -> Int {
        if whitespace.hasPrefix("\t") { return 1 }
        var count = 0
        for character in whitespace {
            if character == " " && count < 2 {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    // MARK: - Shift+Enter Hard Break

    /// Inserts a standard Markdown hard break (two spaces + LF). Inside a list
    /// item the next line is aligned with the item content; elsewhere no
    /// continuation indent is added. Code blocks keep a plain LF.
    /// Returns `true` when the break was handled.
    static func insertHardBreak(textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if let coordinator = textView.delegate as? NativeTextViewCoordinator,
           coordinator.insertFormattedBreak(in: textView, range: textView.selectedRange(), hard: true) { return true }
        let nsText = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound,
              selection.location <= nsText.length,
              NSMaxRange(selection) <= nsText.length else { return false }

        // Code blocks and inline code keep a plain newline. A caret just after
        // a closed inline code token is outside the code.
        if textView.string.contains("`") || textView.string.contains("~"),
           MarkdownDetection.isInsideCodeContext(location: selection.location, in: textView.string) {
            return false
        }

        let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
        let owning = owningListContext(for: nsText, lineRange: lineRange)
        var contentsEnd = 0
        nsText.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lineRange)
        guard NSMaxRange(selection) <= contentsEnd else { return false }
        if let owning {
            guard selection.location >= lineRange.location + owning.contentStart else { return false }
        }

        let indent = owning?.context.continuationIndent ?? ""
        let replacement = "  \n" + indent
        performEdit(textView, replace: selection, with: replacement)
        let caret = selection.location + replacement.utf16.count
        textView.setSelectedRange(NSRange(
            location: min(caret, (textView.string as NSString).length),
            length: 0
        ))
        return true
    }

    /// Enter on an empty item: nested items outdent one level, top-level
    /// items leave the list. Returns `true` when the edit was handled.
    static func outdentOrTerminateEmptyItem(
        textView: NSTextView,
        context: ListLineContext,
        lineRange: NSRange
    ) -> Bool {
        let nsText = textView.string as NSString
        let caret = textView.selectedRange().location
        if indentLevel(from: context.leadingWhitespace) == 0 {
            let lineEnd = NSMaxRange(lineRange)
            let hasNewline = lineRange.length > 0
                && nsText.substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n"
            let maxBodyLength = hasNewline ? lineRange.length - 1 : lineRange.length
            let removalLength = min(context.prefixLength, maxBodyLength)
            performEdit(
                textView,
                replace: NSRange(location: lineRange.location, length: removalLength),
                with: ""
            )
            textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            return true
        }

        let removalCount = indentationRemovalCount(from: context.leadingWhitespace)
        guard removalCount > 0 else { return false }
        performEdit(
            textView,
            replace: NSRange(location: lineRange.location, length: removalCount),
            with: ""
        )
        let newCaret = max(lineRange.location, caret - removalCount)
        textView.setSelectedRange(NSRange(
            location: min(newCaret, (textView.string as NSString).length),
            length: 0
        ))
        return true
    }

    // MARK: - Paragraph Attributes for List Styling

    /// Whether the caret is inside a task checkbox's visible syntax, in which
    /// case `MarkdownStyler.styleTaskCheckboxes` reveals the raw `[ ]`/`[x]`
    /// and skips the extra spacing after it.
    static func taskCheckboxSyntaxIsActive(
        markerRange: NSRange,
        checkboxRange: NSRange,
        nsText: NSString,
        caretLocation: Int
    ) -> Bool {
        guard markerRange.location != NSNotFound,
              checkboxRange.location != NSNotFound else { return false }
        let syntaxStart = markerRange.location
        let syntaxEnd = checkboxRange.location + checkboxRange.length
        guard syntaxEnd > syntaxStart else { return false }
        if NSLocationInRange(
            caretLocation,
            NSRange(location: syntaxStart, length: syntaxEnd - syntaxStart)
        ) {
            return true
        }
        guard caretLocation == syntaxEnd else { return false }
        let lastIndex = syntaxEnd - 1
        guard lastIndex >= syntaxStart, lastIndex < nsText.length else { return false }
        return nsText.substring(with: NSRange(location: lastIndex, length: 1)) != "\n"
    }

    static func paragraphAttributes(
        for text: String,
        baseFont: NSFont,
        nsText: NSString,
        fullRange: NSRange,
        caretLocation: Int,
        codeTokens: [MarkdownToken] = [],
        listsEnabled: Bool,
        defaultLineHeight: CGFloat,
        defaultParagraphSpacing: CGFloat,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [(range: NSRange, attributes: [NSAttributedString.Key: Any])] {
        var attributesList: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        guard listsEnabled else { return attributesList }

        let indentPerLevel = configuration.lists.indentPerLevel
        let extraLineHeight = configuration.lists.extraLineHeight

        // Advance of `string` from `startX`, honoring the paragraph's tab stops.
        // Tabs snap to absolute multiples of `indentPerLevel`; measuring them as
        // fixed-width would drift from the actual layout for nested list items.
        func advanceWidth(_ string: String, startingAt startX: CGFloat) -> CGFloat {
            var x = startX
            var segment = ""
            func flushSegment() {
                guard !segment.isEmpty else { return }
                x += (segment as NSString).size(withAttributes: [.font: baseFont]).width
                segment.removeAll(keepingCapacity: true)
            }
            for character in string {
                if character == "\t" {
                    flushSegment()
                    if indentPerLevel > 0 {
                        x = (floor(x / indentPerLevel) + 1) * indentPerLevel
                    }
                } else {
                    segment.append(character)
                }
            }
            flushSegment()
            return x - startX
        }

        func makeListParagraphStyle() -> NSMutableParagraphStyle {
            let ps = NSMutableParagraphStyle()
            ps.minimumLineHeight = defaultLineHeight + extraLineHeight
            ps.maximumLineHeight = defaultLineHeight + extraLineHeight
            ps.lineSpacing = 0
            ps.paragraphSpacing = defaultParagraphSpacing
            ps.paragraphSpacingBefore = 0
            ps.tabStops = []
            ps.defaultTabInterval = indentPerLevel
            ps.firstLineHeadIndent = 0
            ps.headIndent = 0
            return ps
        }

        func applyListMatches(_ matches: [NSTextCheckingResult]) {
            for match in matches {
                // Fenced code keeps its literal indentation; list layout must
                // not shift code lines that happen to look like list items.
                guard !MarkdownDetection.isInsideCodeBlock(
                    range: NSRange(location: match.range.location, length: 1),
                    codeTokens: codeTokens
                ) else { continue }
                let wsRange = match.range(at: 1)
                let block = listItemBlock(for: nsText, location: match.range.location)
                var markerRange = match.range(at: 2)
                if let block {
                    markerRange.length = block.context.prefixLength - wsRange.length
                }
                let ws = nsText.substring(with: wsRange)
                let depthIndent = advanceWidth(ws, startingAt: 0)

                let markerString = nsText.substring(with: markerRange) as NSString
                let markerWidth = advanceWidth(markerString as String, startingAt: depthIndent)
                let checkboxLocalRange = markerString.range(
                    of: #"\[[ xX]\]"#,
                    options: .regularExpression
                )
                let hasCheckbox = checkboxLocalRange.location != NSNotFound
                let isChecked = hasCheckbox
                    && markerString.substring(with: checkboxLocalRange)
                        .range(of: "[x]", options: [.caseInsensitive]) != nil
                let checkboxRange = hasCheckbox
                    ? NSRange(
                        location: markerRange.location + checkboxLocalRange.location,
                        length: checkboxLocalRange.length
                    )
                    : NSRange(location: NSNotFound, length: 0)
                let checkboxSyntaxIsActive = hasCheckbox
                    && taskCheckboxSyntaxIsActive(
                        markerRange: markerRange,
                        checkboxRange: checkboxRange,
                        nsText: nsText,
                        caretLocation: caretLocation
                    )
                let afterCheckbox = checkboxRange.location + checkboxRange.length
                let checkboxAddsSpacing = hasCheckbox && !isChecked
                    && !checkboxSyntaxIsActive
                    && afterCheckbox < nsText.length
                    && nsText.substring(with: NSRange(location: afterCheckbox, length: 1)) == " "
                let extraSpacing = checkboxAddsSpacing
                    ? HeadingHelpers.checkboxExtraSpacing(
                        font: baseFont,
                        configuration: configuration.checkbox
                    )
                    : 0

                let contentX = depthIndent + markerWidth + extraSpacing
                let ps = makeListParagraphStyle()
                ps.headIndent = contentX
                attributesList.append((match.range(at: 0), [.paragraphStyle: ps]))

                // Shift+Enter continuation lines keep their literal indentation
                // in the Markdown source, but that indentation is measured with
                // proportional space widths and does not match the marker's
                // rendered content offset. Correct the leading whitespace's
                // advance and give wrapped lines the same content indent.
                guard let block,
                      block.lineRanges.count > 1 else { continue }
                for lineRange in block.lineRanges.dropFirst() {
                    let line = nsText.substring(with: lineRange)
                    let leading = leadingWhitespace(in: line)
                    let continuation = makeListParagraphStyle()
                    continuation.headIndent = contentX
                    let leadingAdvance = advanceWidth(leading, startingAt: 0)
                    let correction = contentX - leadingAdvance
                    // TextKit 2 distributes kern around glyphs and ignores it
                    // at an empty line's caret. Paragraph offsets work for both.
                    continuation.firstLineHeadIndent = correction
                    if leading.contains("\t"), indentPerLevel > 0 {
                        let count = Int(ceil(leadingAdvance / indentPerLevel)) + 1
                        continuation.tabStops = (1...count).map {
                            NSTextTab(textAlignment: .left, location: correction + CGFloat($0) * indentPerLevel)
                        }
                    }
                    attributesList.append((lineRange, [.paragraphStyle: continuation]))
                }
            }
        }

        // Ordered lists
        let orderedListPattern = #"^([ \t]*)(\d+[.)](?:[ \t]+\[[ xX]\])?[ \t]+)(.*)$"#
        if let orderedListRegex = try? NSRegularExpression(pattern: orderedListPattern, options: [.anchorsMatchLines]) {
            applyListMatches(orderedListRegex.matches(in: text, options: [], range: fullRange))
        }

        // Bullet lists
        let bulletListPattern = #"^([ \t]*)([-+*•](?:[ \t]+\[[ xX]\])?[ \t]+)(.*)$"#
        if let bulletListRegex = try? NSRegularExpression(pattern: bulletListPattern, options: [.anchorsMatchLines]) {
            applyListMatches(bulletListRegex.matches(in: text, options: [], range: fullRange))
        }
        return attributesList
    }

    // MARK: - Input Handling

    static func handleInsertion(textView: NSTextView, affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString = replacementString else { return true }
        // Never interfere with an IME composition; the input method owns it.
        guard !textView.hasMarkedText() else { return true }

        // Fast path: skip the expensive isInsideCodeBlock scan for ordinary typing.
        if replacementString.count == 1,
           let ch = replacementString.first,
           ch != ">" && ch != "[" && ch != "(" && ch != "{" &&
           ch != "\t" && ch != " " && ch != "\n" {
            return true
        }

        let activeConfig = (textView as? NativeTextView)?.configuration ?? .default
        let listsEnabled = activeConfig.lists.helpersEnabled
        let autoClosePairsEnabled = activeConfig.lists.autoClosePairsEnabled

        func insertAutoPair(open openChar: String, close closeChar: String) -> Bool {
            let insertionLocation = affectedCharRange.location
            MarkdownLists.performEdit(textView, replace: affectedCharRange, with: "\(openChar)\(closeChar)")
            textView.setSelectedRange(NSRange(location: insertionLocation + openChar.count, length: 0))
            return false
        }

        let isInCodeBlock = textView.string.contains("`") || textView.string.contains("~")
            ? MarkdownDetection.isInsideCodeContext(location: affectedCharRange.location, in: textView.string)
            : false
        if replacementString == ">" && affectedCharRange.length == 0 && !isInCodeBlock {
            let insertionLocation = affectedCharRange.location
            guard insertionLocation > 0 else { return true }
            let nsText = textView.string as NSString
            let previousCharRange = NSRange(location: insertionLocation - 1, length: 1)
            let previousChar = nsText.substring(with: previousCharRange)
            if previousChar == "-" {
                MarkdownLists.performEdit(textView, replace: previousCharRange, with: "→")
                textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
                return false
            }
        }

        // Autocomplete Obsidian-style node brackets and single square brackets
        if replacementString == "[" {
            let nsText = textView.string as NSString
            let insertionLocation = affectedCharRange.location
            if insertionLocation > 0 {
                let prevChar = nsText.substring(with: NSRange(location: insertionLocation - 1, length: 1))
                if prevChar == "[" {
                    let hasAutoCloseBracket = insertionLocation < nsText.length
                        && nsText.substring(with: NSRange(location: insertionLocation, length: 1)) == "]"
                    if hasAutoCloseBracket {
                        // Collapse auto-paired "[]" into "[[]]" without changing surrounding text.
                        MarkdownLists.performEdit(
                            textView,
                            replace: NSRange(location: insertionLocation - 1, length: 2),
                            with: "[[]]"
                        )
                    } else {
                        // If the char to the right is not "]" (e.g. newline), do not delete it.
                        MarkdownLists.performEdit(textView, replace: affectedCharRange, with: "[]]")
                    }
                    textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                    return false
                }
            }
            guard autoClosePairsEnabled else { return true }
            return insertAutoPair(open: "[", close: "]")
        }

        // Autocomplete parentheses / braces
        if replacementString == "(" || replacementString == "{" {
            guard autoClosePairsEnabled else { return true }
            let closeChar = (replacementString == "(") ? ")" : "}"
            return insertAutoPair(open: replacementString, close: closeChar)
        }

        // TAB: indent list items (skip in code blocks)
        if replacementString == "\t" && !isInCodeBlock {
            guard listsEnabled else { return true }
            // Keep AppKit's normal replacement semantics for a real selection.
            guard affectedCharRange.length == 0 else { return true }
            let nsText = textView.string as NSString
            let insertionLocation = affectedCharRange.location
            let safeLocTAB = min(affectedCharRange.location, nsText.length)
            let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocTAB, length: 0))
            let currentLine = nsText.substring(with: currentLineRange)
            let lineRangeLocal = NSRange(location: 0, length: currentLine.utf16.count)

            // A Shift+Enter item is one block: indent its continuation lines
            // together with the marker line, leaving siblings untouched.
            if let block = MarkdownLists.listItemBlock(for: nsText, location: safeLocTAB) {
                let level = MarkdownLists.indentLevel(from: block.context.leadingWhitespace)
                if level >= activeConfig.lists.maximumNestingLevel {
                    return false
                }
                return MarkdownLists.indentListItemBlock(textView, block: block) ? false : true
            }

            if MarkdownLists.tabListRegex.firstMatch(in: currentLine, range: lineRangeLocal) != nil {
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: currentLine, range: lineRangeLocal) {
                    let ws = (currentLine as NSString).substring(with: wsMatch.range)
                    let level = MarkdownLists.indentLevel(from: ws)
                    if level >= activeConfig.lists.maximumNestingLevel {
                        return false
                    }
                }
                // Insert indentation without rewriting the marker, so ordered
                // lists stay standard Markdown numbers (1., 2., …).
                MarkdownLists.performEdit(
                    textView,
                    replace: NSRange(location: currentLineRange.location, length: 0),
                    with: "\t"
                )
                textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                return false
            }
            if MarkdownLists.dashNoSpaceRegex.firstMatch(in: currentLine, range: lineRangeLocal) != nil {
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: currentLine, range: lineRangeLocal) {
                    let ws = (currentLine as NSString).substring(with: wsMatch.range)
                    let level = MarkdownLists.indentLevel(from: ws)
                    if level >= activeConfig.lists.maximumNestingLevel { return false }
                }
                MarkdownLists.performEdit(
                    textView,
                    replace: NSRange(location: currentLineRange.location, length: 0),
                    with: "\t"
                )
                textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                return false
            }
            return true
        }

        // SPACE: convert "-" or "1." to proper markers (skip in code blocks)
        if replacementString == " " && !isInCodeBlock {
            guard listsEnabled else { return true }
            let insertionLocation = affectedCharRange.location
            if insertionLocation > 0 {
                let nsText = textView.string as NSString
                let prevCharRange = NSRange(location: insertionLocation - 1, length: 1)
                let prevChar = nsText.substring(with: prevCharRange)
                let currentLineRange = nsText.lineRange(for: NSRange(location: insertionLocation - 1, length: 0))
                let currentLine = nsText.substring(with: currentLineRange)
                if let match = MarkdownLists.numberRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
                    let numberRange = match.range(at: 1)
                    let numberString = (currentLine as NSString).substring(with: numberRange)
                    let markerRange = NSRange(location: currentLineRange.location + match.range.location, length: match.range.length)
                    MarkdownLists.performEdit(textView, replace: markerRange, with: "\t\(numberString). ")
                    return false
                }
                if prevChar == "-" {
                    let beforePrevIndex = insertionLocation - 2
                    let isAtLineStart: Bool = (beforePrevIndex < 0) || nsText.substring(with: NSRange(location: beforePrevIndex, length: 1)) == "\n"
                    if isAtLineStart {
                        MarkdownLists.performEdit(textView, replace: prevCharRange, with: "\t• ")
                        return false
                    }
                }
            }
        }

        // ENTER: HR expansion and list continuation/outdent
        if replacementString == "\n" {
            let nsText = textView.string as NSString
            let safeLocENTER = min(affectedCharRange.location, nsText.length)
            let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocENTER, length: 0))
            let currentLine = nsText.substring(with: currentLineRange)
            let trimmedLine = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)

            // Horizontal rule expansion
            if !isInCodeBlock, affectedCharRange.length == 0,
                trimmedLine.range(of: "^-{3,}$", options: .regularExpression) != nil {
                let hrFont = (textView as? NativeTextView)?.baseFont
                    ?? textView.font
                    ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let hyphenWidth = ("-" as NSString).size(withAttributes: [.font: hrFont]).width
                let visibleWidth = textView.enclosingScrollView?.contentView.bounds.width
                                    ?? textView.textContainer?.containerSize.width
                                    ?? textView.bounds.width
                let count = Int(visibleWidth / hyphenWidth)
                let fullLine = String(repeating: "-", count: max(count, 3))
                let newString = fullLine + "\n"
                MarkdownLists.performEdit(textView, replace: currentLineRange, with: newString)
                textView.setSelectedRange(NSRange(location: currentLineRange.location + fullLine.count + 1, length: 0))
                return false
            }

            if affectedCharRange.length == 0,
               trimmedLine.range(of: "^```\\w*$", options: .regularExpression) != nil {
                let textBeforeLine = nsText.substring(to: currentLineRange.location)
                let openingCount = textBeforeLine.components(separatedBy: "```").count - 1
                let afterLineStart = currentLineRange.location + currentLineRange.length
                let hasClosingAfter: Bool = {
                    guard afterLineStart < nsText.length else { return false }
                    return nsText.substring(from: afterLineStart).contains("```")
                }()
                let lineEnd = currentLineRange.location + max(0, currentLineRange.length - 1)
                let cursorAtLineEnd = affectedCharRange.location >= lineEnd

                if openingCount.isMultiple(of: 2) && cursorAtLineEnd && !hasClosingAfter {
                    let insertionLocation = affectedCharRange.location
                    let completion = "\n\n```"
                    MarkdownLists.performEdit(textView, replace: affectedCharRange, with: completion)
                    textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                    return false
                }
            }

            // Skip list continuation in code blocks
            guard listsEnabled && !isInCodeBlock else { return true }

            // A selection that crosses the current line is left to AppKit so
            // the normal replacement semantics are preserved.
            let selectionEnd = affectedCharRange.location + affectedCharRange.length
            var contentsEnd = 0
            nsText.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: currentLineRange)
            guard selectionEnd <= contentsEnd else { return true }

            if let context = MarkdownLists.listContext(for: currentLine) {
                guard affectedCharRange.location >= currentLineRange.location + context.prefixLength else {
                    return true
                }
                let contentRangeLocal = NSRange(
                    location: context.prefixLength,
                    length: max(0, currentLine.utf16.count - context.prefixLength)
                )
                let contentText = (currentLine as NSString).substring(with: contentRangeLocal)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if affectedCharRange.length == 0 && contentText.isEmpty {
                    let handled = MarkdownLists.outdentOrTerminateEmptyItem(
                        textView: textView,
                        context: context,
                        lineRange: currentLineRange
                    )
                    return handled ? false : true
                }
                let newListItem = "\n" + context.leadingWhitespace
                    + MarkdownLists.continuationText(for: context)
                MarkdownLists.performEdit(textView, replace: affectedCharRange, with: newListItem)
                return false
            }

            // Enter on a line continued with Shift+Enter continues the
            // original list item instead of inserting a plain newline.
            if let owning = MarkdownLists.owningListContext(for: nsText, lineRange: currentLineRange),
               affectedCharRange.location >= currentLineRange.location + owning.contentStart {
                let newListItem = "\n" + owning.context.leadingWhitespace
                    + MarkdownLists.continuationText(for: owning.context)
                MarkdownLists.performEdit(textView, replace: affectedCharRange, with: newListItem)
                return false
            }
        }

        return true
    }
}
