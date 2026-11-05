import AppKit
import XCTest
@testable import MarkdownEngine
@testable import NotchNotes

@MainActor
final class MarkdownAppCommandTests: XCTestCase {
    private func editor(_ source: String) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let configuration = MarkdownEditorConfiguration(inlineEditingMode: .formatted)
        let coordinator = NativeTextViewWrapper(text: .constant(source), configuration: configuration).makeCoordinator()
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.configuration = configuration
        view.string = source
        view.delegate = coordinator
        coordinator.textView = view
        view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        return (view, coordinator)
    }

    func testToolbarAndMenuShareListToggleAndConversion() {
        let (view, coordinator) = editor("first\r\nsecond")
        let state = EditorInteractionState()
        state.bind(containerView: nil, textView: view)
        withExtendedLifetime(coordinator) {
            view.selectAll(nil)
            state.applyMarkdownCommand(.unorderedList)
            XCTAssertEqual(view.string, "- first\r\n- second")
            state.applyMarkdownCommand(.unorderedList)
            XCTAssertEqual(view.string, "first\r\nsecond")
            coordinator.didMarkdownOrderedList(nil)
            XCTAssertEqual(view.string, "1. first\r\n2. second")
            state.applyMarkdownCommand(.todoList)
            XCTAssertEqual(view.string, "- [ ] first\r\n- [ ] second")
        }
    }

    func testKeyboardCommandsAndToolbarReportPendingAndMixedStyles() async {
        let (view, coordinator) = editor("")
        let state = EditorInteractionState()
        state.bind(containerView: nil, textView: view)
        view.applyMarkdownBold(nil)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertTrue(state.activeInlineCommands.contains(.bold))
        view.insertText("bold", replacementRange: view.selectedRange())
        view.applyMarkdownBold(nil)
        view.insertText(" plain", replacementRange: view.selectedRange())
        view.selectAll(nil)
        state.bind(containerView: nil, textView: view)
        XCTAssertTrue(state.mixedInlineCommands.contains(.bold))
        XCTAssertFalse(state.activeInlineCommands.contains(.bold))
        XCTAssertEqual(MarkdownFormatting.selectionState(.bold, in: view), .mixed)
        withExtendedLifetime(coordinator) {}
    }

    func testNoteTitleUsesDisplayedInlineText() throws {
        let name = "TitleRegression.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NoteStore(defaults: defaults, archiveURL: nil)
        store.updateText("# **hello** ~~world~~")
        XCTAssertEqual(store.title(for: store.activeTabID), "hello world")
        store.flush()
    }
}
