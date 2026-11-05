import AppKit
import XCTest
@testable import MarkdownEngine

@MainActor
final class MarkdownInlineEditingTests: XCTestCase {
    func testDeletionMovesBoundaryWhitespaceOutsidePairs() {
        for marker in ["~~", "**", "*", "***"] {
            for (content, caret, backward, expected) in [
                ("a b", marker.utf16.count, false, " " + marker + "b" + marker),
                ("a b", marker.utf16.count + 3, true, marker + "a" + marker + " "),
                ("a  b", marker.utf16.count, false, "  " + marker + "b" + marker)
            ] {
                let (view, coordinator) = editor(marker + content + marker)
                withExtendedLifetime(coordinator) {
                    view.setSelectedRange(NSRange(location: caret, length: 0))
                    if backward { view.deleteBackward(nil) } else { view.deleteForward(nil) }
                    XCTAssertEqual(view.string, expected)
                    XCTAssertFalse(MarkdownInlineEditing.formats(in: MarkdownTokenizer.parseTokens(in: view.string)).isEmpty)
                }
            }
        }
    }

    func testNestedWhitespaceAndWhitespaceOnlyReplacement() {
        for (source, selection, replacement, expected) in [
            ("**~~a b~~**", NSRange(location: 4, length: 1), "", " **~~b~~**"),
            ("~~**a b**~~", NSRange(location: 6, length: 1), "", "~~**a**~~ "),
            ("**~~ab~~**", NSRange(location: 4, length: 2), "  ", "  "),
            ("~~abc~~", NSRange(location: 2, length: 3), " 한글😀 ", " ~~한글😀~~ ")
        ] {
            let (view, coordinator) = editor(source)
            withExtendedLifetime(coordinator) {
                view.setSelectedRange(selection)
                view.insertText(replacement, replacementRange: view.selectedRange())
                XCTAssertEqual(view.string, expected)
            }
        }
    }

    func testActualHorizontalAndShiftNavigationSkipsMarkers() {
        for marker in ["~~", "**", "*", "***"] {
            let source = marker + "abc" + marker
            let (view, coordinator) = editor(source)
            withExtendedLifetime(coordinator) {
                view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
                XCTAssertEqual(view.selectedRange(), NSRange(location: marker.utf16.count + 2, length: 0), marker)
                view.setSelectedRange(NSRange(location: 0, length: 0))
                view.doCommand(by: #selector(NSResponder.moveRight(_:)))
                XCTAssertEqual(view.selectedRange(), NSRange(location: marker.utf16.count + 1, length: 0), marker)
                view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
                view.moveLeftAndModifySelection(nil)
                XCTAssertEqual(view.selectedRange().location, marker.utf16.count + 2, marker)
                view.moveRightAndModifySelection(nil)
                XCTAssertEqual(view.selectedRange(), NSRange(location: source.utf16.count, length: 0), marker)
                view.moveLeftAndModifySelection(nil)
                view.deleteBackward(nil)
                XCTAssertEqual(view.string, marker + "ab" + marker)
                view.setSelectedRange(NSRange(location: 0, length: 0))
                view.moveRightAndModifySelection(nil)
                XCTAssertEqual(NSMaxRange(view.selectedRange()), marker.utf16.count + 1, marker)
                view.moveLeftAndModifySelection(nil)
                XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0), marker)
            }
        }
    }

    func testWordNavigationNeverStopsInsideMarkersAndCodeIsLiteral() {
        let (view, coordinator) = editor("**~~one two~~**")
        withExtendedLifetime(coordinator) {
            let markers = MarkdownInlineEditing.formats(in: MarkdownTokenizer.parseTokens(in: view.string)).flatMap(\.markerRanges)
            for _ in 0..<5 {
                view.moveWordLeft(nil)
                XCTAssertFalse(markers.contains { view.selectedRange().location > $0.location && view.selectedRange().location < NSMaxRange($0) })
            }
            for _ in 0..<5 {
                view.moveWordRightAndModifySelection(nil)
                XCTAssertFalse(markers.contains { NSMaxRange(view.selectedRange()) > $0.location && NSMaxRange(view.selectedRange()) < NSMaxRange($0) })
            }
            view.moveToBeginningOfLine(nil)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
            view.moveToEndOfLineAndModifySelection(nil)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: view.string.utf16.count))
        }
        let (code, codeCoordinator) = editor("`~~abc~~`")
        withExtendedLifetime(codeCoordinator) {
            code.setSelectedRange(NSRange(location: 8, length: 0))
            code.moveLeft(nil)
            XCTAssertEqual(code.selectedRange().location, 7)
        }
    }

    func testNestedEmojiNavigationAndShiftReversal() {
        let source = "**~~a👨‍👩‍👧‍👦~~**"
        let (view, coordinator) = editor(source)
        withExtendedLifetime(coordinator) {
            view.moveLeft(nil)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 0))
            view.moveLeftAndModifySelection(nil)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 5))
            view.moveRightAndModifySelection(nil)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 0))
            view.moveRight(nil)
            XCTAssertEqual(view.selectedRange(), NSRange(location: source.utf16.count, length: 0))
        }
    }

    func testWhitespaceRelocationIsOneNativeUndoableEdit() {
        let source = "**~~a b~~**"
        let (view, coordinator) = editor(source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.allowsUndo = true
        withExtendedLifetime(coordinator) {
            let undo = view.undoManager!
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            view.deleteBackward(nil)
            undo.endUndoGrouping()
            XCTAssertEqual(view.string, "**~~a~~** ")
            XCTAssertEqual(view.selectedRange(), NSRange(location: view.string.utf16.count, length: 0))
            undo.undo()
            XCTAssertEqual(view.string, source)
            undo.redo()
            XCTAssertEqual(view.string, "**~~a~~** ")
        }
    }

    func testExplicitSourceReplacementBypassesSemanticWhitespaceAndMarkers() {
        let (view, coordinator) = editor("~~abc~~")
        withExtendedLifetime(coordinator) {
            MarkdownFormatting.replaceSource(in: view, range: NSRange(location: 0, length: 7),
                                             with: "** abc **", selectionAfter: NSRange(location: 2, length: 0))
            XCTAssertEqual(view.string, "** abc **")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        }
    }

    func testNativeBackwardAndForwardKeepSourcePairs() {
        for marker in ["~~", "**", "*", "***"] {
            let (view, coordinator) = editor(marker + "abc" + marker)
            withExtendedLifetime(coordinator) {
                view.deleteBackward(nil)
                XCTAssertEqual(view.string, marker + "ab" + marker)
                view.setSelectedRange(NSRange(location: 0, length: 0))
                view.deleteForward(nil)
                XCTAssertEqual(view.string, marker + "b" + marker)
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
                view.deleteBackward(nil)
                XCTAssertEqual(view.string, "")
            }
        }
    }

    func testNativeComposedCharactersAndNestedFormatting() {
        for (source, expected) in [("~~한글👨‍👩‍👧‍👦~~", "~~한글~~"),
                                   ("**a ~~bc~~**", "**a ~~b~~**"),
                                   ("~~ab~~**cd**", "~~ab~~**c**"),
                                   ("**~~ab~~**", "**~~a~~**"),
                                   ("**~~a~~**", ""),
                                   ("**a `code` bc**", "**a `code` b**"),
                                   ("**e\u{301}**", "")] {
            let (view, coordinator) = editor(source)
            withExtendedLifetime(coordinator) {
                view.deleteBackward(nil)
                XCTAssertEqual(view.string, expected)
            }
        }
    }

    func testSelectedContentDeletionReplacementAndCut() {
        for replacement in ["", "한😀"] {
            let (view, coordinator) = editor("~~abc~~")
            withExtendedLifetime(coordinator) {
                view.setSelectedRange(NSRange(location: 2, length: 3))
                view.insertText(replacement, replacementRange: view.selectedRange())
                XCTAssertEqual(view.string, replacement.isEmpty ? "" : "~~한😀~~")
            }
        }
        let (view, coordinator) = editor("~~abc~~")
        withExtendedLifetime(coordinator) {
            view.setSelectedRange(NSRange(location: 2, length: 3))
            let pasteboard = NSPasteboard.general
            let savedItems = (pasteboard.pasteboardItems ?? []).map { original in
                let item = NSPasteboardItem()
                for type in original.types {
                    if let data = original.data(forType: type) { item.setData(data, forType: type) }
                }
                return item
            }
            defer {
                pasteboard.clearContents()
                if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
            }
            view.cut(nil)
            XCTAssertEqual(view.string, "")
        }
    }

    func testCrossTokenSelectionPreservesSurvivors() {
        let (view, coordinator) = editor("~~abc~~ **def**")
        withExtendedLifetime(coordinator) {
            view.setSelectedRange(NSRange(location: 3, length: 8))
            view.deleteBackward(nil)
            XCTAssertEqual(view.string, "~~a~~**ef**")
        }
        let (siblings, siblingCoordinator) = editor("~~abc~~ ~~def~~")
        withExtendedLifetime(siblingCoordinator) {
            siblings.setSelectedRange(NSRange(location: 4, length: 7))
            siblings.deleteBackward(nil)
            XCTAssertEqual(siblings.string, "~~abef~~")
        }
        let (gap, gapCoordinator) = editor("~~a~~ ~~b~~")
        withExtendedLifetime(gapCoordinator) {
            gap.setSelectedRange(NSRange(location: 6, length: 0))
            gap.deleteBackward(nil)
            XCTAssertEqual(gap.string, "~~ab~~")
        }
    }

    func testCodeAndProseRemainLiteral() {
        let (view, coordinator) = editor("`~~abc~~`")
        withExtendedLifetime(coordinator) {
            view.setSelectedRange(NSRange(location: 8, length: 0))
            view.deleteBackward(nil)
            XCTAssertEqual(view.string, "`~~abc~`")
        }
    }

    func testCommandPathAndReloadRetainStrike() {
        let (view, coordinator) = editor("~~abc~~")
        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(view.string, "~~ab~~")
        XCTAssertEqual(view.textStorage?.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        let (reloaded, reloadCoordinator) = editor(view.string)
        withExtendedLifetime(reloadCoordinator) {
            XCTAssertEqual(reloaded.textStorage?.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) as? Int,
                           NSUnderlineStyle.single.rawValue)
        }
    }

    func testNativeUndoRedoRestoresSource() {
        let (view, coordinator) = editor("~~abc~~")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.allowsUndo = true
        withExtendedLifetime(coordinator) {
            let undo = view.undoManager!
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            view.deleteBackward(nil)
            undo.endUndoGrouping()
            XCTAssertEqual(view.string, "~~ab~~")
            undo.undo()
            XCTAssertEqual(view.string, "~~abc~~")
            undo.redo()
            XCTAssertEqual(view.string, "~~ab~~")
        }
    }

    func testMarkedTextBypassesSemanticEditing() {
        let (view, coordinator) = editor("~~abc~~")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: view.markedRange(), replacementString: "한"))
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.markedRange())
        view.unmarkText()
        XCTAssertEqual(view.string, "~~a한bc~~")
    }

    private func editor(_ source: String) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewWrapper(text: .constant(source)).makeCoordinator()
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: 400))
        layout.textContainer = container
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        view.string = source
        view.delegate = coordinator
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        XCTAssertNotNil(view.textLayoutManager)
        return (view, coordinator)
    }
}
