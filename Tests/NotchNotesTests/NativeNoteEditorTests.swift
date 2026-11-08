import AppKit
import XCTest
import SwiftUI
@testable import NotchNotes

@MainActor
final class NativeNoteEditorTests: XCTestCase {
    @MainActor private final class Fixture {
        let suite = "NativeNoteEditorTests.\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let store: NoteStore
        let interaction = EditorInteractionState()
        let controller: NativeNoteEditorController
        let window: NSWindow
        init(_ source: String) {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            store = NoteStore(defaults: defaults, archiveURL: directory.appendingPathComponent("notes.json"))
            store.updateText(source)
            controller = NativeNoteEditorController(store: store, interaction: interaction)
            interaction.bind(nativeEditor: controller)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = controller.container
            window.makeKeyAndOrderFront(nil)
            controller.container.layoutSubtreeIfNeeded(); controller.focus()
        }
        func close() {
            controller.flush(); window.contentView = nil; window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testSourcePreservationToolbarAndPerNoteHistory() throws {
        let f = Fixture("- [ ] first\n\n**bold**"); defer { f.close() }
        XCTAssertNil(f.interaction.crepeEditor)
        XCTAssertEqual(f.store.text, "- [ ] first\n\n**bold**")
        let first = f.store.activeTabID
        let editor = try XCTUnwrap(f.controller.editor)
        editor.select(NSRange(location: 0, length: 5))
        f.interaction.applyMarkdownCommand(.italic)
        XCTAssertTrue(f.interaction.activeInlineCommands.contains(.italic))
        let edited = f.store.text
        f.store.addTab(); let second = f.store.activeTabID
        f.controller.requestDocument()
        f.controller.editor?.textView.insertText("second", replacementRange: NSRange(location: 0, length: 0))
        f.store.selectTab(first); f.controller.requestDocument()
        XCTAssertTrue(f.controller.editor === editor)
        XCTAssertEqual(f.store.text, edited)
        f.controller.command("undo")
        XCTAssertFalse(f.store.text.contains("*first*"))
        XCTAssertEqual(f.store.text(for: second).trimmingCharacters(in: .whitespacesAndNewlines), "second")
        f.controller.flush()
        let reloaded = NoteStore(defaults: f.defaults, archiveURL: f.directory.appendingPathComponent("notes.json"))
        XCTAssertEqual(reloaded.text, f.store.text)
        XCTAssertNotNil(reloaded.tabs.first(where: { $0.id == first })?.nativeSelection)
        reloaded.flush()
    }

    func testUnsupportedMarkdownRemainsVerbatimEditableAndUndoable() throws {
        let source = "![image](file.png)\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n![[로컬.png|123]]"
        let f = Fixture(source); defer { f.close() }
        let editor = try XCTUnwrap(f.controller.editor)
        XCTAssertTrue(editor.isSourceMode)
        XCTAssertEqual(editor.textView.string, source)
        XCTAssertEqual(f.store.text, source)
        XCTAssertNotNil(f.interaction.editorNotice)
        editor.textView.insertText("prefix ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(f.store.text, "prefix " + source)
        editor.undo()
        XCTAssertEqual(f.store.text, source)
    }

    func testTabSwitchCommitsMarkedTextToOriginalNote() throws {
        let f = Fixture("before"); defer { f.close() }
        let id = f.store.activeTabID
        let editor = try XCTUnwrap(f.controller.editor)
        editor.select(NSRange(location: 6, length: 0))
        editor.textView.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        f.store.addTab(); f.controller.requestDocument()
        XCTAssertEqual(f.store.text, "")
        XCTAssertTrue(f.store.text(for: id).contains("before한"))
    }

    func testSourceToolbarInlineCommandsPreserveSourceSelectionAndHistory() throws {
        let prefix = "![[로컬.png|123]]\r\n<div data-x='raw'>😀</div>\n\n"
        let suffix = "\n\n| A | B |\n| - | - |\n| 1 | 2 |\n"
        let cases: [(MarkdownCommand, String, NSRange)] = [
            (.bold, "**한글😀**", NSRange(location: 2, length: 4)),
            (.italic, "*한글😀*", NSRange(location: 1, length: 4)),
            (.inlineCode, "`한글😀`", NSRange(location: 1, length: 4)),
            (.strikethrough, "~~한글😀~~", NSRange(location: 2, length: 4)),
            (.link, "[한글😀](url)", NSRange(location: 7, length: 3))
        ]
        for (command, replacement, relativeSelection) in cases {
            let source = prefix + "한글😀" + suffix
            let f = Fixture(source); defer { f.close() }
            let editor = try XCTUnwrap(f.controller.editor)
            XCTAssertTrue(editor.isSourceMode)
            let originalSelection = NSRange(location: prefix.utf16.count, length: 4)
            editor.select(originalSelection)

            f.interaction.applyMarkdownCommand(command)

            let expected = prefix + replacement + suffix
            let selection = NSRange(location: prefix.utf16.count + relativeSelection.location,
                                    length: relativeSelection.length)
            XCTAssertEqual(f.store.text, expected, command.id)
            XCTAssertEqual(editor.textView.string, expected, command.id)
            XCTAssertEqual(editor.textView.selectedRange(), selection, command.id)
            XCTAssertEqual(editor.session.selectedRange, selection, command.id)
            f.controller.command("undo")
            XCTAssertEqual(f.store.text, source, command.id)
            XCTAssertEqual(editor.textView.selectedRange(), originalSelection, command.id)
            f.controller.command("redo")
            XCTAssertEqual(f.store.text, expected, command.id)
            XCTAssertEqual(editor.textView.selectedRange(), selection, command.id)
        }
    }

    func testSourceToolbarBlockCommandsPreserveSurroundingBytesAndUndo() throws {
        let prefix = "![[로컬.png|123]]\r\n\n"
        let suffix = "\n<table untouched='yes'></table>\n"
        let cases: [(MarkdownCommand, String)] = [
            (.quote, "> first\n> 한글😀\n"),
            (.unorderedList, "- first\n- 한글😀\n"),
            (.orderedList, "1. first\n2. 한글😀\n"),
            (.todoList, "- [ ] first\n- [ ] 한글😀\n")
        ]
        for (command, replacement) in cases {
            let source = prefix + "first\n한글😀\n" + suffix
            let f = Fixture(source); defer { f.close() }
            let editor = try XCTUnwrap(f.controller.editor)
            XCTAssertTrue(editor.isSourceMode)
            let originalSelection = NSRange(location: prefix.utf16.count + 1, length: 9)
            editor.select(originalSelection)

            f.interaction.applyMarkdownCommand(command)

            let selection = NSRange(location: prefix.utf16.count, length: replacement.utf16.count)
            XCTAssertEqual(f.store.text, prefix + replacement + suffix, command.id)
            XCTAssertEqual(editor.textView.selectedRange(), selection, command.id)
            f.controller.command("undo")
            XCTAssertEqual(f.store.text, source, command.id)
            XCTAssertEqual(editor.textView.selectedRange(), originalSelection, command.id)
            f.controller.command("redo")
            XCTAssertEqual(f.store.text, prefix + replacement + suffix, command.id)
            XCTAssertEqual(editor.textView.selectedRange(), selection, command.id)
        }
    }

    func testSourceKeyboardBoldAndItalicPreserveUnsupportedSourceAndUndo() throws {
        let prefix = "![[로컬.png|123]]\r\n<div untouched='yes'>😀</div>\n\n"
        let suffix = "\n\n| A | B |\n| - | - |\n| 1 | 2 |\n"
        for (key, keyCode, marker) in [("b", UInt16(11), "**"), ("i", UInt16(34), "*")] {
            let source = prefix + "한글😀" + suffix
            let f = Fixture(source); defer { f.close() }
            let editor = try XCTUnwrap(f.controller.editor)
            XCTAssertTrue(editor.isSourceMode)
            XCTAssertTrue(f.window.firstResponder === editor.textView)
            let originalSelection = NSRange(location: prefix.utf16.count, length: 4)
            editor.select(originalSelection)
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: f.window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode
            ))

            XCTAssertTrue(editor.textView.performKeyEquivalent(with: event))

            let expected = prefix + marker + "한글😀" + marker + suffix
            let selection = NSRange(location: prefix.utf16.count + marker.utf16.count, length: 4)
            XCTAssertEqual(f.store.text, expected, key)
            XCTAssertEqual(editor.textView.string, expected, key)
            XCTAssertEqual(editor.textView.selectedRange(), selection, key)
            let undo = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: f.window.windowNumber, context: nil,
                characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
            ))
            XCTAssertTrue(editor.textView.performKeyEquivalent(with: undo))
            XCTAssertEqual(f.store.text, source, key)
            XCTAssertEqual(editor.textView.selectedRange(), originalSelection, key)
            f.controller.command("redo")
            XCTAssertEqual(f.store.text, expected, key)
            XCTAssertEqual(editor.textView.selectedRange(), selection, key)
        }
    }

    func testFindTargetsActiveNoteBeforeViewUpdate() throws {
        let f = Fixture("first"); defer { f.close() }
        f.store.addTab()
        f.store.updateText("second")
        f.controller.find(action: NSTextFinder.Action.showFindInterface.rawValue)
        XCTAssertEqual(f.controller.displayedID, f.store.activeTabID)
        XCTAssertEqual(f.controller.editor?.textView.string, "second")
        XCTAssertTrue(f.window.firstResponder === f.controller.editor?.textView ||
                      f.controller.editor?.scrollView.isFindBarVisible == true)
    }

    func testOriginalPanelHostsContinuousNativeEditor() async throws {
        let f = Fixture("# 오늘의 메모\n\n기존 디자인 그대로, **네이티브 편집기**로.\n\n- [ ] 한글 입력과 체크박스\n- [x] 문단 간 선택과 Undo\n\n> 작은 메모를 빠르게 기록하세요.")
        defer { f.close() }
        let panel = MarkdownEditorPanel(store: f.store, settingsStore: AppSettingsStore(defaults: f.defaults),
                                        imageStore: LocalImageStore(directory: f.directory.appendingPathComponent("Images")),
                                        editorInteractionState: f.interaction, isEditorActivated: true,
                                        size: CGSize(width: 540, height: 360))
            .background(Color(red: 0.06, green: 0.06, blue: 0.07)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: panel)
        f.window.setContentSize(NSSize(width: 540, height: 360))
        f.window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded(); f.window.displayIfNeeded()
        XCTAssertNotNil(f.interaction.nativeEditor?.editor)
        XCTAssertNil(f.interaction.crepeEditor)
        XCTAssertEqual(f.controller.editor?.textView.textContainerInset, NSSize(width: 12, height: 12))
        if let path = ProcessInfo.processInfo.environment["NOTCHNOTES_NATIVE_CAPTURE_PATH"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }
}
