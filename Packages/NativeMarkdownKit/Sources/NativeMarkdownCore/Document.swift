import Foundation
import Markdown

public enum InlineMark: String, Codable, Hashable, Sendable, CaseIterable {
    case bold, italic, strikethrough, code
}

public struct TextRun: Equatable, Codable, Sendable {
    public var text: String
    public var marks: Set<InlineMark>
    public var link: String?
    public init(_ text: String, marks: Set<InlineMark> = [], link: String? = nil) { self.text = text; self.marks = marks; self.link = link }
}

public enum BlockKind: Equatable, Codable, Sendable {
    case paragraph
    case heading(Int)
    case quote
    case bullet(depth: Int)
    case ordered(number: UInt, depth: Int)
    case task(checked: Bool, depth: Int)
    case code(language: String?)
}

public struct Block: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var kind: BlockKind
    public var runs: [TextRun]
    public var text: String { runs.map(\.text).joined() }
    public init(id: UUID = UUID(), kind: BlockKind = .paragraph, runs: [TextRun] = []) {
        self.id = id; self.kind = kind; self.runs = runs
    }
}

public enum EditingError: Error, Equatable {
    case unsupportedMarkdown(String)
    case invalidRange
    case missingBlock
    case notATask
}

/// Source delimiters never enter the editable model. All offsets refer to
/// visible UTF-16 within a block, and block identity survives transactions.
public struct MarkdownDocument: Equatable, Codable, Sendable {
    public var blocks: [Block]
    public init(blocks: [Block] = [Block()]) { self.blocks = blocks.isEmpty ? [Block()] : blocks }

    public init(markdown: String) throws {
        var result: [Block] = []
        try Self.readBlocks(Markdown.Document(parsing: markdown).children, into: &result)
        self.init(blocks: result)
    }

    private static func readBlocks(_ nodes: some Sequence<Markup>, into result: inout [Block], depth: Int = 0) throws {
        for node in nodes {
            switch node {
            case let paragraph as Paragraph:
                result.append(Block(runs: try runs(paragraph.children)))
            case let heading as Heading:
                result.append(Block(kind: .heading(heading.level), runs: try runs(heading.children)))
            case let quote as BlockQuote:
                for child in quote.children {
                    guard let paragraph = child as? Paragraph else { throw EditingError.unsupportedMarkdown("nested block quote") }
                    result.append(Block(kind: .quote, runs: try runs(paragraph.children)))
                }
            case let code as CodeBlock:
                result.append(Block(kind: .code(language: code.language), runs: [TextRun(code.code)]))
            case let list as UnorderedList:
                try readList(list.children, start: nil, depth: depth, into: &result)
            case let list as OrderedList:
                try readList(list.children, start: list.startIndex, depth: depth, into: &result)
            default: throw EditingError.unsupportedMarkdown(String(describing: type(of: node)))
            }
        }
    }

    private static func readList(_ nodes: some Sequence<Markup>, start: UInt?, depth: Int, into result: inout [Block]) throws {
        for (index, node) in nodes.enumerated() {
            guard let item = node as? ListItem, let paragraph = item.children.first(where: { _ in true }) as? Paragraph else {
                throw EditingError.unsupportedMarkdown("non-paragraph list item")
            }
            let kind: BlockKind
            if let checkbox = item.checkbox {
                guard start == nil else { throw EditingError.unsupportedMarkdown("ordered task list") }
                kind = .task(checked: checkbox == .checked, depth: depth)
            } else if let start { kind = .ordered(number: start + UInt(index), depth: depth) }
            else { kind = .bullet(depth: depth) }
            result.append(Block(kind: kind, runs: try runs(paragraph.children)))
            for nested in item.children.dropFirst() {
                guard nested is UnorderedList || nested is OrderedList else { throw EditingError.unsupportedMarkdown("multi-paragraph list item") }
                try readBlocks([nested], into: &result, depth: depth + 1)
            }
        }
    }

    private static func runs(_ nodes: some Sequence<Markup>, marks: Set<InlineMark> = [], link: String? = nil) throws -> [TextRun] {
        var result: [TextRun] = []
        for node in nodes {
            switch node {
            case let text as Text: result.append(TextRun(text.string, marks: marks, link: link))
            case let code as InlineCode: result.append(TextRun(code.code, marks: marks.union([.code]), link: link))
            case let strong as Strong: result += try runs(strong.children, marks: marks.union([.bold]), link: link)
            case let emphasis as Emphasis: result += try runs(emphasis.children, marks: marks.union([.italic]), link: link)
            case let strike as Strikethrough: result += try runs(strike.children, marks: marks.union([.strikethrough]), link: link)
            case let anchor as Link:
                guard anchor.title == nil || anchor.title == "" else { throw EditingError.unsupportedMarkdown("link title") }
                result += try runs(anchor.children, marks: marks, link: anchor.destination)
            // Retain the distinction: soft wraps are normalized into a space;
            // hard breaks remain visible newlines.
            case is SoftBreak: result.append(TextRun(" ", marks: marks, link: link))
            case is LineBreak: result.append(TextRun("\n", marks: marks, link: link))
            default: throw EditingError.unsupportedMarkdown(String(describing: type(of: node)))
            }
        }
        return result
    }

    public func markdown() -> String {
        var result = "", previousWasList = false
        var listIndents = [0]
        for block in blocks {
            let depth = max(0, block.kind.listDepth ?? 0)
            let indent = listIndents[min(depth, listIndents.count - 1)]
            listIndents = Array(listIndents.prefix(depth + 1))
            let body: String
            let isList: Bool
            let inline = Self.inlineRuns(block.runs)
            // Swift Markdown formats the inline tree, but its formatter assumes
            // text is already escaped and doesn't choose safe code delimiters.
            let rendered = Paragraph(inline).format().trimmingCharacters(in: .newlines)
            switch block.kind {
            case .paragraph: body = rendered; isList = false
            case .heading(let level): body = String(repeating: "#", count: max(1, min(6, level))) + " " + rendered; isList = false
            case .quote: body = rendered.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n"); isList = false
            case .code(let language):
                let marker: Character = language?.contains("`") == true ? "~" : "`"
                let fence = String(repeating: String(marker), count: max(3, Self.longestRun(block.text, of: marker) + 1))
                body = fence + (language ?? "") + "\n" + block.text + (block.text.hasSuffix("\n") ? "" : "\n") + fence
                isList = false
            case .bullet:
                body = Self.listBody(rendered, prefix: "- ", indent: indent); isList = true
                listIndents.append(indent + 4)
            case .ordered(let number, _):
                let prefix = "\(number). "
                body = Self.listBody(rendered, prefix: prefix, indent: indent); isList = true
                listIndents.append(indent + max(4, prefix.count))
            case .task(let checked, _):
                body = Self.listBody(rendered, prefix: checked ? "- [x] " : "- [ ] ", indent: indent); isList = true
                listIndents.append(indent + 4)
            }
            if !isList { listIndents = [0] }
            if !result.isEmpty { result += isList && previousWasList ? "\n" : "\n\n" }
            result += body; previousWasList = isList
        }
        return result
    }

    private static func inlineRuns(_ runs: [TextRun]) -> [any InlineMarkup] {
        var result: [any InlineMarkup] = [], start = 0
        while start < runs.count {
            var end = start + 1
            while end < runs.count, runs[end].link == runs[start].link { end += 1 }
            var lines: [[TextRun]] = [[]]
            for run in runs[start..<end] {
                for (index, part) in run.text.components(separatedBy: "\n").enumerated() {
                    if index > 0 { lines.append([]) }
                    lines[lines.count - 1].append(TextRun(part, marks: run.marks))
                }
            }
            var content: [any RecurringInlineMarkup] = []
            for (index, line) in lines.enumerated() {
                if index > 0 { content.append(LineBreak()) }
                let mixedEmphasis = line.contains { $0.marks.contains(.bold) } && line.contains { $0.marks.contains(.italic) }
                content += inlineMarks(line, level: 0, mixedEmphasis: mixedEmphasis)
            }
            if let destination = runs[start].link {
                let wrapped = destination.contains { $0.isWhitespace || "()<>\\".contains($0) }
                result.append(Link(destination: wrapped ? "<" + escape(destination) + ">" : destination, content))
            }
            else { result += content.map { $0 as any InlineMarkup } }
            start = end
        }
        return result
    }

    /// Shared marks span adjacent runs. Whitespace at a mark boundary is moved
    /// outside its delimiter, as required by CommonMark's flanking rules.
    private static func inlineMarks(_ runs: [TextRun], level: Int, mixedEmphasis: Bool) -> [any RecurringInlineMarkup] {
        let order: [InlineMark] = [.bold, .italic, .strikethrough, .code]
        guard level < order.count else { return [Text(escape(runs.map(\.text).joined()))] }
        let mark = order[level]
        var result: [any RecurringInlineMarkup] = [], start = 0
        while start < runs.count {
            let enabled = runs[start].marks.contains(mark)
            var end = start + 1
            while end < runs.count, runs[end].marks.contains(mark) == enabled { end += 1 }
            let group = Array(runs[start..<end])
            if !enabled {
                var children = inlineMarks(group, level: level + 1, mixedEmphasis: mixedEmphasis)
                // Flanking depends on the emitted edge, including nested code
                // delimiters and escaped or Unicode punctuation, not raw text.
                if mark != .code {
                    let punctuation = CharacterSet.punctuationCharacters.union(Self.escapablePunctuation)
                    let previousEdge = start > 0
                        ? Paragraph(inlineMarks([runs[start - 1]], level: level + 1, mixedEmphasis: mixedEmphasis)).format().last : nil
                    let nextEdge = end < runs.count
                        ? Paragraph(inlineMarks([runs[end]], level: level + 1, mixedEmphasis: mixedEmphasis)).format().first : nil
                    let afterDelimiter = start > 0 && ((mark == .bold && mixedEmphasis) ||
                        previousEdge?.unicodeScalars.contains(where: punctuation.contains) == true)
                    let beforeDelimiter = end < runs.count && ((mark == .bold && mixedEmphasis) ||
                        nextEdge?.unicodeScalars.contains(where: punctuation.contains) == true)
                    if afterDelimiter, let first = children.first as? Text, let character = first.string.first,
                       character.isLetter || character.isNumber {
                        let entity = character.unicodeScalars.map { "&#\($0.value);" }.joined()
                        children[0] = Text(entity + first.string.dropFirst())
                    }
                    if beforeDelimiter, let last = children.last as? Text, let character = last.string.last,
                       character.isLetter || character.isNumber {
                        let entity = character.unicodeScalars.map { "&#\($0.value);" }.joined()
                        children[children.count - 1] = Text(last.string.dropLast() + entity)
                    }
                }
                result += children
            }
            else if mark == .code { result.append(Text(codeSpan(group.map(\.text).joined()))) }
            else {
                let text = group.map(\.text).joined()
                let leadingText = group.prefix(while: { !$0.marks.contains(.code) }).map(\.text).joined()
                let leading = String(leadingText.prefix(while: { $0.isWhitespace }))
                let remaining = text.dropFirst(leading.count)
                let trailingText = group.reversed().prefix(while: { !$0.marks.contains(.code) }).reversed().map(\.text).joined()
                let trailing = String(trailingText.suffix(remaining.count).reversed().prefix(while: { $0.isWhitespace }).reversed())
                let length = text.utf16.count - leading.utf16.count - trailing.utf16.count
                if !leading.isEmpty { result.append(Text(leading)) }
                if length > 0 {
                    let middle = DocumentEditing.slice(group, NSRange(location: leading.utf16.count, length: length))
                    let children = inlineMarks(middle, level: level + 1, mixedEmphasis: mixedEmphasis)
                    switch mark {
                    case .bold:
                        if mixedEmphasis { result.append(Text("__" + Paragraph(children).format().trimmingCharacters(in: .newlines) + "__")) }
                        else { result.append(Strong(children)) }
                    case .italic: result.append(Emphasis(children))
                    case .strikethrough: result.append(Strikethrough(children))
                    case .code: break
                    }
                }
                if !trailing.isEmpty { result.append(Text(trailing)) }
            }
            start = end
        }
        return result
    }

    private static let escapablePunctuation = CharacterSet(charactersIn: "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    private static func escape(_ text: String) -> String {
        return text.reduce(into: "") { result, character in
            if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first, escapablePunctuation.contains(scalar) { result += "\\" }
            result.append(character)
        }
    }
    private static func longestRun(_ text: String, of marker: Character) -> Int {
        var longest = 0, current = 0
        for character in text { current = character == marker ? current + 1 : 0; longest = max(longest, current) }
        return longest
    }
    private static func codeSpan(_ text: String) -> String {
        let fence = String(repeating: "`", count: longestRun(text, of: "`") + 1)
        let pad = !text.allSatisfy { $0 == " " } && (text.first == "`" || text.last == "`" || (text.first == " " && text.last == " "))
        return fence + (pad ? " " : "") + text + (pad ? " " : "") + fence
    }

    private static func listBody(_ text: String, prefix: String, indent: Int) -> String {
        let indent = String(repeating: " ", count: indent)
        return text.components(separatedBy: "\n").enumerated().map { index, line in
            indent + (index == 0 ? prefix : String(repeating: " ", count: prefix.count)) + line
        }.joined(separator: "\n")
    }
}
