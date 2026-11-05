import AppKit
import XCTest
import SwiftUI
@testable import MarkdownEngine
@testable import NotchNotes

@MainActor
final class MarkdownToolbarTests: XCTestCase {
    func testInlineCommandsToggleUnicodeAndMultilineSelections() {
        for (command, marker) in [(MarkdownCommand.bold, "**"), (.italic, "*"), (.strikethrough, "~~"), (.inlineCode, "`")] {
            for input in ["한글😀", " 첫째\n\n둘째  \n"] {
                withEditor(input) { view, state in
                    state.applyMarkdownCommand(command)
                    XCTAssertTrue(view.string.contains(marker + "한글😀" + marker) || view.string.contains(marker + "첫째" + marker))
                    state.applyMarkdownCommand(command)
                    XCTAssertEqual(view.string, input)
                }
            }
        }
    }

    func testMixedFormattingMergesCompleteSpans() {
        for (command, input, expected) in [
            (MarkdownCommand.bold, "**a** b **c**", "**a b c**"),
            (.italic, "*a* b *c*", "*a b c*"),
            (.inlineCode, "`a` b `c`", "`a b c`")
        ] {
            withEditor(input) { view, state in
                state.applyMarkdownCommand(command)
                XCTAssertEqual(view.string, expected)
            }
        }
    }

    func testPartialSpansAndCodeAreNotDestructivelyRewritten() {
        for (command, input, selected) in [
            (MarkdownCommand.bold, "**abc** tail", "bc** ta"),
            (.italic, "*abc*", "b"),
            (.strikethrough, "~~abc~~ tail", "bc~~ ta"),
            (.inlineCode, "`abc`", "b"),
            (.strikethrough, "`~~abc~~`", "~~abc~~"),
            (.bold, "```\nabc\n```", "abc")
        ] {
            withEditor(input) { view, state in
                view.setSelectedRange((input as NSString).range(of: selected))
                state.applyMarkdownCommand(command)
                XCTAssertEqual(view.string, input)
            }
        }
    }

    func testNoSelectionRetainsSelectedPlaceholderBehavior() {
        for (command, marker, placeholder) in [
            (MarkdownCommand.bold, "**", "bold"), (.italic, "*", "italic"),
            (.strikethrough, "~~", "strikethrough"), (.inlineCode, "`", "code")
        ] {
            withEditor("") { view, state in
                state.applyMarkdownCommand(command)
                XCTAssertEqual(view.string, marker + placeholder + marker)
                XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), placeholder)
            }
        }
    }

    func testNativePlainTextCopyUsesRawSelection() {
        withEditor("~~한글😀~~") { view, _ in
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
            XCTAssertEqual(pasteboard.string(forType: .string), "~~한글😀~~")
            view.setSelectedRange(NSRange(location: 2, length: 4))
            pasteboard.clearContents()
            XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
            XCTAssertEqual(pasteboard.string(forType: .string), "한글😀")
        }
    }

    func testNativeCallbackAndUndoPreserveRawMarkdown() async {
        let updated = expectation(description: "Binding receives Markdown")
        var stored = "한글😀"
        let coordinator = NativeTextViewWrapper(text: Binding(get: { stored }, set: {
            stored = $0
            if $0 == "**한글😀**" { updated.fulfill() }
        })).makeCoordinator()
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = ToolbarUndoWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.string = stored
        view.delegate = coordinator
        view.allowsUndo = true
        view.setSelectedRange(NSRange(location: 0, length: stored.utf16.count))
        let state = EditorInteractionState()
        state.bind(containerView: nil, textView: view)
        state.applyMarkdownCommand(.bold)
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(stored, "**한글😀**")
        XCTAssertTrue(window.testUndoManager.canUndo)
        window.testUndoManager.undo()
        XCTAssertEqual(view.string, "한글😀")
        window.orderOut(nil)
        withExtendedLifetime(coordinator) {}
    }

    private func withEditor(_ input: String, body: (NativeTextView, EditorInteractionState) -> Void) {
        let coordinator = NativeTextViewWrapper(text: .constant(input)).makeCoordinator()
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = input
        view.delegate = coordinator
        view.setSelectedRange(NSRange(location: 0, length: input.utf16.count))
        let state = EditorInteractionState()
        state.bind(containerView: nil, textView: view)
        withExtendedLifetime(coordinator) { body(view, state) }
    }

    func testStrikeButtonDoesNotConsumeNeighboringMarkers() {
        for (input, selected, expected) in [
            ("~~a~~ or ~~b~~", " or ", "~~a~~ ~~or~~ ~~b~~"),
            ("~~a~~ b ~~c~~", "~~a~~ b ~~c~~", "~~a b c~~")
        ] {
            let coordinator = NativeTextViewWrapper(text: .constant(input)).makeCoordinator()
            let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            view.string = input
            view.delegate = coordinator
            view.setSelectedRange((input as NSString).range(of: selected))
            let state = EditorInteractionState()
            state.bind(containerView: nil, textView: view)
            state.applyMarkdownCommand(.strikethrough)
            withExtendedLifetime(coordinator) {
                XCTAssertEqual(view.string, expected)
            }
        }
    }

    func testStrikeButtonAppliesVisibleStyleToSelectedText() {
        for input in ["ㅇ", "한글", "한글 ", " 첫째\n둘째\n", "한글😀\n\n  둘째  "] {
            let coordinator = NativeTextViewWrapper(text: .constant(input)).makeCoordinator()
            let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            XCTAssertNotNil(view.textLayoutManager)
            view.string = input
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: 0, length: (input as NSString).length))
            let state = EditorInteractionState()
            state.bind(containerView: nil, textView: view)
            state.applyMarkdownCommand(.strikethrough)
            withExtendedLifetime(coordinator) {
                let text = view.string as NSString
                for word in input.split(whereSeparator: { $0.isWhitespace }) {
                    let range = text.range(of: String(word))
                    XCTAssertEqual(view.textStorage?.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue, input)
                }
                state.applyMarkdownCommand(.strikethrough)
                XCTAssertEqual(view.string, input, "Second click should remove formatting without losing whitespace")
                for word in input.split(whereSeparator: { $0.isWhitespace }) {
                    let range = (view.string as NSString).range(of: String(word))
                    XCTAssertNil(view.textStorage?.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil))
                }
            }
        }
    }
}

@MainActor
private final class ToolbarUndoWindow: NSWindow {
    let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}
