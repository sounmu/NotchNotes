import AppKit

/// A small source-local projection: only the selection and intersecting inline
/// pairs are serialized. Everything outside that footprint stays byte-for-byte.
enum MarkdownFormattedEditing {
    typealias Style = MarkdownFormatting.InlineStyle
    struct TypingState {
        let source: String
        let caret: Int
        let styles: Set<Style>

        func styles(in view: NSTextView) -> Set<Style>? {
            source == view.string && view.selectedRange() == NSRange(location: caret, length: 0) ? styles : nil
        }
    }
    struct Edit {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }
    private struct Atom {
        let text: String
        let source: NSRange
        var styles: Set<Style>
        var literalSource = false
    }
    private static let order: [Style] = [.bold, .italic, .strikethrough, .code]
    private static func marker(_ style: Style) -> String {
        switch style {
        case .bold: return "**"
        case .italic: return "*"
        case .strikethrough: return "~~"
        case .code: return "`"
        }
    }
    private static func styles(_ token: MarkdownToken) -> Set<Style> {
        switch token.kind {
        case .bold: return [.bold]
        case .italic: return [.italic]
        case .boldItalic: return [.bold, .italic]
        case .strikethrough: return [.strikethrough]
        case .inlineCode: return [.code]
        default: return []
        }
    }
    private static func formats(in text: String, tokens knownTokens: [MarkdownToken]? = nil) -> [MarkdownToken] {
        let tokens = knownTokens ?? MarkdownTokenizer.parseTokens(in: text)
        let code = tokens.filter { $0.kind == .inlineCode || $0.kind == .codeBlock }
        return tokens.filter { token in
            !styles(token).isEmpty && !code.contains {
                $0.range != token.range && NSIntersectionRange($0.range, token.range) == token.range
            }
        }
    }
    static func styles(at caret: Int, in text: String, tokens: [MarkdownToken]? = nil) -> Set<Style> {
        formats(in: text, tokens: tokens).reduce(into: []) { result, token in
            if caret >= token.contentRange.location && caret <= NSMaxRange(token.range) {
                result.formUnion(styles(token))
            }
        }
    }
    static func replacementStyles(in text: String, range: NSRange, tokens: [MarkdownToken]? = nil) -> Set<Style> {
        if range.length > 0, let (_, atoms) = projection(in: text, range: range),
           let first = atoms.first(where: { NSIntersectionRange($0.source, range).length > 0 }) {
            return first.styles
        }
        return styles(at: range.location, in: text, tokens: tokens)
    }
    static func selectionStates(in text: String, range: NSRange) -> [Style: MarkdownFormatting.SelectionState] {
        guard let (_, atoms) = projection(in: text, range: range) else { return [:] }
        let selected = atoms.filter { !$0.literalSource && !$0.text.allSatisfy(\.isWhitespace) && NSIntersectionRange($0.source, range).length > 0 }
        return Dictionary(uniqueKeysWithValues: Style.allCases.map { style in
            let count = selected.filter { $0.styles.contains(style) }.count
            let state: MarkdownFormatting.SelectionState = count == 0 ? .off : (count == selected.count ? .on : .mixed)
            return (style, state)
        })
    }
    private static func projection(in text: String, range: NSRange) -> (NSRange, [Atom])? {
        let source = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= source.length else { return nil }
        let tokens = formats(in: text)
        var footprint = range
        var changed = true
        while changed {
            changed = false
            for token in tokens {
                let touches = NSIntersectionRange(footprint, token.range).length > 0
                    || (footprint.length == 0 && footprint.location >= token.contentRange.location
                        && footprint.location <= NSMaxRange(token.range))
                if touches {
                    let expanded = NSUnionRange(footprint, token.range)
                    if expanded != footprint { footprint = expanded; changed = true }
                }
            }
        }
        let allTokens = MarkdownTokenizer.parseTokens(in: text)
        let escapes = MarkdownEscaping.markerRanges(in: text, tokens: allTokens)
        for escape in escapes {
            let pair = NSRange(location: escape.location, length: 2)
            if NSIntersectionRange(pair, footprint).length > 0 { footprint = NSUnionRange(footprint, pair) }
        }
        let relevant = tokens.filter { NSIntersectionRange($0.range, footprint).length > 0 }
        let markers = relevant.flatMap(\.markerRanges) + escapes
        let protected = protectedRanges(in: text, tokens: allTokens)
        var atoms: [Atom] = []
        var offset = footprint.location
        while offset < NSMaxRange(footprint) {
            let character = source.rangeOfComposedCharacterSequence(at: offset)
            if !markers.contains(where: { NSIntersectionRange($0, character).length > 0 }) {
                let marks = relevant.reduce(into: Set<Style>()) { result, token in
                    if NSIntersectionRange(token.contentRange, character).length > 0 { result.formUnion(styles(token)) }
                }
                let escaped = escapes.contains { NSMaxRange($0) == character.location }
                let atomRange = escaped ? NSRange(location: character.location - 1, length: character.length + 1) : character
                let literal = protected.contains { NSIntersectionRange($0, character).length > 0 }
                atoms.append(Atom(text: source.substring(with: character), source: atomRange,
                                  styles: literal ? [] : marks, literalSource: literal))
            }
            offset = NSMaxRange(character)
        }
        return (footprint, atoms)
    }

    private static let blockPrefix = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:(?:#{1,6}|>|[-+*•]|[0-9]+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)"#,
        options: [.anchorsMatchLines])

    private static func protectedRanges(in text: String, tokens: [MarkdownToken]) -> [NSRange] {
        blockPrefix.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map(\.range)
            + tokens.filter { [.codeBlock, .inlineLatex, .blockLatex, .imageEmbed].contains($0.kind) }.map(\.range)
    }
    static func toggle(_ style: Style, in text: String, range: NSRange) -> Edit? {
        guard let (footprint, projected) = projection(in: text, range: range) else { return nil }
        var atoms = projected
        // Block syntax and code contents are literal, not emphasis candidates.
        let blocks = MarkdownTokenizer.parseTokens(in: text).filter { $0.kind == .codeBlock }
        let indices = atoms.indices.filter { index in
            NSIntersectionRange(atoms[index].source, range).length > 0
                && !atoms[index].literalSource
                && !atoms[index].text.allSatisfy(\.isWhitespace)
                && (style == .code || !atoms[index].styles.contains(.code))
                && !blocks.contains(where: { NSIntersectionRange($0.range, atoms[index].source).length > 0 })
        }
        guard !indices.isEmpty else { return nil }
        let remove = indices.allSatisfy { atoms[$0].styles.contains(style) }
        // Include interior spaces; the serializer keeps edge whitespace outside pairs.
        let first = indices.first!, last = indices.last!
        for index in first...last {
            if atoms[index].literalSource { continue }
            if style != .code && atoms[index].styles.contains(.code) { continue }
            if blocks.contains(where: { NSIntersectionRange($0.range, atoms[index].source).length > 0 }) { continue }
            if remove { atoms[index].styles.remove(style) } else { atoms[index].styles.insert(style) }
        }
        return serialize(atoms, footprint: footprint, selected: first..<(last + 1))
    }
    static func insertion(in text: String, range: NSRange, replacement: String, styles: Set<Style>, literal: Bool = false,
                          tokens: [MarkdownToken]? = nil) -> Edit? {
        // Ordinary typing inside unchanged marks needs no span-wide projection.
        // Keep this path source-local even for a very long formatted paragraph.
        if !literal, range.length == 0, !styles.isEmpty, !replacement.isEmpty,
           replacement.allSatisfy({ !$0.isWhitespace && !["*", "~", "`", "\\", "_"].contains($0) }) {
            let active = formats(in: text, tokens: tokens).filter {
                range.location >= $0.contentRange.location && range.location <= NSMaxRange($0.range)
            }
            let inherited = active.reduce(into: Set<Style>()) { $0.formUnion(Self.styles($1)) }
            if inherited == styles, let end = active.map({ NSMaxRange($0.contentRange) }).min() {
                let location = min(range.location, end)
                return Edit(range: NSRange(location: location, length: 0), replacement: replacement,
                            selection: NSRange(location: location + replacement.utf16.count, length: 0))
            }
        }
        guard let (footprint, projected) = projection(in: text, range: range) else { return nil }
        var atoms = projected
        let start = atoms.firstIndex { NSMaxRange($0.source) > range.location } ?? atoms.count
        let end = atoms.firstIndex { $0.source.location >= NSMaxRange(range) } ?? atoms.count
        let inserted = replacement.map { Atom(text: String($0), source: range, styles: literal ? [] : styles, literalSource: literal) }
        atoms.replaceSubrange(start..<max(start, end), with: inserted)
        return serialize(atoms, footprint: footprint, selected: (start + inserted.count)..<(start + inserted.count))
    }

    static func richTextInsertion(_ content: NSAttributedString, in text: String, range: NSRange) -> Edit? {
        guard let (footprint, projected) = projection(in: text, range: range) else { return nil }
        var atoms = projected
        let start = atoms.firstIndex { NSMaxRange($0.source) > range.location } ?? atoms.count
        let end = atoms.firstIndex { $0.source.location >= NSMaxRange(range) } ?? atoms.count
        var offset = 0
        let inserted = content.string.map { character -> Atom in
            let attributes = content.attributes(at: offset, effectiveRange: nil)
            var marks = Set<Style>()
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { marks.insert(.bold) }
                if traits.contains(.italic) { marks.insert(.italic) }
                if traits.contains(.monoSpace) { marks.insert(.code) }
            }
            if let strike = attributes[.strikethroughStyle] as? NSNumber, strike.intValue != 0 { marks.insert(.strikethrough) }
            let value = String(character)
            offset += value.utf16.count
            return Atom(text: value, source: range, styles: marks)
        }
        atoms.replaceSubrange(start..<max(start, end), with: inserted)
        return serialize(atoms, footprint: footprint, selected: (start + inserted.count)..<(start + inserted.count))
    }
    private static func serialize(_ original: [Atom], footprint: NSRange, selected: Range<Int>) -> Edit {
        var atoms = original
        // Markdown delimiters must not enclose leading/trailing whitespace or newlines.
        for style in order {
            var start = 0
            while start < atoms.count {
                guard atoms[start].styles.contains(style), !atoms[start].text.contains(where: \.isNewline) else {
                    if atoms[start].text.contains(where: \.isNewline) { atoms[start].styles.remove(style) }
                    start += 1; continue
                }
                var end = start + 1
                while end < atoms.count && atoms[end].styles.contains(style) && !atoms[end].text.contains(where: \.isNewline) { end += 1 }
                var left = start, right = end
                while style != .code && left < right && atoms[left].text.allSatisfy(\.isWhitespace) { atoms[left].styles.remove(style); left += 1 }
                while style != .code && right > left && atoms[right - 1].text.allSatisfy(\.isWhitespace) { right -= 1; atoms[right].styles.remove(style) }
                start = end
            }
        }
        var codeMarkers: [Int: (String, String)] = [:]
        var cursor = 0
        while cursor < atoms.count {
            guard atoms[cursor].styles.contains(.code) else { cursor += 1; continue }
            let start = cursor
            var longest = 0, run = 0
            while cursor < atoms.count && atoms[cursor].styles == atoms[start].styles {
                if atoms[cursor].text == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
                cursor += 1
            }
            let fence = String(repeating: "`", count: longest + 1)
            let allSpaces = atoms[start..<cursor].allSatisfy { $0.text == " " }
            let pad = !allSpaces && (["`", " "].contains(atoms[start].text) || ["`", " "].contains(atoms[cursor - 1].text))
            for index in start..<cursor { codeMarkers[index] = (fence + (pad ? " " : ""), (pad ? " " : "") + fence) }
        }
        var output = "", outputLength = 0, stack: [Style] = [], starts: [Int] = [], ends: [Int] = []
        var closingCode = "`"
        func append(_ value: String) { output += value; outputLength += value.utf16.count }
        for (index, atom) in atoms.enumerated() {
            // Longest-lived traits go outside shorter runs. This keeps a
            // surviving italic span intact when bold is removed from its middle.
            let active = order.filter { atom.styles.contains($0) }
            // Code is always innermost: emphasis delimiters must never become
            // literal code characters when a mixed selection gains code style.
            let retained = stack.prefix { $0 != .code && atom.styles.contains($0) }
            let new = active.filter { $0 != .code && !retained.contains($0) }.sorted { left, right in
                func end(_ style: Style) -> Int {
                    atoms[index...].firstIndex { !$0.styles.contains(style) } ?? atoms.count
                }
                return end(left) > end(right)
            }
            let next = Array(retained) + new + (atom.styles.contains(.code) ? [.code] : [])
            var common = 0
            while common < min(stack.count, next.count) && stack[common] == next[common] { common += 1 }
            for style in stack.dropFirst(common).reversed() { append(style == .code ? closingCode : marker(style)) }
            for style in next.dropFirst(common) {
                if style == .code {
                    let pair = codeMarkers[index] ?? ("`", "`")
                    append(pair.0)
                    closingCode = pair.1
                } else { append(marker(style)) }
            }
            starts.append(outputLength)
            append(atom.literalSource || atom.styles.contains(.code) ? atom.text : MarkdownEscaping.literal(atom.text))
            ends.append(outputLength)
            stack = next
        }
        let caret = selected.lowerBound == 0 ? (starts.first ?? 0) : ends[selected.lowerBound - 1]
        let lower = selected.isEmpty ? caret : starts[selected.lowerBound]
        let upper = selected.isEmpty ? caret : ends[selected.upperBound - 1]
        for style in stack.reversed() { append(style == .code ? closingCode : marker(style)) }
        return Edit(range: footprint, replacement: output,
                    selection: NSRange(location: footprint.location + lower, length: upper - lower))
    }
}
