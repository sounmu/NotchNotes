import XCTest
@testable import NativeMarkdownCore

final class ClipboardEditingTests: XCTestCase {
    func testFragmentReplacementKeepsSurroundingRunsAndUndoesAsOneEdit() throws {
        let original = try MarkdownDocument(markdown: "**before** after")
        var session = EditingSession(original)
        let selection = NSRange(location: 3, length: 6)
        try session.select(selection)
        let fragment = try MarkdownDocument(markdown: "*one*\n\ntwo")

        try session.apply(.replaceFragment(selection, fragment))

        XCTAssertEqual(session.document.visibleText, "befone\ntwoter")
        XCTAssertEqual(session.document.blocks[0].runs, [TextRun("bef", marks: [.bold]), TextRun("one", marks: [.italic])])
        XCTAssertEqual(session.selectedRange, NSRange(location: 10, length: 0))
        session.undo()
        XCTAssertEqual(session.document, original)
        XCTAssertEqual(session.selectedRange, selection)
        XCTAssertFalse(session.canUndo)
    }

    func testPartialFragmentKeepsSelectedMarksAndNormalizesNestedListDepth() throws {
        let document = try MarkdownDocument(markdown: "- parent\n  - **child**\n  - sibling")
        let fragment = try document.fragment(in: NSRange(location: 9, length: 8))
        XCTAssertEqual(fragment.visibleText, "ild\nsibl")
        XCTAssertEqual(fragment.blocks.map(\.kind), [.bullet(depth: 0), .bullet(depth: 0)])
        XCTAssertEqual(fragment.blocks[0].runs, [TextRun("ild", marks: [.bold])])
    }

    func testPastingAtStartOfExistingHeadingRetainsDestinationKind() throws {
        let fragment = try MarkdownDocument(markdown: "- foo").fragment(in: NSRange(location: 0, length: 3))
        var session = EditingSession(try MarkdownDocument(markdown: "# Title"))

        try session.apply(.replaceFragment(NSRange(location: 0, length: 0), fragment))

        XCTAssertEqual(session.document.blocks[0].kind, .heading(1))
        XCTAssertEqual(session.document.visibleText, "fooTitle")
    }

    func testMultipleTasksPasteAsBlocksWithoutChangingSurroundingParagraph() throws {
        let fragment = try MarkdownDocument(markdown: "- [ ] first\n- [x] second")
        for offset in [0, 1] {
            var session = EditingSession(try MarkdownDocument(markdown: "xy"))

            try session.apply(.replaceFragment(NSRange(location: offset, length: 0), fragment))

            let expectedKinds: [BlockKind] = (offset == 0 ? [] : [.paragraph]) +
                [.task(checked: false, depth: 0), .task(checked: true, depth: 0), .paragraph]
            XCTAssertEqual(session.document.blocks.map(\.kind), expectedKinds)
            XCTAssertEqual(session.document.visibleText, offset == 0 ? "first\nsecond\nxy" : "x\nfirst\nsecond\ny")
            XCTAssertEqual(Set(session.document.blocks.map(\.id)).count, session.document.blocks.count)
        }
    }
}
