import AppKit
import XCTest
@testable import MarkdownEngine

final class MarkdownLivePreviewTests: XCTestCase {
    @MainActor
    func testRestylingPreservesSelectionAndClearsPreviouslyHiddenAttributes() throws {
        let text = "~~한글😀~~"
        let view = NSTextView()
        view.string = text
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let token = try XCTUnwrap(tokens.first)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let font = NSFont.systemFont(ofSize: 13)
        for caret in [fullRange.length, token.contentRange.location, fullRange.length] {
            let selection = NSRange(location: caret, length: 0)
            view.setSelectedRange(selection)
            let active = MarkdownDetection.computeActiveTokenIndices(selectionRange: selection, tokens: tokens, in: text as NSString)
            TextStylingService.restyle(textView: view, layoutBridge: nil, paragraphCandidates: [fullRange], baseFont: font, paragraphStyle: NSMutableParagraphStyle(), caretLocation: caret, activeTokenIndices: active, wikiLinkIDProvider: { _ in nil })
            XCTAssertEqual(view.string, text)
            XCTAssertEqual(view.selectedRange(), selection)
            let markerColor = view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            if active.isEmpty {
                XCTAssertEqual(markerColor, .clear)
            } else {
                XCTAssertNotEqual(markerColor, .clear)
                XCTAssertEqual((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 13)
            }
        }
    }

    func testCompletedFormattingHidesMarkersAndRevealsThemOnReentry() throws {
        for text in ["~~한글😀~~", "**한글😀**", "*한글😀*", "***한글😀***"] {
            let tokens = MarkdownTokenizer.parseTokens(in: text)
            let token = try XCTUnwrap(tokens.first)
            let end = (text as NSString).length
            let collapsed = render(text, selection: NSRange(location: end, length: 0))
            let editing = render(text, selection: NSRange(location: token.contentRange.location, length: 0))
            let collapsedAgain = render(text, selection: NSRange(location: end, length: 0))
            for marker in token.markerRanges {
                XCTAssertEqual(collapsed.attribute(.foregroundColor, at: marker.location, effectiveRange: nil) as? NSColor, .clear, text)
                XCTAssertEqual(collapsedAgain.attribute(.foregroundColor, at: marker.location, effectiveRange: nil) as? NSColor, .clear, text)
                XCTAssertNotEqual(editing.attribute(.foregroundColor, at: marker.location, effectiveRange: nil) as? NSColor, .clear, text)
                XCTAssertEqual((editing.attribute(.font, at: marker.location, effectiveRange: nil) as? NSFont)?.pointSize, 13, text)
            }
            XCTAssertEqual(collapsed.string, text)
            XCTAssertEqual(editing.string, text)
            XCTAssertEqual(collapsed.length, end)
        }
    }

    func testSelectionRevealsAllIntersectingFormatsButNotAdjacentOnes() {
        let text = "x ~~한글😀~~ and **bold** y"
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let selection = NSRange(location: 0, length: (text as NSString).length)
        let active = MarkdownDetection.computeActiveTokenIndices(selectionRange: selection, tokens: tokens, in: text as NSString)
        XCTAssertEqual(active, Set(tokens.indices))
        let before = MarkdownDetection.computeActiveTokenIndices(selectionRange: NSRange(location: 0, length: 2), tokens: tokens, in: text as NSString)
        XCTAssertTrue(before.isEmpty)
    }

    func testStrikeAppliesOnlyToContentWhenMarkersCollapse() throws {
        let text = "~~한글😀~~"
        let token = try XCTUnwrap(MarkdownTokenizer.parseTokens(in: text).first)
        let rendered = render(text, selection: NSRange(location: (text as NSString).length, length: 0))
        XCTAssertEqual(rendered.attribute(.strikethroughStyle, at: token.contentRange.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        for marker in token.markerRanges {
            XCTAssertNil(rendered.attribute(.strikethroughStyle, at: marker.location, effectiveRange: nil))
        }
    }

    func testCodeKeepsLiteralDelimitersVisible() {
        let text = "`~~literal~~ **text**`"
        let rendered = render(text, selection: NSRange(location: (text as NSString).length, length: 0))
        for index in 1..<rendered.length - 1 {
            XCTAssertNotEqual(rendered.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor, .clear)
            XCTAssertNil(rendered.attribute(.strikethroughStyle, at: index, effectiveRange: nil))
        }
    }

    private func render(_ text: String, selection: NSRange) -> NSAttributedString {
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let active = MarkdownDetection.computeActiveTokenIndices(selectionRange: selection, tokens: tokens, in: text as NSString)
        let font = NSFont.systemFont(ofSize: 13)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let styles = MarkdownStyler.styleAttributes(text: text, fontName: font.fontName, fontSize: 13, caretLocation: selection.location, activeTokenIndices: active)
        for style in styles {
            result.addAttributes(style.attributes, range: style.range)
        }
        return result
    }
}
