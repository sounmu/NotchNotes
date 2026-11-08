import XCTest
@testable import NativeMarkdownCore

final class CoreRegressionTests: XCTestCase {
    func testCodeAndUnicodeMarkBoundariesRetainTextAndMarks() throws {
        for runs in [
            [TextRun("call"), TextRun("x", marks: [.bold, .code])],
            [TextRun("x", marks: [.bold, .code]), TextRun("call")],
            [TextRun("인용"), TextRun("“말”", marks: [.bold])],
            [TextRun("“말”", marks: [.bold]), TextRun("인용")]
        ] {
            let document = MarkdownDocument(blocks: [Block(runs: runs)])
            let markdown = document.markdown()
            let restored = try MarkdownDocument(markdown: markdown)
            XCTAssertEqual(restored.blocks[0].runs, runs, markdown)
        }
    }

    func testItalicNeighborRetainsMarksBesideCodeAndPunctuation() throws {
        for runs in [
            [TextRun("call", marks: [.italic]), TextRun("x", marks: [.bold, .code])],
            [TextRun("x", marks: [.bold, .code]), TextRun("call", marks: [.italic])],
            [TextRun("인용", marks: [.italic]), TextRun("“말”", marks: [.bold])],
            [TextRun("“말”", marks: [.bold]), TextRun("인용", marks: [.italic])]
        ] {
            let document = MarkdownDocument(blocks: [Block(runs: runs)])
            let markdown = document.markdown()
            let restored = try MarkdownDocument(markdown: markdown)
            XCTAssertEqual(restored.blocks[0].runs, runs, markdown)
        }
    }

    func testMarkedPunctuationBesideLettersRetainsTextAndMarks() throws {
        for marks: Set<InlineMark> in [[.bold], [.italic], [.strikethrough], [.bold, .italic]] {
            for (left, text, right) in [("a", "#tag", ""), ("", "(x)", "y"), ("a", "(x)", "y"), ("a", "!", "b")] {
                let document = MarkdownDocument(blocks: [Block(runs: [
                    TextRun(left), TextRun(text, marks: marks), TextRun(right)
                ])])
                let markdown = document.markdown()
                let restored = try MarkdownDocument(markdown: markdown)
                XCTAssertEqual(restored.blocks[0].runs.flatMap { run in
                    run.text.map { TextRun(String($0), marks: run.marks) }
                }, document.blocks[0].runs.flatMap { run in
                    run.text.map { TextRun(String($0), marks: run.marks) }
                }, markdown)
            }
        }
    }

    func testAngleBracketLinkDestinationsSurviveReload() throws {
        for source in ["[x](<a b>)", "[x](<a(b>)", "[x](<a)b>)", #"[x](<a\>b>)"#] {
            let document = try MarkdownDocument(markdown: source)
            let markdown = document.markdown()
            let restored = try MarkdownDocument(markdown: markdown)
            XCTAssertEqual(restored.blocks[0].runs, document.blocks[0].runs, markdown)
        }
    }

    func testBacktickInCodeLanguageKeepsFollowingParagraphOnReload() throws {
        for source in [
            "~~~ `x\nbody\n~~~\n\nfollowing",
            "~~~~ swi`ft\n~~~\n```\n~~~~\n\nfollowing"
        ] {
            let document = try MarkdownDocument(markdown: source)
            let markdown = document.markdown()
            let restored = try MarkdownDocument(markdown: markdown)
            XCTAssertEqual(restored.blocks.map(\.kind), document.blocks.map(\.kind), markdown)
            XCTAssertEqual(restored.blocks.map(\.text), document.blocks.map(\.text), markdown)
        }
    }

    func testNestedListRoundtripRetainsKindsAndText() throws {
        for source in [
            "- parent\n  - child\n    - grandchild\n- sibling",
            "10. parent\n    - child\n11. sibling",
            "100. parent\n     - child\n101. sibling",
            "- [ ] parent\n      - child\n- [x] sibling"
        ] {
            let document = try MarkdownDocument(markdown: source)
            let markdown = document.markdown()
            let restored = try MarkdownDocument(markdown: markdown)
            XCTAssertEqual(restored.blocks.map(\.kind), document.blocks.map(\.kind), markdown)
            XCTAssertEqual(restored.visibleText, document.visibleText, markdown)
        }
    }

    func testInlineRoundtripRetainsMarksAndLinks() throws {
        for source in [
            "**bold *both* bold**",
            "*italic **both** italic*",
            "[first\nsecond](https://example.com)",
            "[first  \nsecond](https://example.com)",
            "[**bold** plain *italic*](https://example.com)",
            "**before [linked](https://example.com) after**"
        ] {
            let document = try MarkdownDocument(markdown: source)
            let markdown = document.markdown()
            let restored = try MarkdownDocument(markdown: markdown)
            XCTAssertEqual(restored.visibleText, document.visibleText, markdown)
            XCTAssertEqual(restored.blocks[0].runs.flatMap { run in
                run.text.map { TextRun(String($0), marks: $0.isWhitespace ? [] : run.marks, link: run.link) }
            }, document.blocks[0].runs.flatMap { run in
                run.text.map { TextRun(String($0), marks: $0.isWhitespace ? [] : run.marks, link: run.link) }
            }, markdown)
        }
    }

    func testCodeSpanRoundtripRetainsWhitespaceAndBackticks() throws {
        for text in [" code ", "  code  ", " ", "   ", "`code`", "a``b", " code", "code "] {
            let document = MarkdownDocument(blocks: [Block(runs: [TextRun(text, marks: [.code])])])
            let markdown = document.markdown()
            let restored = try MarkdownDocument(markdown: markdown)
            XCTAssertEqual(restored.blocks[0].text, text, markdown)
            XCTAssertEqual(restored.blocks[0].runs.first?.marks, [.code], markdown)
        }
    }

    func testMarkedCodeSpanRetainsItsWhitespaceOnReload() throws {
        let document = try MarkdownDocument(markdown: "**`  code  `**")
        let markdown = document.markdown()
        let restored = try MarkdownDocument(markdown: markdown)
        XCTAssertEqual(restored.blocks[0].runs, document.blocks[0].runs, markdown)
    }

    func testLinkImportKeepsDestinationAcrossLineBreaks() throws {
        for source in ["[first\nsecond](https://example.com)", "[first  \nsecond](https://example.com)"] {
            let document = try MarkdownDocument(markdown: source)
            XCTAssertTrue(document.blocks[0].runs.allSatisfy { $0.link == "https://example.com" }, source)
        }
    }

    func testOverlappingMarkEditsSurviveReload() throws {
        for (text, start) in [("abc", 0), ("xabcy", 1)] {
            for (first, second) in [(InlineMark.bold, InlineMark.italic), (.italic, .bold)] {
                var session = EditingSession(try MarkdownDocument(markdown: text))
                try session.apply(.formatDocument(first, NSRange(location: start, length: 2)))
                try session.apply(.formatDocument(second, NSRange(location: start + 1, length: 2)))
                let markdown = session.document.markdown()
                let restored = try MarkdownDocument(markdown: markdown)
                XCTAssertEqual(restored.blocks[0].runs, session.document.blocks[0].runs, markdown)
            }
        }
    }

    func testInsertionInsideLinkRetainsDestination() throws {
        let document = try MarkdownDocument(markdown: "[**hello**](https://example.com)")
        for command in [
            EditingCommand.replaceDocument(NSRange(location: 2, length: 0), text: "X", marks: [.bold]),
            .replace(BlockSelection(blockID: document.blocks[0].id, range: NSRange(location: 2, length: 0)), text: "X", marks: [.bold])
        ] {
            var session = EditingSession(document)
            try session.apply(command)
            XCTAssertEqual(session.document.blocks[0].runs, [TextRun("heXllo", marks: [.bold], link: "https://example.com")])
        }
    }

    func testDeletingListBoundaryRetainsInlineContentOnReload() throws {
        for source in [
            "- **first**\n- [second](https://example.com)",
            "paragraph\n\n- parent\n  - **child**\n- sibling"
        ] {
            var session = EditingSession(try MarkdownDocument(markdown: source))
            let boundary = session.document.blockRanges[0].length
            try session.apply(.replaceDocument(NSRange(location: boundary, length: 1), text: "", marks: []))
            let markdown = session.document.markdown()
            let restored = try MarkdownDocument(markdown: markdown)
            XCTAssertEqual(restored.visibleText, session.document.visibleText, markdown)
            XCTAssertEqual(restored.blocks.map(\.kind), session.document.blocks.map(\.kind), markdown)
            XCTAssertEqual(restored.blocks.flatMap(\.runs).filter { $0.link != nil },
                           session.document.blocks.flatMap(\.runs).filter { $0.link != nil }, markdown)
        }
    }
}
