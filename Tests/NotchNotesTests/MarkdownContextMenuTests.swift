import AppKit
import SwiftUI
import XCTest
@testable import MarkdownEngine

@MainActor
final class MarkdownContextMenuTests: XCTestCase {
    func testRepeatedEmphasisCommandsPreserveUnicodeSelection() {
        for bold in [true, false] {
            withEditor("앞 한글😀 뒤") { view, coordinator in
                view.setSelectedRange((view.string as NSString).range(of: "한글😀"))
                let marker = bold ? "**" : "*"
                if bold { coordinator.didMarkdownBold(nil) } else { coordinator.didMarkdownItalic(nil) }
                XCTAssertEqual(view.string, "앞 \(marker)한글😀\(marker) 뒤")
                XCTAssertEqual(selectedText(view), "한글😀")
                if bold { coordinator.didMarkdownBold(nil) } else { coordinator.didMarkdownItalic(nil) }
                XCTAssertEqual(view.string, "앞 한글😀 뒤")
                XCTAssertEqual(selectedText(view), "한글😀")
            }
        }
    }

    func testEmptyMarkersKeepExistingCaretPolicy() {
        for bold in [true, false] {
            withEditor("한글😀") { view, coordinator in
                view.setSelectedRange(NSRange(location: 4, length: 0))
                if bold { coordinator.didMarkdownBold(nil) } else { coordinator.didMarkdownItalic(nil) }
                XCTAssertEqual(view.string, bold ? "한글😀****" : "한글😀**")
                XCTAssertEqual(view.selectedRange(), NSRange(location: bold ? 6 : 5, length: 0))
            }
        }
    }

    func testHeadingAndListCommandsPreserveParagraphSeparators() {
        for newline in ["\n", "\r\n", "\r"] {
            for command in 0...2 {
                withEditor("앞" + newline + "한글😀  " + newline + "뒤") { view, coordinator in
                    view.setSelectedRange((view.string as NSString).range(of: "한글😀"))
                    let prefix: String
                    switch command {
                    case 0:
                        let item = NSMenuItem()
                        item.tag = 2
                        coordinator.didMarkdownHeading(item)
                        prefix = "## "
                    case 1:
                        coordinator.didMarkdownUnorderedList(nil)
                        prefix = "\t• "
                    default:
                        coordinator.didMarkdownOrderedList(nil)
                        prefix = "1. "
                    }
                    XCTAssertEqual(view.string, "앞" + newline + prefix + "한글😀  " + newline + "뒤")
                    XCTAssertEqual(selectedText(view), "한글😀  ")
                }
            }
        }
    }

    func testExplicitSourceCommandDoesNotBecomeInlineUserEdit() {
        withEditor("**한글😀**") { view, coordinator in
            view.setSelectedRange(NSRange(location: 2, length: 4))
            coordinator.didMarkdownBold(nil)
            XCTAssertEqual(view.string, "한글😀")
            coordinator.didMarkdownBold(nil)
            XCTAssertEqual(view.string, "**한글😀**")
            // Subsequent typing still uses the visible-text edit path.
            view.insertText("새😀", replacementRange: view.selectedRange())
            XCTAssertEqual(view.string, "**새😀**")
        }
    }

    func testWhitespaceSelectionDoesNotDuplicateSource() {
        withEditor("  ") { view, coordinator in
            coordinator.didMarkdownBold(nil)
            XCTAssertEqual(view.string, "  ****")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
        }
    }

    func testCommandPublishesRawMarkdownThroughNativeDelegate() async {
        let changed = expectation(description: "Native binding update")
        var stored = "한글😀"
        let coordinator = NativeTextViewWrapper(text: Binding(get: { stored }, set: {
            stored = $0
            changed.fulfill()
        })).makeCoordinator()
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = stored
        view.delegate = coordinator
        coordinator.textView = view
        view.setSelectedRange(NSRange(location: 0, length: 4))
        coordinator.didMarkdownBold(nil)
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(stored, "**한글😀**")
        withExtendedLifetime(coordinator) {}
    }

    private func selectedText(_ view: NSTextView) -> String {
        (view.string as NSString).substring(with: view.selectedRange())
    }

    private func withEditor(_ text: String, body: (NativeTextView, NativeTextViewCoordinator) -> Void) {
        let coordinator = NativeTextViewWrapper(text: .constant(text)).makeCoordinator()
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = text
        view.delegate = coordinator
        coordinator.textView = view
        view.setSelectedRange(NSRange(location: 0, length: text.utf16.count))
        withExtendedLifetime(coordinator) { body(view, coordinator) }
    }
}
