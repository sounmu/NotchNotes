import AppKit
import SwiftUI
import XCTest
@testable import MarkdownEngine
@testable import NotchNotes

@MainActor
final class EditorDocumentPersistenceTests: XCTestCase {
    func testWritingToolsResultKeepsOriginalBindingAfterTabSwitch() async {
        guard #available(macOS 15, *) else { return }
        var first = "original"
        var second = "other"
        let coordinator = NativeTextViewWrapper(
            text: Binding(get: { first }, set: { first = $0 }), documentId: "first"
        ).makeCoordinator()
        let view = NativeTextView(frame: .zero)
        view.string = "rewritten"
        coordinator.isWritingToolsActive = true
        coordinator.wtStartDocumentId = "first"
        coordinator.textViewWritingToolsDidEnd(view)
        coordinator.updateTextBinding(Binding(get: { second }, set: { second = $0 }))
        coordinator.documentId = "second"
        coordinator.lastSyncedText = second
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(first, "rewritten")
        XCTAssertEqual(second, "other")
        XCTAssertEqual(coordinator.lastSyncedText, "other")
    }

    func testPendingEditStaysInItsOriginalTab() async throws {
        let name = "EditorStorageAudit.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NoteStore(defaults: defaults, archiveURL: nil)
        store.updateText("first")
        let oldID = store.activeTabID
        let binding = Binding(get: { store.text(for: oldID) }, set: { store.updateText($0, for: oldID) })
        let coordinator = NativeTextViewWrapper(text: binding, documentId: oldID.uuidString).makeCoordinator()
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = store.text
        view.delegate = coordinator
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.insertText("!", replacementRange: view.selectedRange())
        store.addTab()
        let newID = store.activeTabID
        coordinator.updateTextBinding(Binding(get: { store.text(for: newID) }, set: { store.updateText($0, for: newID) }))
        coordinator.documentId = newID.uuidString
        coordinator.lastSyncedText = ""
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        withExtendedLifetime(coordinator) {
            XCTAssertEqual(store.tabs.first(where: { $0.id == oldID })?.text, "first!")
            XCTAssertEqual(store.text, "")
            XCTAssertEqual(coordinator.lastSyncedText, "")
        }
        store.flush()
    }

    func testMarkdownAndSelectionSurviveDiskReloadWithoutNormalization() throws {
        let name = "EditorPersistence.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let archive = directory.appendingPathComponent("notes.json")
        let store = NoteStore(defaults: defaults, archiveURL: archive)
        let text = "~~한글😀~~  \n\t- 항목  \n\t  다음\n\n\n"
        let originalID = store.activeTabID
        store.updateText(text)
        let selection = NSRange(location: 2, length: 4)
        store.updateSelection(for: originalID, range: selection)
        store.addTab()
        store.updateText("other")
        store.flush()
        defaults.removePersistentDomain(forName: name)
        let loaded = NoteStore(defaults: defaults, archiveURL: archive)
        XCTAssertEqual(loaded.text(for: originalID), text)
        XCTAssertEqual(loaded.selectionRange(for: originalID), selection)
        XCTAssertEqual(loaded.text, "other")
        loaded.flush()
    }

    func testLateEditToDeletedTabDoesNotModifyRemainingTab() throws {
        let name = "EditorDeletedTab.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NoteStore(defaults: defaults, archiveURL: nil)
        let deletedID = store.activeTabID
        store.addTab()
        store.updateText("keep")
        store.removeTab(deletedID)
        store.updateText("late edit", for: deletedID)
        XCTAssertEqual(store.text, "keep")
        XCTAssertEqual(store.tabs.count, 1)
        store.flush()
    }
}
