import AppKit
import NativeMarkdownCore

/// A continuous native text surface. List decorations are drawn outside the
/// editable string; document offsets contain only visible text and separators.
@MainActor
public final class NativeMarkdownEditor: NSView, NSTextViewDelegate {
    public private(set) var session: EditingSession
    public var onChange: ((String) -> Void)?
    public var onSelectionChange: ((NSRange) -> Void)?
    public var onFormattingChange: ((Set<InlineMark>, Set<InlineMark>) -> Void)?
    public var onSourceCommand: ((String) -> Void)?
    public let textView: NativeMarkdownTextView
    public let scrollView = NSScrollView()
    public let isSourceMode: Bool
    private var rendering = false
    private var pendingMarks: Set<InlineMark>?
    private var lastTypingTime = Date.distantPast
    private var lastTypingCaret: Int?
    private var proposedEdit: (range: NSRange, text: String)?

    public init(document: MarkdownDocument, sourceMode: Bool = false) {
        session = EditingSession(document)
        isSourceMode = sourceMode
        // TextKit 1's continuous selection and mature NSTextInputClient handle
        // shaping/composition. The document model remains independent of it.
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        textView = NativeMarkdownTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        textView.editor = self
        textView.delegate = self
        textView.isRichText = true
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = false
        textView.insertionPointColor = NSColor(white: 0.92, alpha: 1)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.setAccessibilityLabel("Note editor")
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor), scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        render()
    }
    required init?(coder: NSCoder) { fatalError("Use init(document:)") }

    public override func layout() {
        super.layout()
        textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: max(textView.frame.height, scrollView.contentSize.height)))
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.sizeToFit()
    }

    public func restore(_ session: EditingSession) {
        commitComposition()
        self.session = session
        pendingMarks = nil; breakTypingGroup()
        render()
    }

    public func select(_ range: NSRange) {
        guard (try? session.document.validate(range)) != nil else { return }
        textView.setSelectedRange(range)
    }

    public func focus() { window?.makeFirstResponder(textView) }

    public func commitComposition() {
        if textView.hasMarkedText() { textView.inputContext?.discardMarkedText(); textView.unmarkText() }
        commitPendingText()
    }

    public func toggle(_ mark: InlineMark) {
        if isSourceMode {
            onSourceCommand?(mark == .code ? "inlineCode" : mark.rawValue)
            return
        }
        commitComposition(); breakTypingGroup()
        let range = textView.selectedRange()
        if range.length == 0 {
            var marks = pendingMarks ?? session.document.marks(at: range.location)
            if marks.contains(mark) { marks.remove(mark) } else { marks.insert(mark) }
            pendingMarks = marks
            updateTypingAttributes(); notifySelection()
        } else { perform(.formatDocument(mark, range)) }
        focus()
    }

    public func toggleBlock(_ kind: BlockKind) {
        guard !isSourceMode else { return }
        commitComposition()
        let range = textView.selectedRange(), document = session.document
        let first = document.blockIndex(at: range.location)
        let current = document.blocks[first].kind
        let same: Bool
        switch (current, kind) {
        case (.bullet, .bullet), (.ordered, .ordered), (.task, .task), (.quote, .quote): same = true
        default: same = current == kind
        }
        perform(.setBlockKind(same ? .paragraph : kind, range)); focus()
    }

    public func indent(_ delta: Int) {
        guard !isSourceMode else { return }
        commitComposition(); perform(.indent(textView.selectedRange(), delta: delta))
    }

    public func insertLink(_ destination: String = "https://") {
        if isSourceMode { onSourceCommand?("link"); return }
        commitComposition(); perform(.setLink(textView.selectedRange(), destination: destination)); focus()
    }

    public func toggleTask(_ id: UUID) {
        commitComposition(); perform(.toggleTask(id))
    }

    public func undo() {
        commitComposition(); breakTypingGroup(); pendingMarks = nil
        guard session.canUndo else { return }
        session.undo(); render(); notifyChange()
    }
    public func redo() {
        commitComposition(); breakTypingGroup(); pendingMarks = nil
        guard session.canRedo else { return }
        session.redo(); render(); notifyChange()
    }

    private func perform(_ command: EditingCommand) {
        breakTypingGroup(); pendingMarks = nil
        do {
            try session.select(textView.selectedRange())
            if try session.apply(command) { render(); notifyChange() }
        } catch { NSSound.beep() }
    }

    func insertClipboardFragment(_ fragment: MarkdownDocument) {
        commitComposition()
        let range = textView.selectedRange()
        if case .code = session.document.blocks[session.document.blockIndex(at: range.location)].kind {
            textView.insertText(fragment.visibleText, replacementRange: range)
        } else {
            perform(.replaceFragment(range, fragment))
        }
    }

    private func breakTypingGroup() { lastTypingCaret = nil; lastTypingTime = .distantPast }

    private func render() {
        guard !textView.hasMarkedText() else { return }
        rendering = true
        let result = NSMutableAttributedString()
        for (index, block) in session.document.blocks.enumerated() {
            for run in block.runs {
                var style = attributes(run.marks, kind: block.kind)
                if let link = run.link { style[.link] = link; style[.foregroundColor] = NSColor.systemBlue }
                result.append(NSAttributedString(string: run.text, attributes: style))
            }
            if index < session.document.blocks.count - 1 { result.append(NSAttributedString(string: "\n", attributes: attributes([], kind: block.kind))) }
        }
        textView.textStorage?.setAttributedString(result)
        let range = session.selectedRange
        textView.setSelectedRange(NSRange(location: min(range.location, result.length), length: min(range.length, max(0, result.length - range.location))))
        updateTypingAttributes()
        textView.sizeToFit(); textView.needsDisplay = true
        rendering = false
        notifySelection()
    }

    private func attributes(_ marks: Set<InlineMark>, kind: BlockKind) -> [NSAttributedString.Key: Any] {
        var size: CGFloat = 15, bold = marks.contains(.bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        paragraph.paragraphSpacing = 6
        switch kind {
        case .heading(let level):
            let index = max(1, min(6, level)) - 1
            size *= [2.0, 1.5, 1.17, 1.0, 0.83, 0.67][index]
            paragraph.paragraphSpacingBefore = size * [0.35, 0.30, 0.25, 0.20, 0.15, 0.10][index]
            bold = true
        case .bullet(let depth), .ordered(_, let depth), .task(_, let depth):
            paragraph.headIndent = CGFloat(depth + 1) * 18
            paragraph.firstLineHeadIndent = paragraph.headIndent
            paragraph.paragraphSpacing = 2
        case .quote:
            paragraph.headIndent = 18; paragraph.firstLineHeadIndent = 18
        default: break
        }
        let code: Bool = { if case .code = kind { return true }; return marks.contains(.code) }()
        var font = code ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if marks.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var result: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(white: 0.92, alpha: 1), .paragraphStyle: paragraph,
            .strikethroughStyle: marks.contains(.strikethrough) ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughColor: NSColor(white: 0.62, alpha: 1)
        ]
        if marks.contains(.code) { result[.backgroundColor] = NSColor.white.withAlphaComponent(0.06) }
        return result
    }

    private func updateTypingAttributes() {
        let offset = min(textView.selectedRange().location, session.document.visibleText.utf16.count)
        let block = session.document.blocks[session.document.blockIndex(at: offset)]
        textView.typingAttributes = attributes(pendingMarks ?? session.document.marks(at: offset), kind: block.kind)
    }

    private func notifySelection() {
        guard !rendering, !textView.hasMarkedText() else { return }
        let range = textView.selectedRange()
        let formatting = session.document.formatting(in: range)
        onFormattingChange?(range.length == 0 ? (pendingMarks ?? formatting.active) : formatting.active, formatting.mixed)
        onSelectionChange?(range)
    }

    private func notifyChange() {
        onChange?(isSourceMode ? session.document.visibleText : session.document.markdown())
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if !rendering, !textView.hasMarkedText(), textView.string == session.document.visibleText {
            try? session.select(textView.selectedRange())
            if let replacementString { proposedEdit = (range, replacementString) }
        }
        return true
    }

    public func textDidChange(_ notification: Notification) { commitPendingText() }

    /// Called only after composition commits. While marked text is active,
    /// AppKit owns storage and selection and no attributed-string rebuild occurs.
    fileprivate func commitPendingText() {
        guard !rendering, !textView.hasMarkedText() else { return }
        let old = session.document.visibleText, new = textView.string
        guard old != new else { return }
        let oldCharacters = Array(old), newCharacters = Array(new)
        var prefix = 0, suffix = 0
        while prefix < min(oldCharacters.count, newCharacters.count), oldCharacters[prefix] == newCharacters[prefix] { prefix += 1 }
        while suffix < min(oldCharacters.count, newCharacters.count) - prefix,
              oldCharacters[oldCharacters.count - 1 - suffix] == newCharacters[newCharacters.count - 1 - suffix] { suffix += 1 }
        var start = String(oldCharacters.prefix(prefix)).utf16.count
        let removed = String(oldCharacters[prefix..<(oldCharacters.count - suffix)]).utf16.count
        var inserted = String(newCharacters[prefix..<(newCharacters.count - suffix)])
        var range = NSRange(location: start, length: removed)
        if let proposedEdit, (try? session.document.validate(proposedEdit.range)) != nil,
           (old as NSString).replacingCharacters(in: proposedEdit.range, with: proposedEdit.text) == new {
            range = proposedEdit.range; start = range.location; inserted = proposedEdit.text
        }
        proposedEdit = nil
        let marks = pendingMarks ?? session.document.marks(at: start)
        let typing = range.length == 0 && inserted.count == 1 && inserted != "\n"
        let coalescing = typing && lastTypingCaret == start && Date().timeIntervalSince(lastTypingTime) < 0.8
        do {
            try session.apply(.replaceDocument(range, text: inserted, marks: marks), coalescing: coalescing)
            if typing { lastTypingCaret = start + inserted.utf16.count; lastTypingTime = Date() }
            else { breakTypingGroup() }
            render(); notifyChange()
        } catch {
            // Keep the previous committed document if AppKit reports an invalid
            // edit; do not publish a partially applied transaction.
            render(); NSSound.beep()
        }
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard !rendering, !textView.hasMarkedText(), textView.string == session.document.visibleText else { return }
        let range = textView.selectedRange()
        if range != session.selectedRange { pendingMarks = nil; breakTypingGroup() }
        try? session.select(range)
        updateTypingAttributes(); notifySelection()
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText(), !isSourceMode else { return false }
        if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
            let kind = session.document.blocks[session.document.blockIndex(at: textView.selectedRange().location)].kind
            switch kind {
            case .bullet, .ordered, .task:
                indent(selector == #selector(NSResponder.insertTab(_:)) ? 1 : -1); return true
            default: return false
            }
        }
        return false
    }
}

@MainActor
public final class NativeMarkdownTextView: NSTextView {
    fileprivate weak var editor: NativeMarkdownEditor?

    public override func unmarkText() { super.unmarkText(); editor?.commitPendingText() }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        guard event.modifierFlags.intersection([.command, .control, .option]) == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": editor?.toggle(.bold); return true
        case "i": editor?.toggle(.italic); return true
        case "z": if event.modifierFlags.contains(.shift) { editor?.redo() } else { editor?.undo() }; return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
    @objc public func undo(_ sender: Any?) { editor?.undo() }
    @objc public func redo(_ sender: Any?) { editor?.redo() }
    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return editor?.session.canUndo == true
        case #selector(redo(_:)): return editor?.session.canRedo == true
        default: return super.validateUserInterfaceItem(item)
        }
    }
    @objc public func applyMarkdownBold(_ sender: Any?) { editor?.toggle(.bold) }
    @objc public func applyMarkdownItalic(_ sender: Any?) { editor?.toggle(.italic) }

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [NativeMarkdownEditor.fragmentPasteboardType, NativeMarkdownEditor.markdownPasteboardType, .rtf, .string]
    }

    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        guard selectedRange().length > 0 else { return [] }
        let types: [NSPasteboard.PasteboardType] = [NativeMarkdownEditor.markdownPasteboardType, .rtf, .string]
        return editor?.isSourceMode == false ? [NativeMarkdownEditor.fragmentPasteboardType] + types : types
    }

    public override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        editor?.writeSelection(to: pasteboard, type: type) ?? false
    }

    public override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        editor?.readSelection(from: pasteboard, type: type) ?? false
    }

    /// The same measured rectangles are used for drawing and hit testing.
    public func taskCheckboxRect(for id: UUID) -> NSRect? {
        guard let editor, !hasMarkedText(), let index = editor.session.document.blocks.firstIndex(where: { $0.id == id }),
              case .task(_, let depth) = editor.session.document.blocks[index].kind,
              let line = lineRect(at: editor.session.document.blockRanges[index].location) else { return nil }
        return checkboxRect(line: line, depth: depth)
    }

    private func checkboxRect(line: NSRect, depth: Int) -> NSRect {
        NSRect(x: textContainerOrigin.x + CGFloat(depth) * 18 + 1, y: line.minY + max(0, (line.height - 12) / 2), width: 12, height: 12)
    }

    private func lineRect(at offset: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        if offset >= (string as NSString).length {
            let rect = layoutManager.extraLineFragmentRect
            return NSRect(x: textContainerOrigin.x, y: rect.minY + textContainerOrigin.y, width: rect.width, height: max(rect.height, 18))
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        let rect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let editor, !editor.isSourceMode, !hasMarkedText() else { return }
        if string.isEmpty {
            ("Start typing…" as NSString).draw(at: NSPoint(x: 13, y: 12), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white.withAlphaComponent(0.24)])
        }
        let ranges = editor.session.document.blockRanges
        for (index, block) in editor.session.document.blocks.enumerated() {
            guard let line = lineRect(at: ranges[index].location), line.intersects(dirtyRect) else { continue }
            switch block.kind {
            case .task(let checked, let depth):
                let rect = checkboxRect(line: line, depth: depth)
                let box = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                NSColor(white: checked ? 0.76 : 0.48, alpha: 1).setStroke(); box.lineWidth = 1; box.stroke()
                if checked {
                    let tick = NSBezierPath(); tick.move(to: NSPoint(x: rect.minX + 2.5, y: rect.midY))
                    tick.line(to: NSPoint(x: rect.minX + 5, y: rect.maxY - 3)); tick.line(to: NSPoint(x: rect.maxX - 2, y: rect.minY + 3))
                    tick.lineWidth = 1.5; tick.stroke()
                }
            case .bullet(let depth), .ordered(_, let depth):
                let label: String
                if case .ordered(let number, _) = block.kind { label = "\(number)." } else { label = "•" }
                (label as NSString).draw(at: NSPoint(x: textContainerOrigin.x + CGFloat(depth) * 18, y: line.minY),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.58, alpha: 1)])
            case .quote:
                NSColor(white: 0.38, alpha: 1).setFill()
                NSRect(x: textContainerOrigin.x + 3, y: line.minY, width: 2, height: line.height).fill()
            default: break
            }
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let editor, !editor.isSourceMode, !hasMarkedText() {
            let ranges = editor.session.document.blockRanges
            for (index, block) in editor.session.document.blocks.enumerated() {
                if case .task(_, let depth) = block.kind, let line = lineRect(at: ranges[index].location),
                   checkboxRect(line: line, depth: depth).insetBy(dx: -2, dy: -2).contains(point) {
                    editor.toggleTask(block.id); return
                }
            }
        }
        super.mouseDown(with: event)
    }
}
