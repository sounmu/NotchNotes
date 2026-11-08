import AppKit
import NativeMarkdownCore

extension NativeMarkdownEditor {
    static let markdownPasteboardType = NSPasteboard.PasteboardType("public.markdown")
    static let fragmentPasteboardType = NSPasteboard.PasteboardType("io.github.oiloil.notchnotes.native-markdown-fragment.v1")

    func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        commitComposition()
        let range = textView.selectedRange()
        guard range.length > 0 else { return false }
        if type == Self.fragmentPasteboardType, !isSourceMode,
           let fragment = try? session.document.fragment(in: range),
           let data = try? JSONEncoder().encode(fragment) {
            return pasteboard.setData(data, forType: type)
        }
        if type == Self.markdownPasteboardType {
            if isSourceMode {
                return pasteboard.setString((textView.string as NSString).substring(with: range), forType: type)
            }
            guard let fragment = try? session.document.fragment(in: range) else { return false }
            return pasteboard.setString(fragment.markdown(), forType: type)
        }
        if type == .string {
            return pasteboard.setString((textView.string as NSString).substring(with: range), forType: type)
        }
        if type == .rtf, let storage = textView.textStorage,
           let data = try? storage.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            return pasteboard.setData(data, forType: type)
        }
        return false
    }

    func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        commitComposition()
        if type == Self.fragmentPasteboardType {
            guard let data = pasteboard.data(forType: type),
                  let fragment = try? JSONDecoder().decode(MarkdownDocument.self, from: data),
                  !fragment.blocks.isEmpty,
                  fragment.blocks.enumerated().allSatisfy({ index, block in
                      guard block.runs.allSatisfy({ $0.link?.contains(where: \.isNewline) != true }) else { return false }
                      switch block.kind {
                      case .bullet(let depth), .ordered(_, let depth), .task(_, let depth):
                          return depth >= 0 && depth <= index
                      case .heading(let level): return (1...6).contains(level)
                      case .code(let language): return language?.contains(where: \.isNewline) != true
                      default: return true
                      }
                  }) else { return false }
            if isSourceMode {
                textView.insertText(fragment.markdown(), replacementRange: textView.selectedRange())
            } else {
                insertClipboardFragment(fragment)
            }
            return true
        }
        if type == .string, let text = pasteboard.string(forType: type) {
            textView.insertText(text, replacementRange: textView.selectedRange())
            return true
        }
        if type == Self.markdownPasteboardType, let source = pasteboard.string(forType: type) {
            if isSourceMode {
                textView.insertText(source, replacementRange: textView.selectedRange())
            } else if let fragment = try? MarkdownDocument(markdown: source) {
                insertClipboardFragment(fragment)
            } else {
                // Unsupported pasted Markdown remains editable text, never a
                // partially imported document with missing content.
                textView.insertText(source, replacementRange: textView.selectedRange())
            }
            return true
        }
        if type == .rtf, let data = pasteboard.data(forType: .rtf),
           let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                    documentAttributes: nil) {
            if isSourceMode {
                textView.insertText(attributed.string, replacementRange: textView.selectedRange())
            } else {
                insertClipboardFragment(Self.document(from: attributed))
            }
            return true
        }
        return false
    }

    private static func document(from attributed: NSAttributedString) -> MarkdownDocument {
        var blocks = [Block()]
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            var marks = Set<InlineMark>()
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { marks.insert(.bold) }
                if traits.contains(.italicFontMask) { marks.insert(.italic) }
                if font.isFixedPitch { marks.insert(.code) }
            }
            if let strike = attributes[.strikethroughStyle] as? NSNumber, strike.intValue != 0 { marks.insert(.strikethrough) }
            let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            let text = (attributed.string as NSString).substring(with: range)
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if index > 0 { blocks.append(Block()) }
                if !line.isEmpty { blocks[blocks.count - 1].runs.append(TextRun(line, marks: marks, link: link)) }
            }
        }
        return MarkdownDocument(blocks: blocks)
    }
}
