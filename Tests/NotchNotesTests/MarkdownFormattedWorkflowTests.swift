import AppKit
import SwiftUI
import XCTest
@testable import MarkdownEngine
@testable import NotchNotes

@MainActor
final class MarkdownFormattedWorkflowTests: XCTestCase {
    func testToolbarTypingPersistsAndReloadsAsFormattedContent() async throws {
        _ = NSApplication.shared
        let name = "FormattedWorkflow.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let archive = directory.appendingPathComponent("notes.json")
        let store = NoteStore(defaults: defaults, archiveURL: archive)
        let tabID = store.activeTabID
        let configuration = MarkdownEditorConfiguration(inlineEditingMode: .formatted)
        let coordinator = NativeTextViewWrapper(text: Binding(
            get: { store.text(for: tabID) }, set: { store.updateText($0, for: tabID) }
        )).makeCoordinator()
        coordinator.configuration = configuration
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.configuration = configuration
        view.delegate = coordinator
        coordinator.textView = view
        let state = EditorInteractionState()
        state.bind(containerView: nil, textView: view)
        state.applyMarkdownCommand(.strikethrough)
        XCTAssertEqual(view.string, "")
        view.insertText("한글😀", replacementRange: view.selectedRange())
        state.applyMarkdownCommand(.strikethrough)
        view.insertText(" plain", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, "~~한글😀~~ plain")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        store.flush()
        let restored = NoteStore(defaults: defaults, archiveURL: archive)
        XCTAssertEqual(restored.text(for: tabID), view.string)
        let reloaded = NativeTextView(frame: view.frame)
        reloaded.configuration = configuration
        reloaded.string = restored.text(for: tabID)
        let next = NativeTextViewWrapper(text: .constant(reloaded.string)).makeCoordinator()
        next.configuration = configuration
        reloaded.delegate = next
        next.textView = reloaded
        reloaded.setSelectedRange(NSRange(location: 6, length: 0))
        reloaded.deleteBackward(nil)
        XCTAssertEqual(reloaded.string, "~~한글~~ plain")
        restored.flush()
        withExtendedLifetime((coordinator, next)) {}
    }
}
