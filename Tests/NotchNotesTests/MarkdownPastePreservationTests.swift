import AppKit
import XCTest
@testable import MarkdownEngine

@MainActor
final class MarkdownPastePreservationTests: XCTestCase {
    func testPastePreservesMarkdownWhitespaceAndSelectionReplacement() {
        for pasted in ["  nested  \n    next\n\n\n", "\t- 한글😀  \n\t  다음", "  ", "\n\n\n", "    code\r\n    next\r\n"] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString(pasted, forType: .string)
            let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            let coordinator = NativeTextViewWrapper(text: .constant("before OLD after")).makeCoordinator()
            view.delegate = coordinator
            view.string = "before OLD after"
            view.setSelectedRange(NSRange(location: 7, length: 3))
            withExtendedLifetime(coordinator) {
                XCTAssertTrue(view.insertPlainText(from: board))
                XCTAssertEqual(view.string, "before " + pasted + " after")
                XCTAssertEqual(view.selectedRange().location, 7 + pasted.utf16.count)
            }
        }
    }

    func testPasteIntoReadOnlyEditorDoesNotMutateText() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("changed", forType: .string)
        let view = NativeTextView(frame: .zero)
        view.string = "original"
        view.isEditable = false
        XCTAssertFalse(view.insertPlainText(from: board))
        XCTAssertEqual(view.string, "original")
    }
}
