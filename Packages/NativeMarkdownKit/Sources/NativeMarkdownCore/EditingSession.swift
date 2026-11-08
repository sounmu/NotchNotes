import Foundation

public struct BlockSelection: Equatable, Sendable {
    public let blockID: UUID
    public let range: NSRange
    public init(blockID: UUID, range: NSRange) { self.blockID = blockID; self.range = range }
}

public enum EditingCommand: Sendable {
    case replace(BlockSelection, text: String, marks: Set<InlineMark>)
    case toggleMark(InlineMark, BlockSelection)
    case toggleTask(UUID)
    case split(BlockSelection)
    case setRuns(UUID, [TextRun])
    case replaceDocument(NSRange, text: String, marks: Set<InlineMark>)
    case replaceFragment(NSRange, MarkdownDocument)
    case formatDocument(InlineMark, NSRange)
    case setBlockKind(BlockKind, NSRange)
    case indent(NSRange, delta: Int)
    case setLink(NSRange, destination: String)
}

/// An editing transaction stores document and visible selection together.
/// This core has no AppKit, WebKit, JavaScript, or hidden syntax dependency.
public struct EditingSession: Sendable {
    private struct State: Sendable {
        var document: MarkdownDocument
        var selection: BlockSelection?
        var documentRange: NSRange?
    }
    private var state: State
    private var past: [State] = []
    private var future: [State] = []
    public var document: MarkdownDocument { state.document }
    public var selection: BlockSelection? { state.selection }
    public var selectedRange: NSRange {
        if let range = state.documentRange { return range }
        if let selection = state.selection, let index = state.document.blocks.firstIndex(where: { $0.id == selection.blockID }) {
            return NSRange(location: state.document.blockRanges[index].location + selection.range.location, length: selection.range.length)
        }
        return NSRange(location: 0, length: 0)
    }
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public init(_ document: MarkdownDocument) { state = State(document: document, selection: nil) }

    public mutating func select(_ selection: BlockSelection) throws {
        _ = try Self.atoms(state.document.blocks[try blockIndex(selection.blockID)], selection.range)
        state.selection = selection
        state.documentRange = nil
    }

    public mutating func select(_ range: NSRange) throws {
        try state.document.validate(range)
        state.documentRange = range
        state.selection = nil
    }

    @discardableResult
    public mutating func apply(_ command: EditingCommand, coalescing: Bool = false) throws -> Bool {
        let before = state
        var next = state
        switch command {
        case .replaceFragment(let range, let fragment):
            next.documentRange = try DocumentEditing.insert(fragment, into: &next.document, range: range)
            next.selection = nil
        case .setLink(let range, let destination):
            var range = range
            if range.length == 0 {
                _ = try DocumentEditing.replace(&next.document, range: range, text: "link text", marks: [])
                range.length = 9
            }
            try DocumentEditing.link(&next.document, destination: destination, range: range)
            next.documentRange = range; next.selection = nil
        case .replaceDocument(let range, let text, let marks):
            next.documentRange = try DocumentEditing.replace(&next.document, range: range, text: text, marks: marks)
            next.selection = nil
        case .formatDocument(let mark, let range):
            try DocumentEditing.toggle(&next.document, mark: mark, range: range)
            next.documentRange = range; next.selection = nil
        case .setBlockKind(let kind, let range):
            try next.document.validate(range)
            for index in DocumentEditing.selectedBlocks(next.document, range: range) { next.document.blocks[index].kind = kind }
            DocumentEditing.renumber(&next.document)
            next.documentRange = range; next.selection = nil
        case .indent(let range, let delta):
            try next.document.validate(range)
            let selected = DocumentEditing.selectedBlocks(next.document, range: range)
            for index in selected {
                guard let depth = next.document.blocks[index].kind.listDepth else { continue }
                let previousDepth = index > 0 ? next.document.blocks[index - 1].kind.listDepth : nil
                let limit = previousDepth.map { $0 + 1 } ?? 0
                let target = max(0, min(limit, depth + max(-1, min(1, delta))))
                next.document.blocks[index].kind = next.document.blocks[index].kind.atDepth(target)
            }
            DocumentEditing.renumber(&next.document)
            next.documentRange = range; next.selection = nil
        case .toggleTask(let id):
            let index = try blockIndex(id)
            guard case let .task(checked, depth) = next.document.blocks[index].kind else { throw EditingError.notATask }
            next.document.blocks[index].kind = .task(checked: !checked, depth: depth)
        case .setRuns(let id, let runs):
            next.document.blocks[try blockIndex(id)].runs = Self.merge(runs)
        case .replace(let selection, let text, let marks):
            let index = try blockIndex(selection.blockID)
            let link = DocumentEditing.link(at: selection.range.location, in: next.document.blocks[index].runs)
            var atoms = try Self.atoms(next.document.blocks[index], selection.range)
            let before = atoms.filter { NSMaxRange($0.range) <= selection.range.location }
            let after = atoms.filter { $0.range.location >= NSMaxRange(selection.range) }
            atoms = before + [Atom(run: TextRun(text, marks: marks, link: link), range: .init(location: 0, length: text.utf16.count))] + after
            next.document.blocks[index].runs = Self.merge(atoms.map(\.run))
            next.selection = BlockSelection(blockID: selection.blockID, range: NSRange(location: selection.range.location + text.utf16.count, length: 0))
        case .toggleMark(let mark, let selection):
            let index = try blockIndex(selection.blockID)
            var atoms = try Self.atoms(next.document.blocks[index], selection.range)
            let selected = atoms.indices.filter { NSIntersectionRange(atoms[$0].range, selection.range).length > 0 }
            guard !selected.isEmpty else { return false }
            let removing = selected.allSatisfy { atoms[$0].run.marks.contains(mark) }
            for i in selected { if removing { atoms[i].run.marks.remove(mark) } else { atoms[i].run.marks.insert(mark) } }
            next.document.blocks[index].runs = Self.merge(atoms.map(\.run))
            next.selection = selection
        case .split(let selection):
            let index = try blockIndex(selection.blockID)
            let block = next.document.blocks[index]
            let atoms = try Self.atoms(block, selection.range)
            let left = Self.merge(atoms.filter { NSMaxRange($0.range) <= selection.range.location }.map(\.run))
            let right = Self.merge(atoms.filter { $0.range.location >= NSMaxRange(selection.range) }.map(\.run))
            let kind: BlockKind
            switch block.kind {
            case .task(_, let depth): kind = .task(checked: false, depth: depth)
            case .ordered(let number, let depth): kind = .ordered(number: number == UInt.max ? number : number + 1, depth: depth)
            case .bullet, .quote: kind = block.kind
            default: kind = .paragraph
            }
            let newBlock = Block(kind: kind, runs: right)
            next.document.blocks[index].runs = left
            next.document.blocks.insert(newBlock, at: index + 1)
            next.selection = BlockSelection(blockID: newBlock.id, range: .init(location: 0, length: 0))
        }
        guard next.document != before.document else { return false }
        if !coalescing || past.isEmpty { past.append(before) }
        future.removeAll(); state = next
        return true
    }

    public mutating func undo() { if let previous = past.popLast() { future.append(state); state = previous } }
    public mutating func redo() { if let next = future.popLast() { past.append(state); state = next } }

    private func blockIndex(_ id: UUID) throws -> Int {
        guard let index = state.document.blocks.firstIndex(where: { $0.id == id }) else { throw EditingError.missingBlock }
        return index
    }
    private struct Atom { var run: TextRun; let range: NSRange }
    private static func atoms(_ block: Block, _ range: NSRange) throws -> [Atom] {
        let length = block.text.utf16.count
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location else { throw EditingError.invalidRange }
        var offset = 0, result: [Atom] = [], boundaries: Set<Int> = [0]
        for run in block.runs {
            for character in run.text {
                let value = String(character)
                result.append(Atom(run: TextRun(value, marks: run.marks, link: run.link), range: .init(location: offset, length: value.utf16.count)))
                offset += value.utf16.count; boundaries.insert(offset)
            }
        }
        guard boundaries.contains(range.location), boundaries.contains(NSMaxRange(range)) else { throw EditingError.invalidRange }
        return result
    }
    private static func merge(_ runs: [TextRun]) -> [TextRun] {
        var result: [TextRun] = []
        for run in runs where !run.text.isEmpty {
            if result.last?.marks == run.marks, result.last?.link == run.link { result[result.count - 1].text += run.text }
            else { result.append(run) }
        }
        return result
    }
}
