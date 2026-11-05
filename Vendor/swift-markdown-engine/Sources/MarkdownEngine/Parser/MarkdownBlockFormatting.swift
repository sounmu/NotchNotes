import AppKit

extension MarkdownFormatting {
    public enum BlockStyle: Equatable {
        case quote, unorderedList, orderedList, taskList, heading(Int)
    }

    /// Shared toolbar/menu command. Only block prefixes change; line endings,
    /// inline source, and indentation remain intact.
    @discardableResult
    public static func applyBlock(_ style: BlockStyle, in view: NSTextView) -> Bool {
        guard let coordinator = view.delegate as? NativeTextViewCoordinator,
              coordinator.configuration.inlineEditingMode == .formatted else { return false }
        guard view.isEditable, !view.hasMarkedText() else { return true }
        let source = view.string as NSString
        let range = source.lineRange(for: view.selectedRange())
        let tokens = MarkdownTokenizer.parseTokens(in: view.string)
        if tokens.contains(where: { $0.kind == .codeBlock && NSIntersectionRange($0.range, range).length > 0 }) { return true }
        struct Line {
            let indent: String
            let body: String
            let ending: String
            let kind: BlockStyle?
        }
        var lines: [Line] = []
        var location = range.location
        repeat {
            var start = 0, end = 0, contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let raw = source.substring(with: NSRange(location: start, length: contentsEnd - start))
            let indent = MarkdownLists.leadingWhitespace(in: raw)
            var body = String(raw.dropFirst(indent.count))
            var kind: BlockStyle?
            if let list = MarkdownLists.listContext(for: raw) {
                kind = list.hasCheckbox ? .taskList : (list.number != nil ? .orderedList : .unorderedList)
                body = (raw as NSString).substring(from: list.prefixLength)
            } else if body.hasPrefix("> ") {
                kind = .quote
                body = String(body.dropFirst(2))
            } else {
                let hashes = body.prefix { $0 == "#" }.count
                if (1...6).contains(hashes), body.dropFirst(hashes).hasPrefix(" ") {
                    kind = .heading(hashes)
                    body = String(body.dropFirst(hashes + 1))
                }
            }
            lines.append(Line(indent: indent, body: body,
                ending: source.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)), kind: kind))
            guard end > location else { break }
            location = end
        } while location < NSMaxRange(range)
        let removing = lines.allSatisfy { $0.kind == style }
        let replacement = lines.enumerated().map { index, line -> String in
            let prefix: String
            if removing { prefix = "" } else {
                switch style {
                case .quote: prefix = "> "
                case .unorderedList: prefix = "- "
                case .orderedList: prefix = "\(index + 1). "
                case .taskList: prefix = "- [ ] "
                case .heading(let level): prefix = String(repeating: "#", count: min(6, max(1, level))) + " "
                }
            }
            return line.indent + prefix + line.body + line.ending
        }.joined()
        replaceSource(in: view, range: range, with: replacement,
                      selectionAfter: NSRange(location: range.location, length: replacement.utf16.count))
        return true
    }
}
