import Foundation

public extension MarkdownDocument {
    /// One newline separates blocks. All editor positions refer to this visible
    /// string, never to serialized Markdown or decorative list markers.
    var visibleText: String { blocks.map(\.text).joined(separator: "\n") }
    var blockRanges: [NSRange] {
        var offset = 0
        return blocks.map { block in
            defer { offset += block.text.utf16.count + 1 }
            return NSRange(location: offset, length: block.text.utf16.count)
        }
    }

    func validate(_ range: NSRange) throws {
        let text = visibleText
        guard range.location >= 0, range.length >= 0, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location else { throw EditingError.invalidRange }
        var boundaries: Set<Int> = [0], offset = 0
        for character in text { offset += String(character).utf16.count; boundaries.insert(offset) }
        guard boundaries.contains(range.location), boundaries.contains(NSMaxRange(range)) else { throw EditingError.invalidRange }
    }

    func blockIndex(at offset: Int) -> Int {
        blockRanges.firstIndex(where: { offset <= NSMaxRange($0) }) ?? max(0, blocks.count - 1)
    }

    func marks(at offset: Int) -> Set<InlineMark> {
        let index = blockIndex(at: offset), start = blockRanges[index].location
        var position = start
        for run in blocks[index].runs {
            position += run.text.utf16.count
            if position >= offset { return run.marks }
        }
        return []
    }

    func formatting(in range: NSRange) -> (active: Set<InlineMark>, mixed: Set<InlineMark>) {
        if range.length == 0 { return (marks(at: range.location), []) }
        var all: Set<InlineMark>?, any: Set<InlineMark> = []
        let ranges = blockRanges
        for (index, block) in blocks.enumerated() {
            var offset = ranges[index].location
            for run in block.runs {
                let span = NSRange(location: offset, length: run.text.utf16.count)
                offset = NSMaxRange(span)
                if NSIntersectionRange(span, range).length > 0 {
                    all = all.map { $0.intersection(run.marks) } ?? run.marks
                    any.formUnion(run.marks)
                }
            }
        }
        return (all ?? [], any.subtracting(all ?? []))
    }
}

extension BlockKind {
    var listDepth: Int? {
        switch self {
        case .bullet(let depth), .ordered(_, let depth), .task(_, let depth): return depth
        default: return nil
        }
    }
    var continuation: BlockKind {
        switch self {
        case .task(_, let depth): return .task(checked: false, depth: depth)
        case .ordered(let number, let depth): return .ordered(number: number == UInt.max ? number : number + 1, depth: depth)
        case .bullet, .quote: return self
        default: return .paragraph
        }
    }
    func atDepth(_ depth: Int) -> BlockKind {
        switch self {
        case .bullet: return .bullet(depth: depth)
        case .ordered(let number, _): return .ordered(number: number, depth: depth)
        case .task(let checked, _): return .task(checked: checked, depth: depth)
        default: return self
        }
    }
}

enum DocumentEditing {
    static func link(at offset: Int, in runs: [TextRun]) -> String? {
        var position = 0
        for run in runs {
            position += run.text.utf16.count
            if position >= offset { return run.link }
        }
        return nil
    }

    static func slice(_ runs: [TextRun], _ range: NSRange) -> [TextRun] {
        var offset = 0
        return runs.compactMap { run in
            let span = NSRange(location: offset, length: run.text.utf16.count)
            offset = NSMaxRange(span)
            let overlap = NSIntersectionRange(span, range)
            guard overlap.length > 0 else { return nil }
            return TextRun((run.text as NSString).substring(with: NSRange(location: overlap.location - span.location, length: overlap.length)), marks: run.marks, link: run.link)
        }
    }

    static func merge(_ runs: [TextRun]) -> [TextRun] {
        var result: [TextRun] = []
        for run in runs where !run.text.isEmpty {
            if result.last?.marks == run.marks, result.last?.link == run.link { result[result.count - 1].text += run.text }
            else { result.append(run) }
        }
        return result
    }

    static func replace(_ document: inout MarkdownDocument, range: NSRange, text: String, marks: Set<InlineMark>) throws -> NSRange {
        try document.validate(range)
        let ranges = document.blockRanges
        let first = document.blockIndex(at: range.location), last = document.blockIndex(at: NSMaxRange(range))
        let leftBlock = document.blocks[first], rightBlock = document.blocks[last]
        let start = range.location - ranges[first].location, end = NSMaxRange(range) - ranges[last].location
        if text == "\n", range.length == 0, leftBlock.text.isEmpty,
           leftBlock.kind.listDepth != nil || leftBlock.kind == .quote {
            document.blocks[first].kind = .paragraph
            return range
        }
        let left = slice(leftBlock.runs, NSRange(location: 0, length: start))
        let right = slice(rightBlock.runs, NSRange(location: end, length: rightBlock.text.utf16.count - end))
        let link = link(at: start, in: leftBlock.runs)
        if first == last, case .code = leftBlock.kind {
            document.blocks[first].runs = merge(left + [TextRun(text)] + right)
        } else {
            let lines = text.components(separatedBy: "\n")
            var result: [Block] = [], kind = leftBlock.kind
            for (index, line) in lines.enumerated() {
                let runs = (index == 0 ? left : []) + [TextRun(line, marks: marks, link: link)] + (index == lines.count - 1 ? right : [])
                result.append(Block(id: index == 0 ? leftBlock.id : UUID(), kind: kind, runs: merge(runs)))
                kind = kind.continuation
            }
            document.blocks.replaceSubrange(first...last, with: result)
        }
        renumber(&document)
        var caret = range.location + text.utf16.count
        if range.length == 0, text.count == 1 { applyInputRule(&document, caret: &caret, inserted: text) }
        return NSRange(location: caret, length: 0)
    }

    private static func applyInputRule(_ document: inout MarkdownDocument, caret: inout Int, inserted: String) {
        let index = document.blockIndex(at: caret), block = document.blocks[index]
        if case .code = block.kind { return }
        let offset = document.blockRanges[index].location
        let local = caret - offset
        let prefix = (block.text as NSString).substring(to: local)
        if inserted == " " {
            var kind: BlockKind?
            switch prefix {
            case "- ", "* ", "+ ": kind = .bullet(depth: 0)
            case "> ": kind = .quote
            case "[ ] ", "[x] ", "[X] ":
                if let depth = block.kind.listDepth { kind = .task(checked: prefix != "[ ] ", depth: depth) }
            default:
                let hashes = prefix.dropLast()
                if (1...6).contains(hashes.count), hashes.allSatisfy({ $0 == "#" }) { kind = .heading(hashes.count) }
                else if let match = prefix.range(of: "^[0-9]{1,9}\\. $", options: .regularExpression), match == prefix.startIndex..<prefix.endIndex,
                        let number = UInt(prefix.dropLast(2)) { kind = .ordered(number: number, depth: 0) }
            }
            if let kind {
                document.blocks[index].kind = kind
                document.blocks[index].runs = slice(block.runs, NSRange(location: local, length: block.text.utf16.count - local))
                caret -= local; renumber(&document); return
            }
        }
        let patterns: [(String, InlineMark, Int)] = [
            (#"(?<![\\*])\*\*([^*\n]+)\*\*$"#, .bold, 2),
            (#"(?<![\\*])\*([^*\n]+)\*$"#, .italic, 1),
            (#"(?<![\\~])~~([^~\n]+)~~$"#, .strikethrough, 2),
            (#"(?<![\\`])`([^`\n]+)`$"#, .code, 1)
        ]
        guard ["*", "~", "`"].contains(inserted) else { return }
        for (pattern, mark, width) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: prefix, range: NSRange(location: 0, length: prefix.utf16.count)) else { continue }
            let before = slice(block.runs, NSRange(location: 0, length: match.range.location))
            let content = slice(block.runs, match.range(at: 1)).map { run in
                var run = run; run.marks.insert(mark); return run
            }
            let after = slice(block.runs, NSRange(location: local, length: block.text.utf16.count - local))
            document.blocks[index].runs = merge(before + content + after)
            caret -= width * 2
            return
        }
    }

    static func toggle(_ document: inout MarkdownDocument, mark: InlineMark, range: NSRange) throws {
        try document.validate(range)
        let removing = document.formatting(in: range).active.contains(mark)
        let ranges = document.blockRanges
        for index in document.blocks.indices {
            let overlap = NSIntersectionRange(ranges[index], range)
            guard overlap.length > 0 else { continue }
            let local = NSRange(location: overlap.location - ranges[index].location, length: overlap.length)
            let block = document.blocks[index]
            let before = slice(block.runs, NSRange(location: 0, length: local.location))
            let selected = slice(block.runs, local).map { run in
                var run = run
                if removing { run.marks.remove(mark) } else { run.marks.insert(mark) }
                return run
            }
            let after = slice(block.runs, NSRange(location: NSMaxRange(local), length: block.text.utf16.count - NSMaxRange(local)))
            document.blocks[index].runs = merge(before + selected + after)
        }
    }

    static func selectedBlocks(_ document: MarkdownDocument, range: NSRange) -> ClosedRange<Int> {
        let first = document.blockIndex(at: range.location)
        let last = document.blockIndex(at: range.length == 0 ? range.location : NSMaxRange(range) - 1)
        return first...last
    }

    static func link(_ document: inout MarkdownDocument, destination: String, range: NSRange) throws {
        try document.validate(range)
        let ranges = document.blockRanges
        for index in document.blocks.indices {
            let overlap = NSIntersectionRange(ranges[index], range)
            guard overlap.length > 0 else { continue }
            let local = NSRange(location: overlap.location - ranges[index].location, length: overlap.length)
            let runs = document.blocks[index].runs
            let before = slice(runs, NSRange(location: 0, length: local.location))
            let selected = slice(runs, local).map { TextRun($0.text, marks: $0.marks, link: destination) }
            let after = slice(runs, NSRange(location: NSMaxRange(local), length: ranges[index].length - NSMaxRange(local)))
            document.blocks[index].runs = merge(before + selected + after)
        }
    }

    static func renumber(_ document: inout MarkdownDocument) {
        var counters: [Int: UInt] = [:]
        var ancestors: [Int] = []
        for index in document.blocks.indices {
            let original = document.blocks[index].kind
            guard let originalDepth = original.listDepth else { counters.removeAll(); ancestors.removeAll(); continue }
            ancestors.removeAll { $0 >= originalDepth }
            let depth = ancestors.count
            ancestors.append(originalDepth)
            let kind = original.atDepth(depth)
            document.blocks[index].kind = kind
            counters = counters.filter { $0.key <= depth }
            if case .ordered(let number, _) = kind {
                let next = counters[depth].map { $0 == UInt.max ? $0 : $0 + 1 } ?? number
                document.blocks[index].kind = .ordered(number: next, depth: depth)
                counters[depth] = next
            } else { counters[depth] = nil }
        }
    }
}
