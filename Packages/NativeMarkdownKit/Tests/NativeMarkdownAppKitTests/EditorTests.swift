import AppKit
import XCTest
import NativeMarkdownCore
import NativeMarkdownAppKit

@MainActor
final class EditorTests: XCTestCase {
    private func window(_ editor: NativeMarkdownEditor) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        window.makeKeyAndOrderFront(nil); editor.layoutSubtreeIfNeeded(); editor.focus()
        return window
    }

    func testCheckboxHitTestingAndContinuousSelection() throws {
        let editor = NativeMarkdownEditor(document: try MarkdownDocument(markdown: "- [ ] task\n\nparagraph"))
        let window = window(editor); defer { window.contentView = nil; window.close() }
        let id = editor.session.document.blocks[0].id
        for checked in [true, false, true] {
            let rect = try XCTUnwrap(editor.textView.taskCheckboxRect(for: id))
            let point = editor.textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            editor.textView.mouseDown(with: event)
            XCTAssertEqual(editor.session.document.blocks[0].kind, .task(checked: checked, depth: 0))
        }
        editor.select(NSRange(location: 2, length: 7))
        editor.textView.insertText("한글😀", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(editor.session.document.visibleText, "ta한글😀graph")
        XCTAssertEqual(editor.session.document.blocks.count, 1)
        editor.undo()
        XCTAssertEqual(editor.session.document.visibleText, "task\nparagraph")
        XCTAssertEqual(editor.session.selectedRange, NSRange(location: 2, length: 7))
        editor.redo()
        XCTAssertEqual(editor.textView.string, "ta한글😀graph")
    }

    func testPendingFormattingEnterAndNativeKeyboardUndo() throws {
        let editor = NativeMarkdownEditor(document: MarkdownDocument())
        let window = window(editor); defer { window.contentView = nil; window.close() }
        editor.toggle(.bold)
        editor.textView.insertText("한글😀", replacementRange: editor.textView.selectedRange())
        XCTAssertTrue(editor.session.document.markdown().contains("**한글😀**"))
        editor.toggleBlock(.task(checked: false, depth: 0))
        editor.textView.insertNewline(nil)
        XCTAssertEqual(editor.session.document.blocks.count, 2)
        XCTAssertEqual(editor.session.document.blocks[1].kind, .task(checked: false, depth: 0))
        editor.textView.insertNewline(nil)
        XCTAssertEqual(editor.session.document.blocks.count, 2)
        XCTAssertEqual(editor.session.document.blocks[1].kind, .paragraph)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        XCTAssertTrue(editor.textView.performKeyEquivalent(with: event))
        XCTAssertEqual(editor.session.document.blocks[1].kind, .task(checked: false, depth: 0))
    }

    func testCompositionDoesNotRebuildMarkedTextAndCommitsOnce() throws {
        let editor = NativeMarkdownEditor(document: try MarkdownDocument(markdown: "before"))
        let window = window(editor); defer { window.contentView = nil; window.close() }
        editor.select(NSRange(location: 6, length: 0))
        var changes: [String] = []
        editor.onChange = { changes.append($0) }
        editor.textView.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.textView.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.textView.hasMarkedText())
        XCTAssertEqual(editor.session.document.visibleText, "before")
        XCTAssertTrue(changes.isEmpty)
        editor.textView.unmarkText()
        XCTAssertEqual(editor.session.document.visibleText, "before한")
        XCTAssertEqual(changes.count, 1)
        editor.undo()
        XCTAssertEqual(editor.textView.string, "before")
    }

    func testOriginalNotchNotesMetricsAndLongTextLayout() throws {
        let editor = NativeMarkdownEditor(document: try MarkdownDocument(markdown: "paragraph"))
        let window = window(editor); defer { window.contentView = nil; window.close() }
        XCTAssertEqual(editor.textView.textContainerInset, NSSize(width: 12, height: 12))
        XCTAssertEqual((editor.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 15)
        editor.select(NSRange(location: 9, length: 0))
        editor.textView.insertText(String(repeating: " 한글😀", count: 200), replacementRange: editor.textView.selectedRange())
        editor.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(editor.textView.frame.height, editor.scrollView.contentSize.height)
        editor.undo()
        XCTAssertEqual(editor.textView.string, "paragraph")
    }

    func testRepeatedCharactersHonorActualEditRange() throws {
        let editor = NativeMarkdownEditor(document: MarkdownDocument(blocks: [Block(runs: [TextRun("aaa", marks: [.bold]), TextRun("aaa")])]))
        let window = window(editor); defer { window.contentView = nil; window.close() }
        editor.select(NSRange(location: 1, length: 0))
        editor.textView.insertText("a", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(editor.session.document.blocks[0].runs, [TextRun("aaaa", marks: [.bold]), TextRun("aaa")])
    }

    func testUndoMenuTracksDocumentHistory() throws {
        let editor = NativeMarkdownEditor(document: MarkdownDocument())
        let window = window(editor); defer { window.contentView = nil; window.close() }
        let undo = NSMenuItem(title: "Undo", action: #selector(NativeMarkdownTextView.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(NativeMarkdownTextView.redo(_:)), keyEquivalent: "Z")
        editor.textView.insertText("note", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.textView.validateUserInterfaceItem(undo))
        XCTAssertFalse(editor.textView.validateUserInterfaceItem(redo))
        editor.textView.undo(nil)
        XCTAssertFalse(editor.textView.validateUserInterfaceItem(undo))
        XCTAssertTrue(editor.textView.validateUserInterfaceItem(redo))
    }

    func testPendingBoldPersistsAcrossSeparateKeystrokes() throws {
        let editor = NativeMarkdownEditor(document: MarkdownDocument())
        let window = window(editor); defer { window.contentView = nil; window.close() }
        editor.toggle(.bold)
        for character in "hello" {
            editor.textView.insertText(String(character), replacementRange: editor.textView.selectedRange())
        }
        XCTAssertEqual(editor.session.document.blocks[0].runs, [TextRun("hello", marks: [.bold])])
    }

    func testRichClipboardPreservesInlineMarksAndLinks() throws {
        let source = NativeMarkdownEditor(document: try MarkdownDocument(markdown: "**bold** [link](https://example.com)"))
        let sourceWindow = window(source); defer { sourceWindow.contentView = nil; sourceWindow.close() }
        source.select(NSRange(location: 0, length: 9))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(source.textView.writeSelection(to: pasteboard, types: [.rtf]))
        let target = NativeMarkdownEditor(document: MarkdownDocument())
        let targetWindow = window(target); defer { targetWindow.contentView = nil; targetWindow.close() }

        XCTAssertTrue(target.textView.readSelection(from: pasteboard, type: .rtf))

        XCTAssertEqual(target.session.document.blocks[0].runs,
                       [TextRun("bold", marks: [.bold]), TextRun(" "), TextRun("link", link: "https://example.com")])
        target.undo()
        XCTAssertEqual(target.textView.string, "")
    }

    func testMarkdownClipboardPreservesListStructure() throws {
        let source = NativeMarkdownEditor(document: try MarkdownDocument(markdown: "- [ ] first\n- [x] **second**"))
        let sourceWindow = window(source); defer { sourceWindow.contentView = nil; sourceWindow.close() }
        source.select(NSRange(location: 0, length: source.textView.string.utf16.count))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let markdown = NSPasteboard.PasteboardType("public.markdown")
        XCTAssertTrue(source.textView.writeSelection(to: pasteboard, types: [markdown, .string]))
        let target = NativeMarkdownEditor(document: MarkdownDocument())
        let targetWindow = window(target); defer { targetWindow.contentView = nil; targetWindow.close() }

        XCTAssertTrue(target.textView.readSelection(from: pasteboard))

        XCTAssertEqual(target.session.document.blocks.map(\.kind),
                       [.task(checked: false, depth: 0), .task(checked: true, depth: 0)])
        XCTAssertEqual(target.session.document.blocks.last?.runs, [TextRun("second", marks: [.bold])])
    }

    func testSourceClipboardKeepsLiteralMarkdownAndSingleUndo() throws {
        let text = "![image](local.png)\n\n**literal**"
        let source = NativeMarkdownEditor(document: MarkdownDocument(blocks: [Block(kind: .code(language: nil), runs: [TextRun(text)])]),
                                          sourceMode: true)
        let sourceWindow = window(source); defer { sourceWindow.contentView = nil; sourceWindow.close() }
        source.select(NSRange(location: 0, length: text.utf16.count))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(source.textView.writeSelection(to: pasteboard, types: source.textView.writablePasteboardTypes))
        let target = NativeMarkdownEditor(document: MarkdownDocument(blocks: [Block(kind: .code(language: nil))]), sourceMode: true)
        let targetWindow = window(target); defer { targetWindow.contentView = nil; targetWindow.close() }

        XCTAssertTrue(target.textView.readSelection(from: pasteboard))

        XCTAssertEqual(target.textView.string, text)
        target.undo()
        XCTAssertEqual(target.textView.string, "")
    }

    func testEditorShortcutsDoNotConsumeFindFieldCommands() throws {
        let editor = NativeMarkdownEditor(document: MarkdownDocument())
        let window = window(editor); defer { window.contentView = nil; window.close() }
        editor.textView.insertText("note", replacementRange: NSRange(location: 0, length: 0))
        let field = NSTextField(string: "find query")
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        editor.addSubview(field)
        window.makeFirstResponder(field)
        XCTAssertFalse(window.firstResponder === editor.textView)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))

        XCTAssertFalse(editor.textView.performKeyEquivalent(with: event))

        XCTAssertEqual(editor.textView.string, "note")
    }

    func testClipboardRetainsTrailingAndBlankLinesWithoutBorrowingNextBlockStyle() throws {
        for document in [
            try MarkdownDocument(markdown: "- a\n- b"),
            MarkdownDocument(blocks: [Block(runs: [TextRun("a")]), Block(), Block(runs: [TextRun("b")])])
        ] {
            let source = NativeMarkdownEditor(document: document)
            let sourceWindow = window(source); defer { sourceWindow.contentView = nil; sourceWindow.close() }
            let text = document.visibleText
            let selection = NSRange(location: 0, length: text.utf16.count - 1)
            source.select(selection)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            XCTAssertTrue(source.textView.writeSelection(to: pasteboard, types: source.textView.writablePasteboardTypes))
            let target = NativeMarkdownEditor(document: MarkdownDocument())
            let targetWindow = window(target); defer { targetWindow.contentView = nil; targetWindow.close() }

            XCTAssertTrue(target.textView.readSelection(from: pasteboard))

            XCTAssertEqual(target.textView.string, (text as NSString).substring(with: selection))
            XCTAssertEqual(target.session.document.blocks.last?.kind, .paragraph)
        }
    }

    func testMalformedNativeClipboardDoesNotReplaceExistingContent() throws {
        let editor = NativeMarkdownEditor(document: try MarkdownDocument(markdown: "safe"))
        let window = window(editor); defer { window.contentView = nil; window.close() }
        editor.select(NSRange(location: 0, length: 4))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let type = NSPasteboard.PasteboardType("io.github.oiloil.notchnotes.native-markdown-fragment.v1")
        pasteboard.declareTypes([type], owner: nil)
        let invalidDocuments = [
            MarkdownDocument(blocks: [Block(kind: .code(language: "swift\ninjected"), runs: [TextRun("code")])]),
            MarkdownDocument(blocks: [Block(runs: [TextRun("link", link: "https://example.com/\ninjected")])])
        ]
        let payloads = [Data(#"{"blocks":[]}"#.utf8)] + (try invalidDocuments.map { try JSONEncoder().encode($0) })
        for payload in payloads {
            pasteboard.setData(payload, forType: type)

            XCTAssertFalse(editor.textView.readSelection(from: pasteboard, type: type))

            XCTAssertEqual(editor.textView.string, "safe")
            XCTAssertFalse(editor.session.canUndo)
        }
    }

    func testInvalidNativeClipboardFallsBackToPlainText() throws {
        let editor = NativeMarkdownEditor(document: try MarkdownDocument(markdown: "safe"))
        let window = window(editor); defer { window.contentView = nil; window.close() }
        editor.select(NSRange(location: 0, length: 4))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let type = NSPasteboard.PasteboardType("io.github.oiloil.notchnotes.native-markdown-fragment.v1")
        pasteboard.declareTypes([type, .string], owner: nil)
        pasteboard.setData(Data("invalid".utf8), forType: type)
        pasteboard.setString("replacement", forType: .string)

        XCTAssertTrue(editor.textView.readSelection(from: pasteboard))

        XCTAssertEqual(editor.textView.string, "replacement")
    }
}
