import AppKit
import MarkdownEngine
import XCTest
@testable import NotchNotes

private final class IndentationUndoTextView: NSTextView {
    let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}

@MainActor
final class MarkdownListIndentationTests: XCTestCase {
    func testRepeatedTabIndentsOrderedMarkerAndBacktabRestoresEachLevel() {
        let (textView, coordinator) = makeEditor("1. item")

        XCTAssertFalse(insertTab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t1. item")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)

        XCTAssertFalse(insertTab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t\t1. item")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)

        XCTAssertTrue(insertBacktab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t1. item")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)

        XCTAssertTrue(insertBacktab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "1. item")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)
    }

    func testBacktabPreservesRemainingIndentationWhenRestoringOrderedMarker() {
        let (textView, coordinator) = makeEditor("\t\ta. item")

        XCTAssertTrue(insertBacktab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t1. item")
    }

    func testTabOnlyAddsIndentationToUnorderedAndTodoMarkers() {
        let cases = [
            ("- item", "\t- item"),
            ("• item", "\t• item"),
            ("- [ ] todo", "\t- [ ] todo"),
            ("• [x] done", "\t• [x] done")
        ]

        for (input, expected) in cases {
            let (textView, coordinator) = makeEditor(input)

            XCTAssertFalse(insertTab(in: textView, with: coordinator), input)
            XCTAssertEqual(textView.string, expected, input)
        }
    }

    func testBacktabRaisesUnorderedAndTodoItemsWithoutChangingMarkers() {
        let cases = [
            "\t- item",
            "\t• item",
            "\t- [ ] todo",
            "\t• [x] done"
        ]

        for input in cases {
            let (textView, coordinator) = makeEditor(input)

            XCTAssertTrue(insertBacktab(in: textView, with: coordinator), input)
            XCTAssertEqual(textView.string, String(input.dropFirst()), input)
        }
    }

    func testBacktabDoesNotUnderflowTopLevelLists() {
        let cases = ["1. item", "a. item", "- item", "• item", "- [ ] todo"]

        for input in cases {
            let (textView, coordinator) = makeEditor(input)

            XCTAssertTrue(insertBacktab(in: textView, with: coordinator), input)
            XCTAssertEqual(textView.string, input, input)
        }
    }

    func testReturnContinuesUnorderedAndTodoItemsAtSameIndentation() {
        let cases = [
            ("- item", "- item\n- "),
            ("• item", "• item\n• "),
            ("- [ ] todo", "- [ ] todo\n- [ ] "),
            ("• [x] done", "• [x] done\n• [ ] "),
            ("\t- [ ] todo", "\t- [ ] todo\n\t- [ ] ")
        ]

        for (input, expected) in cases {
            let (textView, coordinator) = makeEditor(input)

            XCTAssertFalse(insertNewline(in: textView, with: coordinator), input)
            XCTAssertEqual(textView.string, expected, input)
        }
    }

    func testReturnContinuesOrderedItemsWithStandardNumbersAtSameIndentation() {
        let cases = [
            ("1. item", "1. item\n2. "),
            ("\t1. item", "\t1. item\n\t2. "),
            ("9. item", "9. item\n10. ")
        ]

        for (input, expected) in cases {
            let (textView, coordinator) = makeEditor(input)

            XCTAssertFalse(insertNewline(in: textView, with: coordinator), input)
            XCTAssertEqual(textView.string, expected, input)
        }
    }

    func testTabIndentsContinuationLinesOfMultilineListItem() {
        let (textView, coordinator) = makeEditor("- first  \n  second")
        textView.setSelectedRange(NSRange(location: 7, length: 0))

        XCTAssertFalse(insertTab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t- first  \n\t  second")
        XCTAssertEqual(textView.selectedRange().location, 8)
    }

    func testTabOnContinuationLineIndentsWholeItemAndPreservesCaret() {
        let (textView, coordinator) = makeEditor("- first  \n  second")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        XCTAssertFalse(insertTab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t- first  \n\t  second")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)
    }

    func testTabFromBlankContinuationLineIndentsWholeItem() {
        let (textView, coordinator) = makeEditor("- item  \n    \n  ")
        textView.setSelectedRange(NSRange(location: 11, length: 0))

        XCTAssertFalse(insertTab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t- item  \n\t    \n\t  ")
        XCTAssertEqual(textView.selectedRange().location, 13)
    }

    func testTabDoesNotIndentSiblingListItems() {
        let (textView, coordinator) = makeEditor("- first  \n  second\n- sibling")
        textView.setSelectedRange(NSRange(location: 7, length: 0))

        XCTAssertFalse(insertTab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t- first  \n\t  second\n- sibling")
    }

    func testReturnAfterIndentedContinuationContinuesListAtNewIndent() {
        let (textView, coordinator) = makeEditor("- first  \n  second")
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertFalse(insertTab(in: textView, with: coordinator))

        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        XCTAssertFalse(insertNewline(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t- first  \n\t  second\n\t- ")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)
    }

    func testBacktabOutdentsContinuationLinesOfMultilineListItem() {
        let (textView, coordinator) = makeEditor("\t- first  \n\t  second")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        XCTAssertTrue(insertBacktab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "- first  \n  second")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)
    }

    func testBacktabDoesNotOutdentSiblingListItems() {
        let (textView, coordinator) = makeEditor("\t- first  \n\t  second\n\t- sibling")
        textView.setSelectedRange(NSRange(location: 9, length: 0))

        XCTAssertTrue(insertBacktab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "- first  \n  second\n\t- sibling")
    }

    func testBacktabPreservesSelectionAcrossContinuationLines() {
        let (textView, coordinator) = makeEditor("\t- first  \n\t  second")
        textView.setSelectedRange(NSRange(location: 3, length: (textView.string as NSString).length - 3))

        XCTAssertTrue(insertBacktab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "- first  \n  second")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: (textView.string as NSString).length - 2))
    }

    func testUndoRestoresContinuationIndentForTabAndBacktab() {
        let (textView, coordinator, undoManager) = makeUndoableEditor("- first  \n  second")
        textView.setSelectedRange(NSRange(location: 7, length: 0))

        XCTAssertFalse(insertTab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "\t- first  \n\t  second")

        undoManager.undo()
        XCTAssertEqual(textView.string, "- first  \n  second")

        undoManager.redo()
        XCTAssertEqual(textView.string, "\t- first  \n\t  second")

        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        XCTAssertTrue(insertBacktab(in: textView, with: coordinator))
        XCTAssertEqual(textView.string, "- first  \n  second")

        undoManager.undo()
        XCTAssertEqual(textView.string, "\t- first  \n\t  second")
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
        let textView = IndentationUndoTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.string = text
        textView.delegate = coordinator
        textView.allowsUndo = true
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return (textView, coordinator, textView.testUndoManager)
    }

    private func insertTab(in textView: NSTextView, with coordinator: NativeTextViewCoordinator) -> Bool {
        coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "\t"
        )
    }

    private func insertNewline(in textView: NSTextView, with coordinator: NativeTextViewCoordinator) -> Bool {
        coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "\n"
        )
    }

    private func insertBacktab(in textView: NSTextView, with coordinator: NativeTextViewCoordinator) -> Bool {
        coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
    }
}
