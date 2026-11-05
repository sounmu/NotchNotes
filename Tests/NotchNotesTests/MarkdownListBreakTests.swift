import AppKit
import XCTest
@testable import MarkdownEngine
@testable import NotchNotes

private final class UndoTextView: NSTextView {
    let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}

@MainActor
final class MarkdownListBreakTests: XCTestCase {
    func testShiftReturnOnEmptyItemBeforeSiblingKeepsTwoSpaceIndent() {
        let (view, coordinator) = makeEditor("- \n- sibling")
        withExtendedLifetime(coordinator) {
            view.setSelectedRange(NSRange(location: 2, length: 0))
            XCTAssertTrue(shiftReturn(in: view))
            XCTAssertEqual(view.string, "-   \n  \n- sibling")
            view.insertText("continued", replacementRange: view.selectedRange())
            view.insertText("\n", replacementRange: view.selectedRange())
            XCTAssertEqual(view.string, "-   \n  continued\n- \n- sibling")
        }
    }

    func testReturnReplacingMarkerUsesNormalReplacement() {
        let (view, coordinator) = makeEditor("- item\n- sibling")
        withExtendedLifetime(coordinator) {
            view.setSelectedRange(NSRange(location: 0, length: 6))
            view.insertText("\n", replacementRange: view.selectedRange())
            XCTAssertEqual(view.string, "\n\n- sibling")
        }
    }

    func testReturnSelectionIncludingLineEndingDoesNotDuplicateSiblingMarker() {
        let (view, coordinator) = makeEditor("- first\n- sibling")
        withExtendedLifetime(coordinator) {
            view.setSelectedRange(NSRange(location: 2, length: 6))
            view.insertText("\n", replacementRange: view.selectedRange())
            XCTAssertEqual(view.string, "- \n- sibling")
        }
    }

    func testShiftReturnSelectionIncludingLineEndingUsesNormalReplacement() {
        let (view, coordinator) = makeEditor("- first\n- sibling")
        withExtendedLifetime(coordinator) {
            view.setSelectedRange(NSRange(location: 2, length: 6))
            XCTAssertFalse(shiftReturn(in: view))
            view.insertText("\n", replacementRange: view.selectedRange())
            XCTAssertEqual(view.string, "- \n- sibling")
        }
    }

    func testTypedTaskHardBreakIndentReturnUndoRedoSequence() {
        let (view, coordinator, undo) = makeUndoableEditor("- [x] task")
        undo.groupsByEvent = false
        withExtendedLifetime(coordinator) {
            undo.beginUndoGrouping()
            XCTAssertTrue(shiftReturn(in: view))
            undo.endUndoGrouping()
            undo.beginUndoGrouping()
            view.insertText("한글😀", replacementRange: view.selectedRange())
            undo.endUndoGrouping()
            undo.beginUndoGrouping()
            view.insertText("\t", replacementRange: view.selectedRange())
            undo.endUndoGrouping()
            XCTAssertEqual(view.string, "\t- [x] task  \n\t      한글😀")
            undo.beginUndoGrouping()
            view.insertText("\n", replacementRange: view.selectedRange())
            undo.endUndoGrouping()
            let expected = "\t- [x] task  \n\t      한글😀\n\t- [ ] "
            XCTAssertEqual(view.string, expected)
            XCTAssertEqual(view.selectedRange().location, (expected as NSString).length)
            undo.undo()
            XCTAssertEqual(view.string, "\t- [x] task  \n\t      한글😀")
            undo.redo()
            XCTAssertEqual(view.string, expected)
        }
    }

    func testShiftReturnInsertsStandardHardBreakWithContinuationIndent() {
        let cases = [
            ("- item", "- item  \n  "),
            ("\t- item", "\t- item  \n\t  "),
            ("1. item", "1. item  \n   "),
            ("\t1. item", "\t1. item  \n\t   "),
            ("10. item", "10. item  \n    "),
            ("- [ ] todo", "- [ ] todo  \n      ")
        ]

        for (input, expected) in cases {
            let (textView, _) = makeEditor(input)

            XCTAssertTrue(shiftReturn(in: textView), input)
            XCTAssertEqual(textView.string, expected, input)
            XCTAssertEqual(textView.selectedRange().location, (expected as NSString).length, input)
            XCTAssertFalse(
                textView.string.unicodeScalars.contains { $0.value == 0x2028 },
                "hard breaks must not store U+2028: \(input)"
            )
        }
    }

    func testShiftReturnContinuesAnExistingBackslashHardBreakLine() {
        // Existing documents may use the backslash form; keep recognizing it.
        let (textView, _) = makeEditor("- item\\\n  first")

        XCTAssertTrue(shiftReturn(in: textView))
        XCTAssertEqual(textView.string, "- item\\\n  first  \n  ")
    }

    func testRepeatedShiftReturnKeepsContinuationIndent() {
        let (textView, _) = makeEditor("- item")

        XCTAssertTrue(shiftReturn(in: textView))
        XCTAssertEqual(textView.string, "- item  \n  ")

        XCTAssertTrue(shiftReturn(in: textView))
        XCTAssertEqual(textView.string, "- item  \n    \n  ")

        XCTAssertTrue(shiftReturn(in: textView))
        XCTAssertEqual(textView.string, "- item  \n    \n    \n  ")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)
    }

    func testShiftReturnAppendsTwoSpacesAndPreservesExistingTrailingWhitespace() {
        let (textView, _) = makeEditor("- item ")

        XCTAssertTrue(shiftReturn(in: textView))
        XCTAssertEqual(textView.string, "- item   \n  ")
    }

    func testHardBreakDetectionUsesOddBackslashCountAndTwoSpaces() {
        XCTAssertTrue(MarkdownLists.endsWithHardBreak("- item\\\n"))
        XCTAssertFalse(MarkdownLists.endsWithHardBreak("- item\\\\\n"))
        XCTAssertTrue(MarkdownLists.endsWithHardBreak("- item\\\\\\\n"))
        XCTAssertTrue(MarkdownLists.endsWithHardBreak("- item  \n"))
        XCTAssertFalse(MarkdownLists.endsWithHardBreak("- item \n"))
        XCTAssertFalse(MarkdownLists.endsWithHardBreak("- item"))
    }

    func testEscapedTrailingBackslashIsNotAHardBreak() {
        // Even backslashes are an escaped backslash, not a hard break, so
        // Enter must fall through to AppKit instead of continuing the list.
        let (textView, coordinator) = makeEditor("- item\\\\\n  first")

        XCTAssertTrue(returnKey(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "- item\\\\\n  first")
    }

    func testReturnAfterRepeatedShiftReturnCreatesTheNextListItem() {
        let (textView, coordinator) = makeEditor("- item  \n    \n  ")

        XCTAssertFalse(returnKey(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "- item  \n    \n  \n- ")
    }

    func testShiftReturnReplacesSelectionWithoutDroppingIt() {
        let (textView, _) = makeEditor("- item")
        textView.setSelectedRange(NSRange(location: 3, length: 3))

        XCTAssertTrue(shiftReturn(in: textView))
        XCTAssertEqual(textView.string, "- i  \n  ")
    }

    func testShiftReturnInNormalParagraphInsertsStandardHardBreak() {
        let (textView, _) = makeEditor("plain text")

        XCTAssertTrue(shiftReturn(in: textView))
        XCTAssertEqual(textView.string, "plain text  \n")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)
        XCTAssertFalse(textView.string.unicodeScalars.contains { $0.value == 0x2028 })
    }

    func testShiftReturnInNormalParagraphReplacesSelection() {
        let (textView, _) = makeEditor("plain text")
        textView.setSelectedRange(NSRange(location: 6, length: 4))

        XCTAssertTrue(shiftReturn(in: textView))
        XCTAssertEqual(textView.string, "plain   \n")
    }

    func testShiftReturnKeepsPlainNewlineInCodeBlocksAndInlineCode() {
        let (codeTextView, _) = makeEditor("```\n- item\n```")
        codeTextView.setSelectedRange(NSRange(location: 10, length: 0))

        XCTAssertFalse(shiftReturn(in: codeTextView))
        XCTAssertEqual(codeTextView.string, "```\n- item\n```")

        // AppKit's insertNewline path must produce a plain LF, not a hard break.
        codeTextView.insertText("\n", replacementRange: codeTextView.selectedRange())
        XCTAssertEqual(codeTextView.string, "```\n- item\n\n```")
        XCTAssertFalse(codeTextView.string.contains("\\"))

        let (inlineTextView, _) = makeEditor("`- item`")
        inlineTextView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertFalse(shiftReturn(in: inlineTextView))
        XCTAssertEqual(inlineTextView.string, "`- item`")
    }

    func testShiftReturnAfterClosedInlineCodeInsertsHardBreakOutsideCode() {
        let (textView, _) = makeEditor("- `code`")

        XCTAssertTrue(shiftReturn(in: textView))
        XCTAssertEqual(textView.string, "- `code`  \n  ")
        XCTAssertEqual(textView.selectedRange().location, ("- `code`  \n  " as NSString).length)
    }

    func testShiftReturnAfterClosedInlineCodeInParagraphInsertsHardBreak() {
        let (textView, _) = makeEditor("text `code`")

        XCTAssertTrue(shiftReturn(in: textView))
        XCTAssertEqual(textView.string, "text `code`  \n")
    }

    func testShiftReturnKeepsPlainNewlineInUnclosedFencedCode() {
        let cases = [
            "```\n- item",
            "```swift\n- item",
            "~~~\n- item",
            "~~~swift\n- item"
        ]

        for input in cases {
            let (textView, coordinator) = makeEditor(input)

            XCTAssertFalse(shiftReturn(in: textView), input)
            XCTAssertEqual(textView.string, input, input)

            // Plain Enter must fall through to AppKit and must not continue a list.
            XCTAssertTrue(returnKey(in: textView, with: coordinator), input)
            XCTAssertEqual(textView.string, input, input)
        }
    }

    func testShiftReturnKeepsPlainNewlineInsideClosedTildeAndLanguageFences() {
        let cases = [
            "~~~\n- item\n~~~",
            "```swift\n- item\n```"
        ]

        for input in cases {
            let (textView, _) = makeEditor(input)
            let contentLocation = (input as NSString).range(of: "- item").location + 2
            textView.setSelectedRange(NSRange(location: contentLocation, length: 0))

            XCTAssertFalse(shiftReturn(in: textView), input)
            XCTAssertEqual(textView.string, input, input)
        }
    }

    func testShiftReturnAfterClosedFenceInsertsHardBreakOutsideCode() {
        let input = "```\n- item\n```"
        let (textView, _) = makeEditor(input)

        XCTAssertTrue(shiftReturn(in: textView))
        XCTAssertEqual(textView.string, input + "  \n")
    }

    func testReturnAfterHardBreakCreatesTheNextListItem() {
        let cases = [
            // Backslash hard breaks from existing documents round-trip.
            ("- item\\\n  first", "- item\\\n  first\n- "),
            ("- item\\\n  ", "- item\\\n  \n- "),
            ("\t- item\\\n\t  first", "\t- item\\\n\t  first\n\t- "),
            ("1. item\\\n   first", "1. item\\\n   first\n2. "),
            ("- [ ] todo\\\n      first", "- [ ] todo\\\n      first\n- [ ] "),
            // Newly generated two-space hard breaks continue the list too.
            ("- item  \n  first", "- item  \n  first\n- "),
            ("- item  \n  ", "- item  \n  \n- "),
            ("\t- item  \n\t  first", "\t- item  \n\t  first\n\t- "),
            ("1. item  \n   first", "1. item  \n   first\n2. "),
            ("- [ ] todo  \n      first", "- [ ] todo  \n      first\n- [ ] ")
        ]

        for (input, expected) in cases {
            let (textView, coordinator) = makeEditor(input)

            XCTAssertFalse(returnKey(in: textView, with: coordinator), input)
            XCTAssertEqual(textView.string, expected, input)
        }
    }

    func testEmptyNestedItemOutdentsOneLevelThenTerminates() {
        let (textView, coordinator) = makeEditor("\t- ")

        XCTAssertFalse(returnKey(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "- ")
        XCTAssertEqual(textView.selectedRange().location, 2)

        XCTAssertFalse(returnKey(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(textView.selectedRange().location, 0)
    }

    func testDeeplyNestedOrderedItemOutdentsOneLevelAtATime() {
        let (textView, coordinator) = makeEditor("\t\t1. ")

        XCTAssertFalse(returnKey(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t1. ")
        XCTAssertEqual(textView.selectedRange().location, 4)

        XCTAssertFalse(returnKey(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "1. ")
        XCTAssertEqual(textView.selectedRange().location, 3)

        XCTAssertFalse(returnKey(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "")
    }

    func testEmptyTopLevelItemTerminatesTheList() {
        let cases = ["- ", "1. ", "- [ ] "]

        for input in cases {
            let (textView, coordinator) = makeEditor(input)

            XCTAssertFalse(returnKey(in: textView, with: coordinator), input)
            XCTAssertEqual(textView.string, "", input)
        }
    }

    func testReturnReplacesSelectionInsideListItem() {
        let (textView, coordinator) = makeEditor("- item")
        textView.setSelectedRange(NSRange(location: 3, length: 3))

        XCTAssertFalse(returnKey(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "- i\n- ")
    }

    func testReturnLeavesMultiLineSelectionToAppKit() {
        let (textView, coordinator) = makeEditor("- item\n- second")
        textView.setSelectedRange(NSRange(location: 3, length: 10))

        XCTAssertTrue(returnKey(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "- item\n- second")
    }

    func testTabLeavesSelectionReplacementToAppKit() {
        let (textView, coordinator) = makeEditor("- item")
        textView.setSelectedRange(NSRange(location: 2, length: 4))

        XCTAssertTrue(coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "\t"
        ))
        XCTAssertEqual(textView.string, "- item")
    }

    func testInsertNewlineCommandDoesNotHandleWithoutShiftKeyEvent() {
        let (textView, coordinator) = makeEditor("- item")

        // No NSApp.currentEvent keyDown in tests, so this must fall through to
        // AppKit instead of inserting a hard break.
        XCTAssertFalse(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        XCTAssertEqual(textView.string, "- item")
    }

    func testMarkedTextProtectsShiftReturnAndListInsertion() {
        let (textView, coordinator) = makeEditor("- ")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.setMarkedText(
            "ㄱ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 2, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        XCTAssertFalse(shiftReturn(in: textView))
        XCTAssertTrue(coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: textView.selectedRange().location, length: 0),
            replacementString: "\n"
        ))
        textView.unmarkText()
    }

    func testUndoRestoresListContinuationAndHardBreak() {
        let (textView, coordinator, undoManager) = makeUndoableEditor("- item")

        XCTAssertFalse(returnKey(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "- item\n- ")

        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.string, "- item")

        XCTAssertTrue(shiftReturn(in: textView))
        XCTAssertEqual(textView.string, "- item  \n  ")
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.string, "- item")
    }

    private func makeEditor(_ text: String) -> (NSTextView, NativeTextViewCoordinator) {
        let wrapper = NativeTextViewWrapper(text: .constant(text))
        let coordinator = wrapper.makeCoordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        textView.string = text
        textView.delegate = coordinator
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return (textView, coordinator)
    }

    private func makeUndoableEditor(_ text: String) -> (NSTextView, NativeTextViewCoordinator, UndoManager) {
        let wrapper = NativeTextViewWrapper(text: .constant(text))
        let coordinator = wrapper.makeCoordinator()
        let textView = UndoTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.string = text
        textView.delegate = coordinator
        textView.allowsUndo = true
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return (textView, coordinator, textView.testUndoManager)
    }

    private func shiftReturn(in textView: NSTextView) -> Bool {
        MarkdownInputHandler.handleInsertNewline(textView: textView, isShiftPressed: true)
    }

    private func returnKey(in textView: NSTextView, with coordinator: NativeTextViewCoordinator) -> Bool {
        coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "\n"
        )
    }
}
