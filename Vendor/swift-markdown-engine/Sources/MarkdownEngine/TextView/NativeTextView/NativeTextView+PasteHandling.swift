//
//  NativeTextView+PasteHandling.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//

import AppKit

extension NativeTextView {
    private static let pastableTextExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "text"
    ]

    override func paste(_ sender: Any?) {
        guard isEditable else {
            super.paste(sender)
            return
        }

        let pasteboard = NSPasteboard.general

        if let imageEmbed = onPasteImage?(pasteboard), !imageEmbed.isEmpty {
            insertBlockEmbed(imageEmbed)
            return
        }

        if insertClipboardText(from: pasteboard) { return }

        pasteAsPlainText(sender)
    }

    func insertClipboardText(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable else { return false }
        if configuration.inlineEditingMode == .formatted, !hasMarkedText(),
           let coordinator = delegate as? NativeTextViewCoordinator,
           let data = pasteboard.data(forType: .rtf),
           let content = NSAttributedString(rtf: data, documentAttributes: nil), content.length > 0,
           let edit = MarkdownFormattedEditing.richTextInsertion(content, in: string, range: selectedRange()) {
            coordinator.applyFormattedEdit(edit, to: self, styles: [])
            return true
        }
        return insertPlainText(from: pasteboard)
    }

    /// Whitespace is Markdown content: indentation, hard breaks, and blank
    /// paragraphs must survive a paste exactly as copied.
    func insertPlainText(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable else { return false }
        guard let text = pasteboard.string(forType: .string)
                ?? textFromPastedFileURL(pasteboard: pasteboard),
              !text.isEmpty else { return false }
        insertText(text, replacementRange: selectedRange())
        return true
    }

    private func insertBlockEmbed(_ embed: String) {
        let sel = selectedRange()
        let nsText = string as NSString
        var prefix = ""
        var suffix = ""
        if sel.location > 0, nsText.character(at: sel.location - 1) != 0x0A {
            prefix = "\n"
        }
        let afterLocation = sel.location + sel.length
        if afterLocation < nsText.length, nsText.character(at: afterLocation) != 0x0A {
            suffix = "\n"
        }
        let replacement = prefix + embed + suffix
        MarkdownFormatting.replaceSource(in: self, range: sel, with: replacement,
            selectionAfter: NSRange(location: sel.location + replacement.utf16.count, length: 0))
    }

    /// Reads the textual content of a pasted markdown/text file URL — the
    /// fallback that makes iOS Universal Clipboard pastes useful.
    private func textFromPastedFileURL(pasteboard: NSPasteboard) -> String? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        for url in urls where url.isFileURL {
            guard Self.pastableTextExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
            if let s = try? String(contentsOf: url) { return s }
        }
        return nil
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            let pasteboard = NSPasteboard.general
            if PasteboardImageReader.canPasteImage(from: pasteboard) { return true }
            if textFromPastedFileURL(pasteboard: pasteboard) != nil { return true }
        }
        return super.validateUserInterfaceItem(item)
    }
}
