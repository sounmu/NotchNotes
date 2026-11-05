import AppKit
import XCTest
@testable import MarkdownEngine
@testable import NotchNotes

/// Layout-level tests for Shift+Enter list continuations. These assert the
/// final TextKit geometry rather than mirroring the styling implementation.
@MainActor
final class MarkdownListLayoutTests: XCTestCase {
    func testFullDocumentRestyleKeepsParagraphsAfterList() {
        let text = "- first  \n  second\n\n~~last~~"
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.string = text
        TextStylingService.restyle(
            textView: view, layoutBridge: nil,
            paragraphCandidates: [NSRange(location: 0, length: (text as NSString).length)],
            baseFont: .systemFont(ofSize: 15), paragraphStyle: NSMutableParagraphStyle(),
            caretLocation: (text as NSString).length, activeTokenIndices: [], wikiLinkIDProvider: { _ in nil }
        )
        let last = (text as NSString).range(of: "last")
        XCTAssertEqual(view.textStorage?.attribute(.strikethroughStyle, at: last.location, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
    }

    func testBulletContinuationContentStartsAtMarkerContentX() {
        assertContinuationAligned("- item  \n  continued")
    }

    func testOrderedContinuationContentStartsAtMarkerContentX() {
        assertContinuationAligned("1. item  \n   continued")
    }

    func testMultiDigitOrderedContinuationContentStartsAtMarkerContentX() {
        assertContinuationAligned("10. item  \n    continued")
    }

    func testNestedTabContinuationContentStartsAtMarkerContentX() {
        assertContinuationAligned("\t- item  \n\t  continued")
        assertContinuationAligned("\t1. item  \n\t   continued")
        assertContinuationAligned("\t\t- item  \n\t\t  continued")
        assertContinuationAligned("\t\t1. item  \n\t\t   continued")
    }

    func testUncheckedTaskContinuationContentStartsAtMarkerContentX() {
        assertContinuationAligned("- [ ] todo  \n      continued")
    }

    func testCheckedTaskContinuationContentStartsAtMarkerContentX() {
        assertContinuationAligned("- [x] done  \n      continued")
    }

    func testEmptyContinuationCaretStartsAtMarkerContentX() {
        let cases = [
            "- item  \n  ",
            "1. item  \n   ",
            "10. item  \n    ",
            "\t- item  \n\t  ",
            "\t1. item  \n\t   ",
            "- [ ] todo  \n      ",
            "- [x] done  \n      "
        ]

        for text in cases {
            let layout = render(text)
            let lines = lineRanges(in: text)
            XCTAssertEqual(lines.count, 2, text)
            let markerX = layout.x(ofCharacterAt: contentStart(of: lines[0], in: text))
            let caretX = layout.caretX(at: (text as NSString).length)
            XCTAssertGreaterThan(markerX, 0, text)
            XCTAssertEqual(caretX, markerX, accuracy: 0.5, text)
        }
    }

    func testEmptyNewlineContinuationCaretUsesContentIndent() {
        // Deleting the generated indentation leaves a bare newline. The
        // paragraph style must still apply to the newline so the caret and
        // the following paragraph do not collapse back to the left edge.
        let text = "- item  \n\nnext"
        let layout = render(text)
        let lines = lineRanges(in: text)
        XCTAssertEqual(lines.count, 3, text)

        let markerX = layout.x(ofCharacterAt: contentStart(of: lines[0], in: text))
        let emptyLineCaretX = layout.caretX(at: lines[1].location)
        XCTAssertGreaterThan(markerX, 0, text)
        XCTAssertEqual(emptyLineCaretX, markerX, accuracy: 0.5, text)

        let nextParagraphX = layout.x(ofCharacterAt: lines[2].location)
        XCTAssertEqual(nextParagraphX, 0, accuracy: 0.5, text)
    }

    func testContinuationWrappedLinesUseMarkerContentIndent() {
        let text = "- item  \n  alpha beta gamma delta epsilon zeta eta theta"
        let layout = render(text, width: 150)
        let lines = lineRanges(in: text)
        XCTAssertEqual(lines.count, 2, text)

        let markerX = layout.x(ofCharacterAt: contentStart(of: lines[0], in: text))
        XCTAssertGreaterThan(markerX, 0, text)

        let continuationFragments = layout.lineFragments()
            .filter { NSIntersectionRange($0.characterRange, lines[1]).length > 0 }
            .sorted { $0.characterRange.location < $1.characterRange.location }
        XCTAssertGreaterThanOrEqual(
            continuationFragments.count,
            2,
            "the continuation line should wrap for this layout width"
        )

        for fragment in continuationFragments.dropFirst() {
            XCTAssertEqual(
                fragment.usedRect.origin.x,
                markerX,
                accuracy: 0.5,
                "wrapped continuation line should start at the item content x"
            )
        }
    }

    func testContinuationStylingDoesNotLeakIntoFollowingParagraph() {
        let text = "- item  \n  continued\n\nnext paragraph"
        let layout = render(text)
        let lines = lineRanges(in: text)
        XCTAssertEqual(lines.count, 4, text)

        let nextParagraphX = layout.x(ofCharacterAt: lines[3].location)
        XCTAssertEqual(nextParagraphX, 0, accuracy: 0.5, text)
    }

    func testLayoutPreservesLiteralHardBreakSource() {
        let text = "- item  \n  continued"
        let layout = render(text)
        XCTAssertEqual(layout.storage.string, text)
        XCTAssertTrue(layout.storage.string.contains("  \n  "))
    }

    func testRestylingMarkerLineUpdatesAllContinuationLines() {
        let text = "- [ ] todo  \n      first  \n      second"
        let nsText = text as NSString
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        textView.string = text

        let resolvedFont = NSFont(name: "SF Pro", size: 16) ?? NSFont.systemFont(ofSize: 16)
        let (baseFont, baseParagraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: resolvedFont.fontName,
            fontSize: resolvedFont.pointSize
        )
        let fullRange = NSRange(location: 0, length: nsText.length)
        textView.textStorage?.setAttributes(
            [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: baseParagraph
            ],
            range: fullRange
        )

        let caret = nsText.length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: caret, length: 0),
            tokens: tokens,
            in: nsText
        )
        let markerParagraph = nsText.paragraphRange(for: NSRange(location: 0, length: 0))
        TextStylingService.restyle(
            textView: textView,
            layoutBridge: nil,
            paragraphCandidates: [markerParagraph],
            baseFont: baseFont,
            paragraphStyle: baseParagraph,
            caretLocation: caret,
            activeTokenIndices: active,
            wikiLinkIDProvider: { _ in nil }
        )

        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            return XCTFail("TextKit 1 layout expected")
        }
        layoutManager.ensureLayout(for: container)

        let lines = lineRanges(in: text)
        XCTAssertEqual(lines.count, 3, text)
        let markerX = x(
            at: contentStart(of: lines[0], in: text),
            layoutManager: layoutManager,
            container: container
        )
        XCTAssertGreaterThan(markerX, 0, text)
        for line in lines.dropFirst() {
            XCTAssertEqual(
                x(
                    at: contentStart(of: line, in: text),
                    layoutManager: layoutManager,
                    container: container
                ),
                markerX,
                accuracy: 0.5,
                text
            )
        }
    }

    func testFencedCodeKeepsLiteralIndentationForListLikeLines() {
        let text = "```\n- item  \n  continuation\n```"
        let layout = render(text)
        let nsText = text as NSString
        let itemLocation = nsText.range(of: "- item").location
        let indentLocation = nsText.range(of: "  continuation").location
        let continuationLocation = nsText.range(of: "continuation").location
        let itemX = layout.x(ofCharacterAt: itemLocation)
        let continuationX = layout.x(ofCharacterAt: continuationLocation)
        let indentFont = layout.storage.attribute(
            .font,
            at: indentLocation,
            effectiveRange: nil
        ) as? NSFont
        let literalIndent = ("  " as NSString).size(
            withAttributes: [.font: indentFont ?? layout.font]
        ).width
        XCTAssertEqual(
            continuationX - itemX,
            literalIndent,
            accuracy: 0.5,
            "fenced code must keep its literal indentation"
        )
    }

    // MARK: - Helpers

    private func assertContinuationAligned(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let layout = render(text)
        let lines = lineRanges(in: text)
        XCTAssertEqual(lines.count, 2, text, file: file, line: line)

        let markerX = layout.x(ofCharacterAt: contentStart(of: lines[0], in: text))
        let continuationX = layout.x(ofCharacterAt: contentStart(of: lines[1], in: text))
        XCTAssertGreaterThan(markerX, 0, text, file: file, line: line)
        XCTAssertEqual(continuationX, markerX, accuracy: 0.5, text, file: file, line: line)
    }

    private func lineRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        var result: [NSRange] = []
        var location = 0
        while location < nsText.length {
            let range = nsText.lineRange(for: NSRange(location: location, length: 0))
            result.append(range)
            let next = NSMaxRange(range)
            if next <= location { break }
            location = next
        }
        return result
    }

    private func x(
        at index: Int,
        layoutManager: NSLayoutManager,
        container: NSTextContainer
    ) -> CGFloat {
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: index, length: 1),
            actualCharacterRange: nil
        )
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: container).origin.x
    }

    private func contentStart(of lineRange: NSRange, in text: String) -> Int {
        let line = (text as NSString).substring(with: lineRange)
        if let context = MarkdownLists.listContext(for: line) {
            return lineRange.location + context.prefixLength
        }
        return lineRange.location + MarkdownLists.leadingWhitespace(in: line).utf16.count
    }

    private func render(
        _ text: String,
        caret: Int? = nil,
        width: CGFloat = 600
    ) -> RenderedLayout {
        let resolvedFont = NSFont(name: "SF Pro", size: 16) ?? NSFont.systemFont(ofSize: 16)
        let (baseFont, baseParagraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: resolvedFont.fontName,
            fontSize: resolvedFont.pointSize
        )
        let caretLocation = caret ?? (text as NSString).length
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: caretLocation, length: 0),
            tokens: tokens,
            in: text as NSString
        )
        let styles = MarkdownStyler.styleAttributes(
            text: text,
            fontName: baseFont.fontName,
            fontSize: baseFont.pointSize,
            caretLocation: caretLocation,
            activeTokenIndices: active
        )

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: baseParagraph
            ]
        )
        for style in styles {
            attributed.addAttributes(style.attributes, range: style.range)
        }

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: 2_000))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        return RenderedLayout(
            font: baseFont,
            storage: storage,
            layoutManager: layoutManager,
            container: container
        )
    }
}

private struct RenderedLayout {
    let font: NSFont
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let container: NSTextContainer

    func x(ofCharacterAt index: Int) -> CGFloat {
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: index, length: 1),
            actualCharacterRange: nil
        )
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: container).origin.x
    }

    func caretX(at index: Int) -> CGFloat {
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: index)
        return layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 0),
            in: container
        ).origin.x
    }

    func lineFragments() -> [(characterRange: NSRange, usedRect: CGRect)] {
        var result: [(characterRange: NSRange, usedRect: CGRect)] = []
        var glyphIndex = 0
        let glyphCount = layoutManager.numberOfGlyphs
        while glyphIndex < glyphCount {
            var glyphRange = NSRange(location: 0, length: 0)
            let usedRect = layoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &glyphRange
            )
            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            result.append((characterRange, usedRect))
            let next = NSMaxRange(glyphRange)
            if next <= glyphIndex { break }
            glyphIndex = next
        }
        return result
    }
}

// MARK: - TextKit 2 (NativeTextView) Layout

/// The shipping editor is a `NativeTextView`, which AppKit backs with TextKit 2.
/// These tests exercise the same `NativeTextView` + `NSTextLayoutManager` stack
/// the app uses, so a TextKit 1 fallback would be caught here.
///
/// TextKit 2 splits kern around glyphs and ignores trailing kern at an empty
/// continuation's caret. These cases guard the paragraph-offset solution.
@MainActor
final class MarkdownListTextKit2LayoutTests: XCTestCase {
    func testNativeTextViewIsBackedByTextKit2() {
        let layout = renderTextKit2("- 항목")
        XCTAssertNotNil(layout.textView.textLayoutManager)
        XCTAssertNotNil(layout.textView.textContentStorage)
        XCTAssertTrue(
            layout.textView.textLayoutManager?.textContentManager === layout.textView.textContentStorage,
            "NativeTextView must lay out through its NSTextContentStorage"
        )
    }

    func testBulletKoreanContinuationAligns() {
        assertContinuationAligned("- 항목  \n  계속")
    }

    func testEmptyMarkerHardBreakDoesNotCountBreakSpacesAsIndentation() {
        assertContinuationAligned("-   \n  계속")
        assertContinuationAligned("1.   \n   계속")
        assertContinuationAligned("\t- [ ]   \n\t      계속")
    }

    func testOrderedKoreanContinuationAligns() {
        assertContinuationAligned("1. 항목  \n   계속")
        assertContinuationAligned("10. 항목  \n    계속")
    }

    func testTaskKoreanContinuationAligns() {
        assertContinuationAligned("- [ ] 할 일  \n      계속")
        assertContinuationAligned("- [x] 완료  \n      계속")
    }

    func testNestedTabKoreanContinuationAligns() {
        assertContinuationAligned("\t- 항목  \n\t  계속")
        assertContinuationAligned("\t1. 항목  \n\t   계속")
        assertContinuationAligned("\t\t- 항목  \n\t\t  계속")
        assertContinuationAligned("\t\t10. 항목  \n\t\t    계속")
    }

    func testEmptyContinuationCaretAligns() {
        let cases = [
            "- 항목  \n  ",
            "1. 항목  \n   ",
            "10. 항목  \n    ",
            "\t- 항목  \n\t  ",
            "\t1. 항목  \n\t   ",
            "- [ ] 할 일  \n      ",
            "- [x] 완료  \n      "
        ]

        for text in cases {
            let layout = renderTextKit2(text)
            let lines = lineRanges(in: text)
            XCTAssertEqual(lines.count, 2, text)

            let markerX = layout.x(ofCharacterAt: contentStart(of: lines[0], in: text))
            let caretX = layout.caretX(at: (text as NSString).length)
            XCTAssertNotNil(markerX, text)
            XCTAssertNotNil(caretX, text)
            XCTAssertGreaterThan(markerX ?? 0, 0, text)
            XCTAssertEqual(caretX ?? .nan, markerX ?? .nan, accuracy: 0.5, text)
        }
    }

    func testWrappedContinuationLinesUseContentIndent() {
        let text = "- 항목  \n  알파 베타 감마 델타 엡실론 제타 에타"
        let layout = renderTextKit2(text, width: 120)
        let lines = lineRanges(in: text)
        XCTAssertEqual(lines.count, 2, text)

        let markerX = layout.x(ofCharacterAt: contentStart(of: lines[0], in: text))
        XCTAssertNotNil(markerX, text)
        XCTAssertGreaterThan(markerX ?? 0, 0, text)

        let continuationFragments = layout.fragments().filter {
            NSIntersectionRange(layout.documentRange(of: $0), lines[1]).length > 0
        }
        XCTAssertEqual(continuationFragments.count, 1, "expected one paragraph fragment for the continuation")
        guard let fragment = continuationFragments.first else { return }
        XCTAssertGreaterThanOrEqual(
            fragment.textLineFragments.count,
            2,
            "the continuation line should wrap for this layout width"
        )

        let lineX = layout.firstCharacterX(in: fragment)
        for x in lineX.dropFirst() {
            XCTAssertEqual(
                x,
                markerX ?? .nan,
                accuracy: 0.5,
                "wrapped continuation line should start at the item content x"
            )
        }
    }

    func testContinuationDoesNotLeakIntoFollowingParagraph() {
        let text = "- 항목  \n  계속\n\n다음 문단"
        let layout = renderTextKit2(text)
        let lines = lineRanges(in: text)
        XCTAssertEqual(lines.count, 4, text)

        let nextParagraphX = layout.x(ofCharacterAt: lines[3].location)
        XCTAssertNotNil(nextParagraphX, text)
        XCTAssertEqual(nextParagraphX ?? .nan, 0, accuracy: 0.5, text)
    }

    func testTextKit2PreservesLiteralHardBreakSource() {
        let text = "- 항목  \n  계속"
        let layout = renderTextKit2(text)
        XCTAssertEqual(layout.textView.string, text)
        XCTAssertTrue(layout.textView.string.contains("  \n  "))
    }

    // MARK: - Helpers

    private func assertContinuationAligned(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let layout = renderTextKit2(text)
        let lines = lineRanges(in: text)
        XCTAssertEqual(lines.count, 2, text, file: file, line: line)

        let markerX = layout.x(ofCharacterAt: contentStart(of: lines[0], in: text))
        let continuationX = layout.x(ofCharacterAt: contentStart(of: lines[1], in: text))
        XCTAssertNotNil(markerX, text, file: file, line: line)
        XCTAssertNotNil(continuationX, text, file: file, line: line)
        XCTAssertGreaterThan(markerX ?? 0, 0, text, file: file, line: line)
        XCTAssertEqual(
            continuationX ?? .nan,
            markerX ?? .nan,
            accuracy: 0.5,
            text,
            file: file,
            line: line
        )
    }

    private func lineRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        var result: [NSRange] = []
        var location = 0
        while location < nsText.length {
            let range = nsText.lineRange(for: NSRange(location: location, length: 0))
            result.append(range)
            let next = NSMaxRange(range)
            if next <= location { break }
            location = next
        }
        return result
    }

    private func contentStart(of lineRange: NSRange, in text: String) -> Int {
        let line = (text as NSString).substring(with: lineRange)
        if let context = MarkdownLists.listContext(for: line) {
            return lineRange.location + context.prefixLength
        }
        return lineRange.location + MarkdownLists.leadingWhitespace(in: line).utf16.count
    }

    private func renderTextKit2(
        _ text: String,
        caret: Int? = nil,
        width: CGFloat = 600
    ) -> RenderedTextKit2Layout {
        // Mirrors NativeTextViewWrapper.makeNSView: init(frame:) lets AppKit
        // create the TextKit 2 stack, and all layout queries go through
        // textLayoutManager rather than layoutManager (which would force a
        // TextKit 1 fallback).
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        XCTAssertNotNil(textView.textLayoutManager, "NativeTextView must use TextKit 2")
        XCTAssertNotNil(textView.textContentStorage, "NativeTextView must expose NSTextContentStorage")
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.isRichText = true
        textView.string = text

        let resolvedFont = NSFont(name: "SF Pro", size: 16) ?? NSFont.systemFont(ofSize: 16)
        let (baseFont, baseParagraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: resolvedFont.fontName,
            fontSize: resolvedFont.pointSize
        )
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let caretLocation = caret ?? nsText.length
        textView.setSelectedRange(NSRange(location: caretLocation, length: 0))

        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: caretLocation, length: 0),
            tokens: tokens,
            in: nsText
        )
        let styles = MarkdownStyler.styleAttributes(
            text: text,
            fontName: baseFont.fontName,
            fontSize: baseFont.pointSize,
            caretLocation: caretLocation,
            activeTokenIndices: active,
            precomputedTokens: tokens
        )

        guard let storage = textView.textStorage else {
            XCTFail("NativeTextView must expose a text storage")
            return RenderedTextKit2Layout(
                textView: textView,
                textLayoutManager: textView.textLayoutManager!,
                textContentStorage: textView.textContentStorage!
            )
        }
        storage.beginEditing()
        storage.setAttributes(
            [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: baseParagraph
            ],
            range: fullRange
        )
        for style in styles {
            storage.addAttributes(style.attributes, range: style.range)
        }
        storage.endEditing()

        guard let textLayoutManager = textView.textLayoutManager,
              let textContentStorage = textView.textContentStorage else {
            XCTFail("NativeTextView must use TextKit 2")
            fatalError("TextKit 2 stack unavailable")
        }
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)

        return RenderedTextKit2Layout(
            textView: textView,
            textLayoutManager: textLayoutManager,
            textContentStorage: textContentStorage
        )
    }
}

private struct RenderedTextKit2Layout {
    let textView: NativeTextView
    let textLayoutManager: NSTextLayoutManager
    let textContentStorage: NSTextContentStorage

    func fragments() -> [NSTextLayoutFragment] {
        var result: [NSTextLayoutFragment] = []
        textLayoutManager.enumerateTextLayoutFragments(
            from: textLayoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            result.append(fragment)
            return true
        }
        return result
    }

    /// Glyph x of `index` in text-container coordinates.
    func x(ofCharacterAt index: Int) -> CGFloat? {
        guard let location = documentLocation(at: index),
              let fragment = textLayoutManager.textLayoutFragment(for: location) else {
            return nil
        }
        guard let offset = offsetInFragment(fragment, for: location),
              let length = fragmentLength(fragment) else { return nil }
        let clamped = min(max(offset, 0), length)

        for lineFragment in fragment.textLineFragments {
            let lineRange = lineFragment.characterRange
            if clamped >= lineRange.location && clamped < lineRange.location + lineRange.length {
                return x(in: fragment, lineFragment: lineFragment, localIndex: clamped - lineRange.location)
            }
        }
        return nil
    }

    /// Caret x of `index`, including the trailing edge of a line's whitespace.
    func caretX(at index: Int) -> CGFloat? {
        guard let location = documentLocation(at: index) else { return nil }
        var fragment = textLayoutManager.textLayoutFragment(for: location)
        if fragment == nil, index > 0, let previous = documentLocation(at: index - 1) {
            fragment = textLayoutManager.textLayoutFragment(for: previous)
        }
        guard let fragment,
              let offset = offsetInFragment(fragment, for: location),
              let length = fragmentLength(fragment) else { return nil }
        let clamped = min(max(offset, 0), length)

        for lineFragment in fragment.textLineFragments {
            let lineRange = lineFragment.characterRange
            if clamped >= lineRange.location && clamped <= lineRange.location + lineRange.length {
                return x(in: fragment, lineFragment: lineFragment, localIndex: clamped - lineRange.location)
            }
        }
        return nil
    }

    /// x of the first character on each visual line of `fragment`.
    func firstCharacterX(in fragment: NSTextLayoutFragment) -> [CGFloat] {
        fragment.textLineFragments.map { lineFragment in
            let localIndex = lineFragment.characterRange.location
            return x(in: fragment, lineFragment: lineFragment, localIndex: localIndex)
        }
    }

    /// Document-level character range covered by `fragment`.
    func documentRange(of fragment: NSTextLayoutFragment) -> NSRange {
        let start = textContentStorage.offset(
            from: textContentStorage.documentRange.location,
            to: fragment.rangeInElement.location
        )
        let end = textContentStorage.offset(
            from: textContentStorage.documentRange.location,
            to: fragment.rangeInElement.endLocation
        )
        guard start != NSNotFound, end != NSNotFound, end >= start else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: start, length: end - start)
    }

    private func documentLocation(at index: Int) -> NSTextLocation? {
        textContentStorage.location(
            textContentStorage.documentRange.location,
            offsetBy: index
        )
    }

    private func offsetInFragment(_ fragment: NSTextLayoutFragment, for location: NSTextLocation) -> Int? {
        let offset = textContentStorage.offset(
            from: fragment.rangeInElement.location,
            to: location
        )
        return offset == NSNotFound ? nil : offset
    }

    private func fragmentLength(_ fragment: NSTextLayoutFragment) -> Int? {
        let length = textContentStorage.offset(
            from: fragment.rangeInElement.location,
            to: fragment.rangeInElement.endLocation
        )
        return length == NSNotFound ? nil : length
    }

    private func x(
        in fragment: NSTextLayoutFragment,
        lineFragment: NSTextLineFragment,
        localIndex: Int
    ) -> CGFloat {
        let point = lineFragment.locationForCharacter(at: localIndex)
        return fragment.layoutFragmentFrame.origin.x
            + lineFragment.typographicBounds.origin.x
            + point.x
    }
}
