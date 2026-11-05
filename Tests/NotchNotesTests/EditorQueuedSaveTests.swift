import AppKit
import SwiftUI
import XCTest
@testable import MarkdownEngine
@testable import NotchNotes

@MainActor
final class EditorQueuedSaveTests: XCTestCase {
    private func editor(_ source: String, binding: Binding<String>) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewWrapper(text: binding).makeCoordinator()
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = source
        view.delegate = coordinator
        coordinator.textView = view
        view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        return (view, coordinator)
    }

    func testRevertedEditIsTheSnapshotPersistedToDisk() async throws {
        let name = "EditorRegression.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("notes.json")
        let store = NoteStore(defaults: defaults, archiveURL: archive)
        store.updateText("original")
        let id = store.activeTabID
        let (view, coordinator) = editor(store.text, binding: Binding(get: { store.text(for: id) }, set: { store.updateText($0, for: id) }))
        view.insertText("!", replacementRange: view.selectedRange())
        view.deleteBackward(nil)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        store.flush()
        defaults.removePersistentDomain(forName: name)
        let restored = NoteStore(defaults: defaults, archiveURL: archive)
        XCTAssertEqual(view.string, "original")
        XCTAssertEqual(restored.text, view.string)
        restored.flush()
        withExtendedLifetime(coordinator) {}
    }

    func testUndoBeforeQueuedBindingDeliveryPersistsFinalState() async {
        var stored = ""
        let (view, coordinator) = editor("", binding: Binding(get: { stored }, set: { stored = $0 }))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.allowsUndo = true
        let undo = view.undoManager!
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        view.insertText("a", replacementRange: view.selectedRange())
        undo.endUndoGrouping()
        undo.undo()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(stored, "")
        window.contentView = nil
        withExtendedLifetime(coordinator) {}
    }
}
