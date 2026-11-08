import Foundation

public extension MarkdownDocument {
    /// A clipboard fragment uses the same visible UTF-16 positions as editing.
    func fragment(in range: NSRange) throws -> MarkdownDocument {
        try validate(range)
        let ranges = blockRanges
        let first = blockIndex(at: range.location)
        let last = blockIndex(at: NSMaxRange(range))
        var selected: [Block] = []
        for index in first...last {
            let start = max(range.location, ranges[index].location)
            let end = min(NSMaxRange(range), NSMaxRange(ranges[index]))
            let local = NSRange(location: start - ranges[index].location, length: max(0, end - start))
            let kind: BlockKind = index > first && start == NSMaxRange(range) ? .paragraph : blocks[index].kind
            selected.append(Block(kind: kind, runs: DocumentEditing.slice(blocks[index].runs, local)))
        }
        // A copied nested list must stand alone when pasted at document root.
        let baseDepth = selected.compactMap { $0.kind.listDepth }.min() ?? 0
        for index in selected.indices {
            if let depth = selected[index].kind.listDepth { selected[index].kind = selected[index].kind.atDepth(depth - baseDepth) }
        }
        return MarkdownDocument(blocks: selected)
    }
}

extension DocumentEditing {
    static func insert(_ fragment: MarkdownDocument, into document: inout MarkdownDocument, range: NSRange) throws -> NSRange {
        try document.validate(range)
        let ranges = document.blockRanges
        let first = document.blockIndex(at: range.location)
        let last = document.blockIndex(at: NSMaxRange(range))
        let leftBlock = document.blocks[first], rightBlock = document.blocks[last]
        let left = slice(leftBlock.runs, NSRange(location: 0, length: range.location - ranges[first].location))
        let end = NSMaxRange(range) - ranges[last].location
        let right = slice(rightBlock.runs, NSRange(location: end, length: rightBlock.text.utf16.count - end))
        var inserted = fragment.blocks.map { Block(kind: $0.kind, runs: $0.runs) }
        var leadingSeparator = 0
        if inserted.count == 1 {
            if !left.isEmpty || (!leftBlock.text.isEmpty && range.length < leftBlock.text.utf16.count) {
                inserted[0].kind = leftBlock.kind
            }
            inserted[0].runs = merge(left + inserted[0].runs + right)
        } else {
            if inserted[0].kind == .paragraph {
                if !left.isEmpty { inserted[0].kind = leftBlock.kind }
                inserted[0].runs = merge(left + inserted[0].runs)
            } else if !left.isEmpty {
                inserted.insert(Block(kind: leftBlock.kind, runs: left), at: 0)
                leadingSeparator = 1
            }
            if inserted[inserted.count - 1].kind == .paragraph {
                if inserted[inserted.count - 1].runs.isEmpty, !right.isEmpty {
                    inserted[inserted.count - 1].kind = rightBlock.kind
                }
                inserted[inserted.count - 1].runs = merge(inserted[inserted.count - 1].runs + right)
            } else if !right.isEmpty {
                inserted.append(Block(kind: rightBlock.kind, runs: right))
            }
        }
        inserted[0] = Block(id: leftBlock.id, kind: inserted[0].kind, runs: inserted[0].runs)
        document.blocks.replaceSubrange(first...last, with: inserted)
        renumber(&document)
        return NSRange(location: range.location + leadingSeparator + fragment.visibleText.utf16.count, length: 0)
    }
}
