import AppKit

/// Source-range edits over the existing parser's inline tokens. Delimiters are
/// retained around surviving content; no rendered-text or AST round trip.
enum MarkdownInlineEditing {
    // Scope normalization to native navigation, never programmatic source
    // selections (toolbar ranges, reload, IME and undo must remain exact).
    // Accessed synchronously by NSTextView commands/delegates on the UI thread.
    static var navigationSteps: [ObjectIdentifier: Bool] = [:]
    struct Edit {
        let range: NSRange
        let replacement: String
        let caret: Int
    }

    static func formats(in tokens: [MarkdownToken]) -> [MarkdownToken] {
        let literals = tokens.filter { [.inlineCode, .codeBlock, .inlineLatex, .blockLatex].contains($0.kind) }
        return tokens.filter { token in
            [.bold, .italic, .boldItalic, .strikethrough].contains(token.kind)
                && !literals.contains { NSLocationInRange(token.range.location, $0.range) }
        }
    }

    /// Code contents remain literal; only the parsed backtick delimiters vanish.
    static func presentationFormats(in tokens: [MarkdownToken]) -> [MarkdownToken] {
        let blocks = tokens.filter { $0.kind == .codeBlock }
        return formats(in: tokens) + tokens.filter { token in
            token.kind == .inlineCode && !blocks.contains { NSIntersectionRange($0.range, token.range).length > 0 }
        }
    }

    static func hiddenMarkerRanges(in text: String, tokens: [MarkdownToken]) -> [NSRange] {
        presentationFormats(in: tokens).flatMap(\.markerRanges)
            + MarkdownEscaping.markerRanges(in: text, tokens: tokens)
    }

    static func characterRange(in text: NSString, at caret: Int, backward: Bool,
                               tokens: [MarkdownToken], formatted: Bool = false) -> NSRange? {
        let markers = formatted ? hiddenMarkerRanges(in: text as String, tokens: tokens) : formats(in: tokens).flatMap(\.markerRanges)
        var index = backward ? caret - 1 : caret
        while index >= 0 && index < text.length {
            if let marker = markers.first(where: { NSLocationInRange(index, $0) }) {
                index = backward ? marker.location - 1 : NSMaxRange(marker)
            } else {
                return text.rangeOfComposedCharacterSequence(at: index)
            }
        }
        return nil
    }

    static func edit(in source: String, range: NSRange, replacement: String,
                     tokens: [MarkdownToken], formatted: Bool = false) -> Edit? {
        let text = source as NSString
        guard range.length > 0, range.location <= text.length,
              range.length <= text.length - range.location else { return nil }
        let formats = formatted ? presentationFormats(in: tokens) : formats(in: tokens)
        let joinsFormats = replacement.isEmpty && formats.contains { left in
            NSMaxRange(left.range) == range.location && formats.contains { right in
                right.kind == left.kind && right.range.location == NSMaxRange(range)
            }
        }
        let escapes = formatted ? MarkdownEscaping.markerRanges(in: source, tokens: tokens) : []
        guard joinsFormats || formats.contains(where: { NSIntersectionRange($0.range, range).length > 0 })
                || escapes.contains(where: { NSIntersectionRange(NSRange(location: $0.location, length: 2), range).length > 0 }) else { return nil }
        var markers = IndexSet()
        for marker in formats.flatMap(\.markerRanges) {
            markers.insert(integersIn: marker.location..<NSMaxRange(marker))
        }
        for escape in escapes { markers.insert(escape.location) }
        let expanded = text.rangeOfComposedCharacterSequences(for: range)
        var deleted = IndexSet(integersIn: expanded.location..<NSMaxRange(expanded))
        deleted.subtract(markers)
        // A marker-only selection is not permission to damage the source pair.
        guard let insertion = deleted.first else {
            return Edit(range: range, replacement: text.substring(with: range), caret: range.location)
        }
        for escape in escapes where deleted.contains(escape.location + 1) { deleted.insert(escape.location) }
        for token in formats {
            var content = IndexSet(integersIn: token.contentRange.location..<NSMaxRange(token.contentRange))
            content.subtract(markers)
            let touched = !content.intersection(deleted).isEmpty
            content.subtract(deleted)
            let receivesReplacement = !replacement.isEmpty && NSLocationInRange(insertion, token.contentRange)
            if touched && content.isEmpty && !receivesReplacement {
                for marker in token.markerRanges {
                    deleted.insert(integersIn: marker.location..<NSMaxRange(marker))
                }
            }
        }
        // Removing the gap between equal sibling formats would otherwise create
        // an ambiguous delimiter run (~~a~~~~b~~). Join their surviving content.
        let ordered = formats.sorted { $0.range.location < $1.range.location }
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            guard left.kind == right.kind, NSMaxRange(left.range) <= right.range.location,
                  let close = left.markerRanges.last, let open = right.markerRanges.first,
                  text.substring(with: close) == text.substring(with: open),
                  !deleted.contains(close.location), !deleted.contains(open.location) else { continue }
            let gap = NSMaxRange(left.range)..<right.range.location
            guard deleted.count(in: gap) == gap.count,
                  gap.count > 0,
                  replacement.isEmpty || insertion < NSMaxRange(left.contentRange) else { continue }
            deleted.insert(integersIn: close.location..<NSMaxRange(close))
            deleted.insert(integersIn: open.location..<NSMaxRange(open))
        }
        let start = min(deleted.first!, insertion)
        let end = deleted.last! + 1
        let result = NSMutableString(string: text.substring(with: NSRange(location: start, length: end - start)))
        for run in deleted.rangeView.reversed() {
            result.deleteCharacters(in: NSRange(location: run.lowerBound - start, length: run.count))
        }
        let insertionOffset = insertion - start - deleted.count(in: start..<insertion)
        result.insert(replacement, at: insertionOffset)
        let caret = start + insertionOffset + replacement.utf16.count
        let edit = Edit(range: NSRange(location: start, length: end - start), replacement: result as String, caret: caret)
        return normalizeWhitespace(edit, in: text, formats: formats.filter { $0.kind != .inlineCode }, deleted: deleted,
                                   insertion: insertion, replacementLength: replacement.utf16.count)
    }

    /// Keep the parser's original marker identities while moving newly exposed
    /// whitespace outside them. Work inside-out so nested pairs stay valid too.
    private static func normalizeWhitespace(_ edit: Edit, in source: NSString,
                                            formats: [MarkdownToken], deleted: IndexSet,
                                            insertion: Int, replacementLength: Int) -> Edit {
        struct Pair {
            var open: NSRange
            var close: NSRange
            let original: NSRange
        }
        func mapped(_ location: Int) -> Int {
            location - deleted.count(in: 0..<location) + (location > insertion ? replacementLength : 0)
        }
        let events = formats.flatMap { token in
            [(token.markerRanges.first!, true, token.kind), (token.markerRanges.last!, false, token.kind)]
        }.filter { !deleted.contains($0.0.location) }.sorted { $0.0.location < $1.0.location }
        var stack: [(NSRange, MarkdownTokenKind)] = []
        var pairs: [Pair] = []
        for (marker, opening, kind) in events {
            if opening {
                stack.append((marker, kind))
            } else if let index = stack.lastIndex(where: { $0.1 == kind }) {
                let open = stack.remove(at: index).0
                pairs.append(Pair(open: NSRange(location: mapped(open.location), length: open.length),
                                  close: NSRange(location: mapped(marker.location), length: marker.length),
                                  original: NSRange(location: open.location, length: NSMaxRange(marker) - open.location)))
            }
        }
        pairs.sort { $0.original.length < $1.original.length }
        let result = NSMutableString(string: source)
        result.replaceCharacters(in: edit.range, with: edit.replacement)
        var scope = edit.range
        var caret = edit.caret
        func remove(_ range: NSRange) {
            result.deleteCharacters(in: range)
            func shifted(_ position: Int) -> Int {
                position <= range.location ? position : max(range.location, position - range.length)
            }
            caret = shifted(caret)
            for index in pairs.indices {
                pairs[index].open.location = shifted(pairs[index].open.location)
                pairs[index].close.location = shifted(pairs[index].close.location)
            }
        }
        for index in pairs.indices {
            let pair = pairs[index]
            let contentStart = NSMaxRange(pair.open)
            let content = result.substring(with: NSRange(location: contentStart, length: pair.close.location - contentStart))
            let leading = String(content.prefix(while: { $0.isWhitespace }))
            let trailing = String(content.dropFirst(leading.count).reversed().prefix(while: { $0.isWhitespace }).reversed())
            guard !leading.isEmpty || !trailing.isEmpty || content.isEmpty else { continue }
            scope = NSUnionRange(scope, pair.original)
            if leading.utf16.count == content.utf16.count {
                remove(pair.close)
                remove(pair.open)
                continue
            }
            let body = String(content.dropFirst(leading.count).dropLast(trailing.count))
            let open = result.substring(with: pair.open)
            let close = result.substring(with: pair.close)
            let full = NSRange(location: pair.open.location, length: NSMaxRange(pair.close) - pair.open.location)
            let bodyEnd = pair.close.location - trailing.utf16.count
            if caret >= contentStart && caret <= contentStart + leading.utf16.count {
                caret = pair.open.location + caret - contentStart
            } else if !trailing.isEmpty && caret >= bodyEnd && caret <= pair.close.location {
                caret += pair.close.length
            }
            result.replaceCharacters(in: full, with: leading + open + body + close + trailing)
        }
        let length = scope.length + result.length - source.length
        return Edit(range: scope, replacement: result.substring(with: NSRange(location: scope.location, length: length)), caret: caret)
    }

    /// AppKit's proposed endpoints are source offsets, including zero-width
    /// markers. Normalize only endpoints inside parsed markers; literal code and
    /// the editor's reveal-on-entry styling policy are unaffected.
    static func selection(in source: NSString, from old: NSRange, to proposed: NSRange,
                          tokens: [MarkdownToken], characterStep: Bool, formatted: Bool = false) -> NSRange {
        let markers = formatted ? hiddenMarkerRanges(in: source as String, tokens: tokens) : formats(in: tokens).flatMap(\.markerRanges)
        func endpoint(_ target: Int, from origin: Int, characterStep: Bool) -> Int {
            guard target != origin || formatted,
                  let marker = markers.first(where: { target >= $0.location && target <= NSMaxRange($0) }) else { return target }
            let backward = target < origin
            var position = target
            if characterStep, abs(target - origin) <= marker.length,
               let character = characterRange(in: source, at: origin, backward: backward, tokens: tokens, formatted: formatted) {
                position = backward ? character.location : NSMaxRange(character)
            }
            while let enclosing = markers.first(where: {
                backward ? position > $0.location && position <= NSMaxRange($0)
                    : position >= $0.location && position < NSMaxRange($0)
            }) {
                position = backward ? enclosing.location : NSMaxRange(enclosing)
            }
            return position
        }
        if proposed.length == 0 {
            return NSRange(location: endpoint(proposed.location, from: old.location, characterStep: characterStep && old.length == 0), length: 0)
        }
        let start = endpoint(proposed.location, from: old.location, characterStep: characterStep)
        let end = endpoint(NSMaxRange(proposed), from: NSMaxRange(old), characterStep: characterStep)
        return NSRange(location: min(start, end), length: abs(end - start))
    }
}

extension NativeTextView {
    private func withInlineNavigation(characterStep: Bool, _ perform: () -> Void) {
        let key = ObjectIdentifier(self)
        let previous = MarkdownInlineEditing.navigationSteps[key]
        MarkdownInlineEditing.navigationSteps[key] = characterStep
        defer { MarkdownInlineEditing.navigationSteps[key] = previous }
        perform()
    }

    override func moveLeft(_ sender: Any?) {
        withInlineNavigation(characterStep: true) { super.moveLeft(sender) }
    }
    override func moveForward(_ sender: Any?) {
        withInlineNavigation(characterStep: true) { super.moveForward(sender) }
    }
    override func moveBackward(_ sender: Any?) {
        withInlineNavigation(characterStep: true) { super.moveBackward(sender) }
    }
    override func moveForwardAndModifySelection(_ sender: Any?) {
        withInlineNavigation(characterStep: true) { super.moveForwardAndModifySelection(sender) }
    }
    override func moveBackwardAndModifySelection(_ sender: Any?) {
        withInlineNavigation(characterStep: true) { super.moveBackwardAndModifySelection(sender) }
    }
    override func moveUp(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveUp(sender) }
    }
    override func moveDown(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveDown(sender) }
    }
    override func moveUpAndModifySelection(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveUpAndModifySelection(sender) }
    }
    override func moveDownAndModifySelection(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveDownAndModifySelection(sender) }
    }
    override func moveWordForward(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveWordForward(sender) }
    }
    override func moveWordBackward(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveWordBackward(sender) }
    }
    override func moveWordForwardAndModifySelection(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveWordForwardAndModifySelection(sender) }
    }
    override func moveWordBackwardAndModifySelection(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveWordBackwardAndModifySelection(sender) }
    }
    override func moveRight(_ sender: Any?) {
        withInlineNavigation(characterStep: true) { super.moveRight(sender) }
    }
    override func moveLeftAndModifySelection(_ sender: Any?) {
        withInlineNavigation(characterStep: true) { super.moveLeftAndModifySelection(sender) }
    }
    override func moveRightAndModifySelection(_ sender: Any?) {
        withInlineNavigation(characterStep: true) { super.moveRightAndModifySelection(sender) }
    }
    override func moveWordLeft(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveWordLeft(sender) }
    }
    override func moveWordRight(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveWordRight(sender) }
    }
    override func moveWordLeftAndModifySelection(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveWordLeftAndModifySelection(sender) }
    }
    override func moveWordRightAndModifySelection(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveWordRightAndModifySelection(sender) }
    }
    override func moveToBeginningOfLine(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveToBeginningOfLine(sender) }
    }
    override func moveToEndOfLine(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveToEndOfLine(sender) }
    }
    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveToBeginningOfLineAndModifySelection(sender) }
    }
    override func moveToEndOfLineAndModifySelection(_ sender: Any?) {
        withInlineNavigation(characterStep: false) { super.moveToEndOfLineAndModifySelection(sender) }
    }
}
