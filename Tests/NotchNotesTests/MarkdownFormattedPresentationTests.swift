import AppKit
import XCTest
@testable import MarkdownEngine

@MainActor
final class MarkdownFormattedPresentationTests: XCTestCase {
    private func editor(_ source: String) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        var configuration = MarkdownEditorConfiguration.default
        configuration.inlineEditingMode = .formatted
        let coordinator = NativeTextViewWrapper(text: .constant(source), configuration: configuration).makeCoordinator()
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: 400))
        layout.textContainer = container
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        view.configuration = configuration
        view.string = source
        view.delegate = coordinator
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        return (view, coordinator)
    }

    func testActiveMarkersAreClearAndHaveZeroTextKit2Advance() throws {
        for source in ["**abc**", "*abc*", "***abc***", "~~abc~~", "`~~abc~~`", "**~~abc~~**"] {
            let (view, coordinator) = editor(source)
            let tokens = MarkdownTokenizer.parseTokens(in: source)
            let markers = MarkdownInlineEditing.presentationFormats(in: tokens).flatMap(\.markerRanges)
            XCTAssertFalse(markers.isEmpty, source)
            for selection in [NSRange(location: 1, length: 0), NSRange(location: 0, length: source.utf16.count)] {
                view.setSelectedRange(selection)
                coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
                let layout = try XCTUnwrap(view.textLayoutManager)
                layout.ensureLayout(for: layout.documentRange)
                let content = try XCTUnwrap(view.textContentStorage)
                let fragment = try XCTUnwrap(layout.textLayoutFragment(for: content.documentRange.location))
                let line = try XCTUnwrap(fragment.textLineFragments.first)
                for marker in markers {
                    for index in marker.location..<NSMaxRange(marker) {
                        let color = try XCTUnwrap(view.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)
                        XCTAssertEqual(color.alphaComponent, 0, source)
                        XCTAssertEqual(line.locationForCharacter(at: index).x,
                                       line.locationForCharacter(at: index + 1).x, accuracy: 0.000001, source)
                    }
                    let start = line.locationForCharacter(at: marker.location).x
                    let end = line.locationForCharacter(at: NSMaxRange(marker)).x
                    XCTAssertEqual(start, end, accuracy: 0.000001, source)
                }
                XCTAssertEqual(view.string, source)
            }
        }
    }

    func testCopyUsesVisibleTextAndKeepsLiteralCodeOnNamedPasteboard() throws {
        let source = "**bold** ~~strike~~ `~~literal~~`"
        let (view, coordinator) = editor(source)
        let board = NSPasteboard(name: NSPasteboard.Name("NotchNotes.FormattedTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        withExtendedLifetime(coordinator) {
            view.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
            XCTAssertTrue(view.writeSelection(to: board, types: [.string, .rtf]))
            XCTAssertEqual(board.string(forType: .string), "bold strike ~~literal~~")
            XCTAssertEqual(view.string, source)
        }
        let data = try XCTUnwrap(board.data(forType: .rtf))
        XCTAssertEqual(NSAttributedString(rtf: data, documentAttributes: nil)?.string, "bold strike ~~literal~~")
    }

    func testMouseLikeEndpointsAndNavigationPreserveSource() {
        let source = "**~~abc~~**\n`~~literal~~`"
        let (view, coordinator) = editor(source)
        let tokens = MarkdownTokenizer.parseTokens(in: source)
        let markers = MarkdownInlineEditing.presentationFormats(in: tokens).flatMap(\.markerRanges)
        withExtendedLifetime(coordinator) {
            for marker in markers {
                let proposed = NSRange(location: marker.location + marker.length / 2, length: 0)
                let normalized = coordinator.textView(view, willChangeSelectionFromCharacterRange: proposed,
                                                      toCharacterRange: proposed)
                XCTAssertFalse(markers.contains { normalized.location > $0.location && normalized.location < NSMaxRange($0) })
                view.setSelectedRange(normalized)
                view.moveDown(nil)
                view.moveUpAndModifySelection(nil)
                view.moveWordForward(nil)
                for endpoint in [view.selectedRange().location, NSMaxRange(view.selectedRange())] {
                    XCTAssertFalse(markers.contains { endpoint > $0.location && endpoint < NSMaxRange($0) })
                }
                XCTAssertEqual(view.string, source)
            }
        }
    }

    func testFormattedDeletionUndoPreservesCodeDelimiters() {
        let source = "`~~abc~~`"
        let (view, coordinator) = editor(source)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.allowsUndo = true
        withExtendedLifetime(coordinator) {
            let undo = view.undoManager!
            undo.groupsByEvent = false
            view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
            undo.beginUndoGrouping()
            view.deleteBackward(nil)
            undo.endUndoGrouping()
            XCTAssertEqual(view.string, "`~~abc~`")
            undo.undo()
            XCTAssertEqual(view.string, source)
            undo.redo()
            XCTAssertEqual(view.string, "`~~abc~`")
        }
    }
}
