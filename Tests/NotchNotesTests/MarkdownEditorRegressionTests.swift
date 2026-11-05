import AppKit
import SwiftUI
import XCTest
@testable import MarkdownEngine

@MainActor
final class MarkdownEditorRegressionTests: XCTestCase {
    private func editor(_ source: String, binding: Binding<String>? = nil) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let configuration = MarkdownEditorConfiguration(inlineEditingMode: .formatted)
        let coordinator = NativeTextViewWrapper(text: binding ?? .constant(source), configuration: configuration).makeCoordinator()
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.configuration = configuration
        view.string = source
        view.delegate = coordinator
        coordinator.textView = view
        view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        return (view, coordinator)
    }
    private func type(_ text: String, in view: NSTextView) { view.insertText(text, replacementRange: view.selectedRange()) }

    func testFormattedListEnterAndTabKeepListStructure() {
        for prefix in ["- ", "1. ", "- [ ] "] {
            let (view, coordinator) = editor(prefix + "**abc**")
            withExtendedLifetime(coordinator) {
                view.setSelectedRange(NSRange(location: prefix.utf16.count + 5, length: 0))
                view.insertNewline(nil)
                type("next", in: view)
                let next = prefix == "1. " ? "2. " : prefix
                XCTAssertEqual(view.string, prefix + "**abc**\n" + next + "**next**")
                view.insertTab(nil)
                XCTAssertTrue(view.string.contains("\n\t" + next))
            }
        }
        let (empty, emptyCoordinator) = editor("- ")
        withExtendedLifetime(emptyCoordinator) {
            MarkdownFormatting.apply(.bold, in: empty)
            empty.insertNewline(nil)
            XCTAssertEqual(empty.string, "")
            type("next", in: empty)
            XCTAssertEqual(empty.string, "**next**")
        }
    }

    func testHardBreakSplitsFormattingAndPreservesVisibleText() {
        let (view, coordinator) = editor("**abcd**")
        withExtendedLifetime(coordinator) {
            view.setSelectedRange(NSRange(location: 4, length: 0))
            XCTAssertTrue(MarkdownInputHandler.handleInsertNewline(textView: view, isShiftPressed: true))
            XCTAssertEqual(view.string, "**ab**  \n**cd**")
            XCTAssertEqual(MarkdownFormatting.visibleText(in: view.string), "ab  \ncd")
        }
    }

    func testFullSelectionFormattingKeepsBlockPrefixes() {
        for prefix in ["# ", "- ", "1. ", "> ", "- [ ] ", "* ", "+ "] {
            let (view, coordinator) = editor(prefix + "text")
            withExtendedLifetime(coordinator) {
                view.selectAll(nil)
                MarkdownFormatting.apply(.bold, in: view)
                XCTAssertEqual(view.string, prefix + "**text**")
                MarkdownFormatting.apply(.bold, in: view)
                XCTAssertEqual(view.string, prefix + "text")
            }
        }
    }

    func testTypedPunctuationRoundTripsThroughFormattingAndClipboard() {
        for style in [MarkdownFormatting.InlineStyle.bold, .italic, .strikethrough, .code] {
            for content in ["a*b", "a**b", "a~~b", "a`b", "`edge`", "a\\b", "한😀*글"] {
                let (view, coordinator) = editor("")
                withExtendedLifetime(coordinator) {
                    MarkdownFormatting.apply(style, in: view)
                    for character in content { type(String(character), in: view) }
                    XCTAssertEqual(MarkdownFormatting.visibleText(in: view.string), content, "\(style): \(view.string)")
                    let board = NSPasteboard.withUniqueName()
                    defer { board.releaseGlobally() }
                    view.selectAll(nil)
                    XCTAssertTrue(view.writeSelection(to: board, types: [.string]))
                    XCTAssertEqual(board.string(forType: .string), content)
                }
            }
        }
    }

    func testFencedCodeBackticksRemainLiteralDuringCopyAndDelete() {
        let source = "```\n`literal`\n```"
        let (view, coordinator) = editor(source)
        withExtendedLifetime(coordinator) {
            XCTAssertEqual(MarkdownFormatting.visibleText(in: view.string), source)
            view.setSelectedRange(NSRange(location: NSMaxRange((source as NSString).range(of: "`literal`")), length: 0))
            view.deleteBackward(nil)
            XCTAssertEqual(view.string, "```\n`literal\n```")
        }
        let (literal, literalCoordinator) = editor("```\ncode\n```")
        withExtendedLifetime(literalCoordinator) {
            literal.setSelectedRange(NSRange(location: 8, length: 0))
            MarkdownFormatting.apply(.bold, in: literal)
            type("!", in: literal)
            XCTAssertEqual(literal.string, "```\ncode!\n```")
        }
    }

    func testCodeWordDeletionUsesVisibleWordBoundaries() {
        let (view, coordinator) = editor("`one two`")
        withExtendedLifetime(coordinator) {
            view.deleteWordBackward(nil)
            XCTAssertEqual(MarkdownFormatting.visibleText(in: view.string), "one ")
        }
    }

    func testDeleteLastCharacterAndEndNavigationRetainFormatting() {
        let (view, coordinator) = editor("")
        withExtendedLifetime(coordinator) {
            MarkdownFormatting.apply(.bold, in: view)
            type("a", in: view)
            view.deleteBackward(nil)
            type("b", in: view)
            XCTAssertEqual(view.string, "**b**")
            view.moveToEndOfLine(nil)
            type("c", in: view)
            XCTAssertEqual(view.string, "**bc**")
        }
    }

    func testClipboardRoundTripPreservesInlineStyles() {
        let (view, coordinator) = editor("**bold** ~~strike~~ `code`")
        let (other, otherCoordinator) = editor("")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        withExtendedLifetime((coordinator, otherCoordinator)) {
            view.selectAll(nil)
            XCTAssertTrue(view.writeSelection(to: board, types: [.string, .rtf]))
            XCTAssertTrue(other.insertClipboardText(from: board))
            XCTAssertEqual(other.string, view.string)
        }
    }

    func testCheckboxAndImageCommandsBypassTypingMarks() {
        let (view, coordinator) = editor("- [ ] task")
        withExtendedLifetime(coordinator) {
            MarkdownFormatting.apply(.bold, in: view)
            XCTAssertTrue(view.toggleTaskCheckbox(in: NSRange(location: 2, length: 3), isChecked: false))
            XCTAssertEqual(view.string, "- [x] task")
        }
        let (imageView, imageCoordinator) = editor("")
        withExtendedLifetime(imageCoordinator) {
            MarkdownFormatting.apply(.bold, in: imageView)
            imageView.onPasteImage = { _ in "![[image.png]]" }
            imageView.paste(nil)
            XCTAssertEqual(imageView.string, "![[image.png]]")
        }
    }

    func testFenceRuleAndMaximumListNumberAreSafe() {
        let (view, coordinator) = editor("```\n---")
        withExtendedLifetime(coordinator) {
            view.insertNewline(nil)
            XCTAssertEqual(view.string, "```\n---\n")
        }
        let (numbered, numberCoordinator) = editor("\(Int.max). item")
        withExtendedLifetime(numberCoordinator) {
            numbered.insertNewline(nil)
            XCTAssertEqual(numbered.string, "\(Int.max). item\n\(Int.max). ")
        }
    }

    func testCommonListAndEmphasisVariants() {
        for (source, expected) in [("* item", "* item\n* "), ("+ item", "+ item\n+ "), ("1) item", "1) item\n2) ")] {
            let (view, coordinator) = editor(source)
            withExtendedLifetime(coordinator) {
                view.insertNewline(nil)
                XCTAssertEqual(view.string, expected)
            }
        }
        XCTAssertEqual(MarkdownFormatting.visibleText(in: "_italic_ __bold__ snake_case"), "italic bold snake_case")
    }

    func testEscapedCharacterDeletionAndCodeUnformatPreserveCharacters() {
        let (view, coordinator) = editor("")
        withExtendedLifetime(coordinator) {
            MarkdownFormatting.apply(.bold, in: view)
            type("*", in: view)
            XCTAssertEqual(MarkdownFormatting.visibleText(in: view.string), "*")
            view.deleteBackward(nil)
            XCTAssertEqual(view.string, "")
            type("x", in: view)
            XCTAssertEqual(view.string, "**x**")
        }
        let (code, codeCoordinator) = editor("`` **a** `b` ``")
        withExtendedLifetime(codeCoordinator) {
            code.selectAll(nil)
            MarkdownFormatting.apply(.code, in: code)
            XCTAssertEqual(MarkdownFormatting.visibleText(in: code.string), "**a** `b`")
            XCTAssertTrue(MarkdownFormatting.spans(in: code.string, style: .bold).isEmpty)
        }
        XCTAssertEqual(MarkdownFormatting.visibleText(in: "\\`literal\\` and `code`"), "`literal` and code")
        let (mixed, mixedCoordinator) = editor("**one** two")
        withExtendedLifetime(mixedCoordinator) {
            mixed.selectAll(nil)
            MarkdownFormatting.apply(.code, in: mixed)
            XCTAssertEqual(MarkdownFormatting.visibleText(in: mixed.string), "one two")
            XCTAssertEqual(MarkdownFormatting.spans(in: mixed.string, style: .bold).count, 1)
            let one = (mixed.string as NSString).range(of: "one")
            let font = mixed.textStorage?.attribute(.font, at: one.location, effectiveRange: nil) as? NSFont
            XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
            XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
            MarkdownFormatting.apply(.code, in: mixed)
            XCTAssertEqual(mixed.string, "**one** two")
        }
    }

    func testLongUniformSpanUsesLocalInsertionInsteadOfReserializingIt() throws {
        let source = "**" + String(repeating: "한", count: 50_000) + "**"
        let caret = source.utf16.count - 2
        let edit = try XCTUnwrap(MarkdownFormattedEditing.insertion(in: source,
            range: NSRange(location: caret, length: 0), replacement: "글", styles: [.bold]))
        XCTAssertEqual(edit.range, NSRange(location: caret, length: 0))
        XCTAssertEqual(edit.replacement, "글")
        XCTAssertEqual(edit.selection, NSRange(location: caret + 1, length: 0))
    }
}
