import AppKit
import SwiftUI
import NativeMarkdownCore
import NativeMarkdownAppKit

/// Native visible-text positions must not be confused with Markdown offsets
/// or ProseMirror positions from the previous editor.
struct NativeEditorSelection: Codable, Equatable {
    var location: Int
    var length: Int
    var range: NSRange { NSRange(location: location, length: length) }
}

@MainActor
final class NativeNoteEditorController {
    private struct Entry {
        var source: String
        let editor: NativeMarkdownEditor
    }
    let store: NoteStore
    let container = NSView()
    weak var interaction: EditorInteractionState?
    private var entries: [UUID: Entry] = [:]
    private(set) var displayedID: UUID?
    private(set) var editor: NativeMarkdownEditor?

    init(store: NoteStore, interaction: EditorInteractionState) {
        self.store = store; self.interaction = interaction
        requestDocument()
    }

    func requestDocument() {
        let id = store.activeTabID
        if displayedID != id { editor?.commitComposition() }
        entries = entries.filter { entry in store.tabs.contains { $0.id == entry.key } }
        let source = store.text(for: id)
        if displayedID == id, entries[id]?.source == source { return }
        let next: NativeMarkdownEditor
        if let entry = entries[id], entry.source == source { next = entry.editor }
        else {
            // Unsupported structures remain editable verbatim in a native source
            // surface. Opening a note never normalizes or drops stored content.
            let document: MarkdownDocument
            let sourceMode: Bool
            do {
                if source.contains("![[") || source.contains("[[") { throw EditingError.unsupportedMarkdown("local references") }
                document = try MarkdownDocument(markdown: source); sourceMode = false
            } catch {
                document = MarkdownDocument(blocks: [Block(kind: .code(language: nil), runs: [TextRun(source)])])
                sourceMode = true
            }
            next = NativeMarkdownEditor(document: document, sourceMode: sourceMode)
            entries[id] = Entry(source: source, editor: next)
            next.onSourceCommand = { [weak self] command in
                guard let self, self.store.activeTabID == id else { return }
                self.command(command)
            }
            next.onChange = { [weak self] markdown in
                guard let self, self.store.tabs.contains(where: { $0.id == id }) else { return }
                self.entries[id]?.source = markdown
                self.store.updateText(markdown, for: id)
            }
            next.onSelectionChange = { [weak self] range in self?.store.updateNativeSelection(range, for: id) }
            next.onFormattingChange = { [weak self] active, mixed in
                guard let self, self.store.activeTabID == id else { return }
                self.interaction?.setFormattingState(active: active.map(Self.commandID), mixed: mixed.map(Self.commandID))
            }
            if let range = store.tabs.first(where: { $0.id == id })?.nativeSelection?.range { next.select(range) }
        }
        let focused = editor?.textView === container.window?.firstResponder
        editor?.removeFromSuperview()
        editor = next; displayedID = id
        next.frame = container.bounds; next.autoresizingMask = [.width, .height]
        container.addSubview(next)
        interaction?.editorNotice = next.isSourceMode ? "Markdown source mode · rich rendering for this syntax is still in development" : nil
        let formatting = next.session.document.formatting(in: next.textView.selectedRange())
        interaction?.setFormattingState(active: formatting.active.map(Self.commandID), mixed: formatting.mixed.map(Self.commandID))
        if focused { next.focus() }
    }

    func flush() { editor?.commitComposition(); store.flush() }
    func focus() { requestDocument(); editor?.focus() }
    func command(_ command: String) {
        requestDocument()
        guard let editor else { return }
        if editor.isSourceMode,
           let sourceCommand = MarkdownCommand.allCases.first(where: { $0.id == command }) {
            editor.commitComposition()
            interaction?.applySourceMarkdownCommand(sourceCommand, in: editor.textView)
            editor.focus()
            return
        }
        switch command {
        case "bold": editor.toggle(.bold)
        case "italic": editor.toggle(.italic)
        case "strikethrough": editor.toggle(.strikethrough)
        case "inlineCode": editor.toggle(.code)
        case "link": editor.insertLink()
        case "quote": editor.toggleBlock(.quote)
        case "unorderedList": editor.toggleBlock(.bullet(depth: 0))
        case "orderedList": editor.toggleBlock(.ordered(number: 1, depth: 0))
        case "todoList": editor.toggleBlock(.task(checked: false, depth: 0))
        case "undo": editor.undo()
        case "redo": editor.redo()
        default: break
        }
    }

    func find(action: Int) {
        requestDocument()
        guard let editor else { return }
        editor.focus()
        let item = NSMenuItem(); item.tag = action
        editor.textView.performFindPanelAction(item)
    }

    private static func commandID(_ mark: InlineMark) -> String { mark == .code ? "inlineCode" : mark.rawValue }
}

struct NativeNoteEditorView: NSViewRepresentable {
    let store: NoteStore
    let interaction: EditorInteractionState
    func makeNSView(context: Context) -> NSView {
        let controller = interaction.nativeEditor ?? NativeNoteEditorController(store: store, interaction: interaction)
        interaction.bind(nativeEditor: controller)
        return controller.container
    }
    func updateNSView(_ view: NSView, context: Context) { interaction.nativeEditor?.requestDocument() }
}
