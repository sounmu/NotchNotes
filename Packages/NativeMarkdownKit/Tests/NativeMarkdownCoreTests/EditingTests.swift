import XCTest
@testable import NativeMarkdownCore

final class EditingTests: XCTestCase {
    func testImportUsesVisibleTextAndExportsTaskChanges() throws {
        let document = try MarkdownDocument(markdown: "# 제목\n\n- [ ] **한글😀** 작업")
        XCTAssertEqual(document.blocks[1].text, "한글😀 작업")
        var editor = EditingSession(document)
        try editor.apply(.toggleTask(document.blocks[1].id))
        XCTAssertTrue(editor.document.markdown().contains("- [x] **한글😀** 작업"))
        editor.undo(); XCTAssertEqual(editor.document, document)
        editor.redo(); XCTAssertTrue(editor.document.markdown().contains("[x]"))
    }
    func testPartialFormattingAndReplacementUseVisibleUTF16() throws {
        let block = Block(runs: [TextRun("한😀글")])
        var editor = EditingSession(MarkdownDocument(blocks: [block]))
        let selection = BlockSelection(blockID: block.id, range: NSRange(location: 1, length: 2))
        try editor.apply(.toggleMark(.bold, selection))
        XCTAssertEqual(editor.document.markdown(), "한**😀**글")
        try editor.apply(.replace(selection, text: "새", marks: [.italic]))
        XCTAssertEqual(editor.document.blocks[0].text, "한새글")
        editor.undo(); XCTAssertEqual(editor.selection, selection)
        XCTAssertEqual(editor.document.markdown(), "한**😀**글")
    }
    func testRejectsSplitSurrogateAndComposedCharacterWithoutMutation() throws {
        let block = Block(runs: [TextRun("😀e\u{301}")])
        let document = MarkdownDocument(blocks: [block])
        var editor = EditingSession(document)
        for range in [NSRange(location: 1, length: 0), NSRange(location: 2, length: 1), NSRange(location: Int.max, length: 4)] {
            XCTAssertThrowsError(try editor.apply(.replace(.init(blockID: block.id, range: range), text: "x", marks: [])))
            XCTAssertEqual(editor.document, document)
            XCTAssertFalse(editor.canUndo)
        }
    }
    func testSplitTaskKeepsStructureAndUndoRestoresIdentity() throws {
        let document = try MarkdownDocument(markdown: "- [x] **firstsecond**")
        var editor = EditingSession(document)
        try editor.apply(.split(.init(blockID: document.blocks[0].id, range: NSRange(location: 5, length: 0))))
        XCTAssertEqual(editor.document.markdown(), "- [x] **first**\n- [ ] **second**")
        XCTAssertEqual(editor.document.blocks[0].id, document.blocks[0].id)
        XCTAssertNotEqual(editor.document.blocks[1].id, document.blocks[0].id)
        editor.undo(); XCTAssertEqual(editor.document, document)
    }
    func testUnsupportedMarkdownIsRejectedRatherThanSilentlyLost() {
        for source in ["![image](image.png)", "| A | B |\n| - | - |\n| 1 | 2 |"] {
            XCTAssertThrowsError(try MarkdownDocument(markdown: source))
        }
    }
    func testLiteralPunctuationAndCodeSurviveSerialization() throws {
        let document = MarkdownDocument(blocks: [Block(runs: [TextRun("a*b `c` \\ d")]), Block(kind: .code(language: "swift"), runs: [TextRun("let x = `a`\n")])])
        let restored = try MarkdownDocument(markdown: document.markdown())
        XCTAssertEqual(restored.blocks.map(\.text), document.blocks.map(\.text))
    }

    func testOverlappingMarksAndWhitespaceKeepVisibleContentOnReload() throws {
        let block = Block(runs: [TextRun("alpha beta gamma", marks: [.bold])])
        var editor = EditingSession(MarkdownDocument(blocks: [block]))
        try editor.apply(.toggleMark(.italic, .init(blockID: block.id, range: NSRange(location: 6, length: 4))))
        let restored = try MarkdownDocument(markdown: editor.document.markdown())
        XCTAssertEqual(restored.blocks[0].text, block.text)
        XCTAssertTrue(restored.blocks[0].runs.contains(where: { $0.text.contains("beta") && $0.marks == [.bold, .italic] }))
        XCTAssertTrue(restored.blocks[0].runs.allSatisfy { $0.marks.contains(.bold) })
    }
}
