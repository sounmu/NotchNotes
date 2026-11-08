import XCTest
@testable import NativeMarkdownCore

final class DocumentEditingTests: XCTestCase {
    func testCrossBlockReplaceDeleteAndUndoRetainIdentityAndSelection() throws {
        let document = try MarkdownDocument(markdown: "**first**\n\nsecond\n\nthird")
        var session = EditingSession(document)
        let selection = NSRange(location: 3, length: 7)
        try session.select(selection)
        try session.apply(.replaceDocument(selection, text: "한😀\nnew", marks: [.italic]))
        XCTAssertEqual(session.document.visibleText, "fir한😀\nnewnd\nthird")
        XCTAssertEqual(session.document.blocks[0].id, document.blocks[0].id)
        XCTAssertEqual(session.document.blocks[2].id, document.blocks[2].id)
        session.undo()
        XCTAssertEqual(session.document, document)
        XCTAssertEqual(session.selectedRange, selection)
        session.redo()
        try session.apply(.replaceDocument(NSRange(location: 6, length: 1), text: "", marks: []))
        XCTAssertEqual(session.document.visibleText, "fir한😀newnd\nthird")
    }

    func testFormattingAcrossParagraphsAndMixedState() throws {
        var session = EditingSession(try MarkdownDocument(markdown: "**first**\n\nsecond"))
        let range = NSRange(location: 2, length: 7)
        XCTAssertEqual(session.document.formatting(in: range).mixed, [.bold])
        try session.apply(.formatDocument(.bold, range))
        XCTAssertEqual(session.document.formatting(in: range).active, [.bold])
        try session.apply(.formatDocument(.bold, range))
        XCTAssertEqual(session.document.formatting(in: range).active, [])
        XCTAssertEqual(session.document.visibleText, "first\nsecond")
    }

    func testTaskContinuationExitAndOrderedRenumbering() throws {
        var session = EditingSession(try MarkdownDocument(markdown: "- [x] task"))
        try session.apply(.replaceDocument(NSRange(location: 4, length: 0), text: "\n", marks: []))
        XCTAssertEqual(session.document.blocks[1].kind, .task(checked: false, depth: 0))
        try session.apply(.replaceDocument(session.selectedRange, text: "\n", marks: []))
        XCTAssertEqual(session.document.blocks.count, 2)
        XCTAssertEqual(session.document.blocks[1].kind, .paragraph)
        session = EditingSession(try MarkdownDocument(markdown: "1. one\n2. two"))
        try session.apply(.replaceDocument(NSRange(location: 3, length: 0), text: "\nnew", marks: []))
        XCTAssertEqual(session.document.blocks.map(\.kind), [.ordered(number: 1, depth: 0), .ordered(number: 2, depth: 0), .ordered(number: 3, depth: 0)])
    }

    func testUnicodeBoundariesAndCodeNewlines() throws {
        var session = EditingSession(try MarkdownDocument(markdown: "😀\n\ne\u{301}"))
        for range in [NSRange(location: 1, length: 0), NSRange(location: 3, length: 1), NSRange(location: Int.max, length: 1)] {
            XCTAssertThrowsError(try session.apply(.replaceDocument(range, text: "bad", marks: [])))
        }
        XCTAssertFalse(session.canUndo)
        session = EditingSession(try MarkdownDocument(markdown: "```swift\na\n```"))
        try session.apply(.replaceDocument(NSRange(location: 1, length: 0), text: "\nb", marks: []))
        XCTAssertEqual(session.document.blocks.count, 1)
        XCTAssertEqual(session.document.blocks[0].text, "a\nb\n")
    }

    func testMarkdownTypingRulesUseModelTransactions() throws {
        var session = EditingSession(MarkdownDocument())
        for character in "- [ ] **task**" {
            try session.apply(.replaceDocument(session.selectedRange, text: String(character), marks: []))
        }
        XCTAssertEqual(session.document.visibleText, "task")
        XCTAssertEqual(session.document.blocks[0].kind, .task(checked: false, depth: 0))
        XCTAssertEqual(session.document.blocks[0].runs[0].marks, [.bold])
        session.undo()
        XCTAssertEqual(session.document.visibleText, "**task*")
        session = EditingSession(MarkdownDocument())
        for character in "## Title" { try session.apply(.replaceDocument(session.selectedRange, text: String(character), marks: [])) }
        XCTAssertEqual(session.document.blocks[0].kind, .heading(2))
        XCTAssertEqual(session.document.visibleText, "Title")
    }

    func testLinksSurviveFormattingAndSplitting() throws {
        var session = EditingSession(try MarkdownDocument(markdown: "[hello](https://example.com)"))
        try session.apply(.formatDocument(.bold, NSRange(location: 0, length: 2)))
        let restored = try MarkdownDocument(markdown: session.document.markdown())
        XCTAssertEqual(restored.blocks[0].text, "hello")
        XCTAssertTrue(restored.blocks[0].runs.allSatisfy { $0.link == "https://example.com" })
    }

    func testFormattingWhitespaceDoesNotLeakMarkdownDelimiters() throws {
        var session = EditingSession(try MarkdownDocument(markdown: "a b c"))
        try session.apply(.formatDocument(.bold, NSRange(location: 1, length: 3)))
        let markdown = session.document.markdown()
        let restored = try MarkdownDocument(markdown: markdown)
        XCTAssertEqual(restored.visibleText, "a b c", markdown)
        XCTAssertTrue(restored.blocks[0].runs.contains { $0.text.contains("b") && $0.marks.contains(.bold) }, markdown)
    }
}
