import AppKit
import SwiftUI
import XCTest
@testable import MarkdownEngine

@MainActor
final class MarkdownFormattedEditingTests: XCTestCase {
    func testStandaloneUnmarkCommitsPendingFormat() {
        withEditor("") { view, _ in
            MarkdownFormatting.apply(.bold, in: view)
            view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            view.unmarkText()
            XCTAssertFalse(view.hasMarkedText())
            XCTAssertEqual(view.string, "**한**")
            type("글", in: view)
            XCTAssertEqual(view.string, "**한글**")
        }
    }

    func testPendingToggleTypesAndExitsWithoutPlaceholder() {
        for (style, marker) in [(MarkdownFormatting.InlineStyle.bold, "**"), (.italic, "*"), (.strikethrough, "~~"), (.code, "`")] {
            withEditor("") { view, _ in
                XCTAssertTrue(MarkdownFormatting.apply(style, in: view))
                XCTAssertEqual(view.string, "")
                type("한글😀", in: view)
                XCTAssertEqual(view.string, marker + "한글😀" + marker)
                MarkdownFormatting.apply(style, in: view)
                type("plain", in: view)
                XCTAssertEqual(view.string, marker + "한글😀" + marker + "plain")
                type("!", in: view)
                XCTAssertEqual(view.string, marker + "한글😀" + marker + "plain!")
            }
        }
    }

    func testSingleKeystrokesKeepOneStrikePair() {
        withEditor("") { view, _ in
            MarkdownFormatting.apply(.strikethrough, in: view)
            for character in "abc" {
                type(String(character), in: view)
                XCTAssertEqual(MarkdownFormatting.spans(in: view.string, style: .strikethrough).count, 1)
            }
            XCTAssertEqual(view.string, "~~abc~~")
        }
    }

    func testTypingInSpanAndTogglingOffSplitsIt() {
        withEditor("~~abcd~~") { view, _ in
            view.setSelectedRange(NSRange(location: 4, length: 0))
            type("X", in: view)
            XCTAssertEqual(view.string, "~~abXcd~~")
            MarkdownFormatting.apply(.strikethrough, in: view)
            type("Y", in: view)
            XCTAssertEqual(view.string, "~~abX~~Y~~cd~~")
            type("Z", in: view)
            XCTAssertEqual(view.string, "~~abX~~YZ~~cd~~")
        }
    }

    func testReplacingWholeFormattedSelectionRetainsMarksAndDeletingCleansPair() {
        withEditor("**hello**") { view, coordinator in
            view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
            type("새😀", in: view)
            XCTAssertEqual(view.string, "**새😀**")
            view.setSelectedRange((view.string as NSString).range(of: "새😀"))
            XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
            XCTAssertEqual(view.string, "")
        }
    }

    func testPartialRemovalPreservesOtherMarksAndUntouchedSource() {
        withEditor("__untouched__\r\n***abcdef***\r\n  suffix  ") { view, _ in
            view.setSelectedRange((view.string as NSString).range(of: "cd"))
            MarkdownFormatting.apply(.bold, in: view)
            XCTAssertEqual(view.string, "__untouched__\r\n***ab**cd**ef***\r\n  suffix  ")
            XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "cd")
            let tokens = MarkdownTokenizer.parseTokens(in: view.string)
            let selected = view.selectedRange()
            XCTAssertTrue(tokens.contains { $0.kind == .italic && NSIntersectionRange($0.contentRange, selected) == selected })
            XCTAssertFalse(tokens.contains { $0.kind == .bold && NSIntersectionRange($0.contentRange, selected).length > 0 })
        }
    }

    func testMixedSelectionAddsThenRemovesOnlyRequestedMark() {
        withEditor("**one** and *two*") { view, _ in
            view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
            MarkdownFormatting.apply(.bold, in: view)
            XCTAssertEqual(view.string, "**one and *two***")
            MarkdownFormatting.apply(.bold, in: view)
            XCTAssertEqual(view.string, "one and *two*")
        }
    }

    func testMultilineWhitespaceAndUnicodeRoundTrip() {
        withEditor("  한글😀  \r\n café \n  ") { view, _ in
            view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
            MarkdownFormatting.apply(.strikethrough, in: view)
            XCTAssertEqual(view.string, "  ~~한글😀~~  \r\n ~~café~~ \n  ")
            let source = view.string
            withEditor(source) { reloaded, _ in
                reloaded.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
                MarkdownFormatting.apply(.strikethrough, in: reloaded)
                XCTAssertEqual(reloaded.string, "  한글😀  \r\n café \n  ")
            }
        }
    }

    func testCodePunctuationIsLiteral() {
        withEditor("`**literal** ~~code~~`") { view, _ in
            view.setSelectedRange((view.string as NSString).range(of: "literal"))
            MarkdownFormatting.apply(.bold, in: view)
            XCTAssertEqual(view.string, "`**literal** ~~code~~`")
            view.setSelectedRange(NSRange(location: 3, length: 0))
            type("X", in: view)
            XCTAssertEqual(view.string, "`**Xliteral** ~~code~~`")
        }
    }

    func testNativeUndoRedoRestoresMarkdownStyleAndContent() {
        withEditor("hello") { view, _ in
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.allowsUndo = true
            let undo = view.undoManager!
            undo.groupsByEvent = false
            view.setSelectedRange(NSRange(location: 0, length: 5))
            undo.beginUndoGrouping()
            MarkdownFormatting.apply(.bold, in: view)
            undo.endUndoGrouping()
            XCTAssertEqual(view.string, "**hello**")
            undo.undo()
            XCTAssertEqual(view.string, "hello")
            undo.redo()
            XCTAssertEqual(view.string, "**hello**")
            view.setSelectedRange(NSRange(location: 7, length: 0))
            undo.beginUndoGrouping()
            type("!", in: view)
            undo.endUndoGrouping()
            XCTAssertEqual(view.string, "**hello!**")
            undo.undo()
            XCTAssertEqual(view.string, "**hello**")
            undo.redo()
            XCTAssertEqual(view.string, "**hello!**")
            window.contentView = nil
        }
    }

    func testMarkedTextAndSourceBypassAreNotReinterpreted() {
        withEditor("hello") { view, coordinator in
            view.setSelectedRange(NSRange(location: 5, length: 0))
            view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
            let composing = view.string
            MarkdownFormatting.apply(.bold, in: view)
            XCTAssertEqual(view.string, composing)
            XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: view.markedRange(), replacementString: "한"))
            view.unmarkText()
            MarkdownFormatting.replaceSource(in: view, range: NSRange(location: 0, length: view.string.utf16.count),
                                             with: "~~raw~~", selectionAfter: NSRange(location: 2, length: 0))
            XCTAssertEqual(view.string, "~~raw~~")
        }
    }

    func testPendingFormatDoesNotRewriteInitialIMEComposition() {
        withEditor("") { view, _ in
            MarkdownFormatting.apply(.bold, in: view)
            view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(view.string, "ㅎ")
            view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.markedRange())
            XCTAssertEqual(view.string, "한")
            view.unmarkText()
        }
    }

    func testPendingFormatResetsOnDocumentAndModeChanges() {
        withEditor("") { view, coordinator in
            coordinator.documentId = "A"
            MarkdownFormatting.apply(.bold, in: view)
            coordinator.documentId = "B"
            type("plain", in: view)
            XCTAssertEqual(view.string, "plain")
            MarkdownFormatting.apply(.bold, in: view)
            coordinator.configuration.inlineEditingMode = .livePreview
            coordinator.configuration.inlineEditingMode = .formatted
            type(" text", in: view)
            XCTAssertEqual(view.string, "plain text")
        }
    }

    func testKoreanCompositionCommitRetainsPendingFormatAndNativeUndo() {
        for explicitRange in [false, true] {
            withEditor("") { view, _ in
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = view
                view.allowsUndo = true
                let undo = view.undoManager!
                undo.groupsByEvent = false
                MarkdownFormatting.apply(.bold, in: view)
                undo.beginUndoGrouping()
                view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertEqual(view.string, "ㅎ")
                view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.markedRange())
                XCTAssertEqual(view.string, "한")
                view.insertText("한", replacementRange: explicitRange ? view.markedRange() : NSRange(location: NSNotFound, length: 0))
                undo.endUndoGrouping()
                XCTAssertFalse(view.hasMarkedText())
                XCTAssertEqual(view.string, "**한**")
                undo.beginUndoGrouping()
                type("글", in: view)
                undo.endUndoGrouping()
                XCTAssertEqual(view.string, "**한글**")
                undo.undo()
                XCTAssertEqual(view.string, "**한**")
                undo.undo()
                XCTAssertEqual(view.string, "")
                undo.redo()
                XCTAssertEqual(view.string, "**한**")
                undo.redo()
                XCTAssertEqual(view.string, "**한글**")
                window.contentView = nil
            }
        }
    }

    func testCompositionCancellationAndDocumentChangeDoNotLeakFormatting() {
        withEditor("") { view, coordinator in
            coordinator.documentId = "A"
            MarkdownFormatting.apply(.bold, in: view)
            view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
            view.insertText("", replacementRange: view.markedRange())
            XCTAssertEqual(view.string, "")
            XCTAssertFalse(view.hasMarkedText())
            view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
            coordinator.documentId = "B"
            view.insertText("한", replacementRange: view.markedRange())
            XCTAssertEqual(view.string, "한")
        }
    }

    private func type(_ text: String, in view: NSTextView) {
        view.insertText(text, replacementRange: view.selectedRange())
    }

    private func withEditor(_ text: String, body: (NativeTextView, NativeTextViewCoordinator) -> Void) {
        let coordinator = NativeTextViewWrapper(text: .constant(text)).makeCoordinator()
        var configuration = MarkdownEditorConfiguration.default
        configuration.inlineEditingMode = .formatted
        coordinator.configuration = configuration
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.configuration = configuration
        view.string = text
        view.delegate = coordinator
        coordinator.textView = view
        view.setSelectedRange(NSRange(location: 0, length: 0))
        withExtendedLifetime(coordinator) { body(view, coordinator) }
    }
}
