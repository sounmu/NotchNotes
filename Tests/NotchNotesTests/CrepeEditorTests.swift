import AppKit
import WebKit
import XCTest
@testable import NotchNotes

@MainActor
final class CrepeEditorTests: XCTestCase {
    @MainActor final class Fixture {
        let defaults: UserDefaults
        let suite = "CrepeTests.\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CrepeTests.\(UUID())")
        let store: NoteStore
        let interaction = EditorInteractionState()
        let editor: CrepeEditorController
        let window: NSWindow
        init(_ source: String) {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            store = NoteStore(defaults: defaults, archiveURL: directory.appendingPathComponent("notes.json"))
            store.updateText(source)
            editor = CrepeEditorController(store: store, images: LocalImageStore(directory: directory.appendingPathComponent("Images")), interaction: interaction)
            interaction.bind(webEditor: editor)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor.webView
            window.orderFront(nil)
        }
        func close() {
            editor.webView.stopLoading()
            window.contentView = nil; window.close()
            store.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        func js(_ code: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
            try await editor.webView.callAsyncJavaScript(code, arguments: arguments, in: nil, contentWorld: .page)
        }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<1500 {
                if let error = editor.error { throw NSError(domain: error, code: 1) }
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(domain: "Editor timed out", code: 2)
        }
        func ready() async throws { try await wait { editor.isReady } }
        func insert(_ value: String) async throws {
            _ = try await js("return window.notchEditor.testAction('insert', value)", ["value": value])
        }
    }

    func testOpeningPreservesOriginalSourceAndCheckboxDOMTogglesRepeatedly() async throws {
        let source = "- [ ] 할 일\n\n**bold**"
        let f = Fixture(source); defer { f.close() }
        try await f.ready()
        XCTAssertEqual(f.store.text, source, "Opening a note must not normalize its stored source")
        for checked in [true, false, true, false] {
            _ = try await f.js("return window.notchEditor.testAction('checkbox')")
            await f.editor.flush()
            XCTAssertTrue(f.store.text.contains(checked ? "[x] 할 일" : "[ ] 할 일"))
        }
    }

    func testToolbarPendingMarksMixedStateAndUndoRedo() async throws {
        let f = Fixture(""); defer { f.close() }
        try await f.ready()
        f.interaction.applyMarkdownCommand(.bold)
        try await f.wait { f.interaction.activeInlineCommands.contains(.bold) }
        try await f.insert("한글😀")
        await f.editor.flush()
        XCTAssertTrue(f.store.text.contains("**한글😀**"))
        _ = try await f.js("return window.notchEditor.command('undo')")
        await f.editor.flush()
        XCTAssertEqual(f.store.text.trimmingCharacters(in: .whitespacesAndNewlines), "")
        _ = try await f.js("return window.notchEditor.command('redo')")
        await f.editor.flush()
        XCTAssertTrue(f.store.text.contains("**한글😀**"))
        _ = try await f.js("window.notchEditor.command('bold'); return window.notchEditor.testAction('insert', ' plain')")
        _ = try await f.js("return window.notchEditor.testAction('select', {anchor: 1, head: 11})")
        await f.editor.flush()
        XCTAssertTrue(f.interaction.mixedInlineCommands.contains(.bold))
    }

    func testImmediateAndRapidTabSwitchesKeepLatestTextAndHistoryWithOriginalNote() async throws {
        let f = Fixture("first"); defer { f.close() }
        try await f.ready()
        let first = f.store.activeTabID
        try await f.insert("입력😀")
        f.store.addTab(); let second = f.store.activeTabID
        f.editor.requestDocument(); try await f.ready()
        try await f.insert("second")
        f.store.selectTab(first); f.editor.requestDocument()
        f.store.selectTab(second); f.editor.requestDocument()
        try await f.ready()
        await f.editor.flush()
        XCTAssertTrue(f.store.text(for: first).contains("입력😀first"))
        XCTAssertEqual(f.store.text(for: second).trimmingCharacters(in: .whitespacesAndNewlines), "second")
        f.store.selectTab(first); f.editor.requestDocument(); try await f.ready()
        _ = try await f.js("return window.notchEditor.command('undo')")
        await f.editor.flush()
        XCTAssertEqual(f.store.text.trimmingCharacters(in: .whitespacesAndNewlines), "first")
        XCTAssertEqual(f.store.text(for: second).trimmingCharacters(in: .whitespacesAndNewlines), "second")
    }

    func testFlushImmediatelyAfterEditSurvivesDiskReload() async throws {
        let f = Fixture("before"); defer { f.close() }
        try await f.ready()
        try await f.insert("저장 ")
        await f.editor.flush()
        f.defaults.removePersistentDomain(forName: f.suite)
        let reloaded = NoteStore(defaults: f.defaults, archiveURL: f.directory.appendingPathComponent("notes.json"))
        XCTAssertEqual(reloaded.text, f.store.text)
        XCTAssertTrue(reloaded.text.contains("저장 before"))
        XCTAssertNotNil(reloaded.crepeSelection(for: reloaded.activeTabID))
        reloaded.flush()
    }

    func testQueuedReturnUsesOutgoingSnapshotAndFlushWaitsForSwitch() async throws {
        let f = Fixture("first"); defer { f.close() }
        try await f.ready()
        let first = f.store.activeTabID
        // Delay the next switch, then edit the outgoing note in that same JS
        // turn. Swift has already queued the return with the earlier source.
        _ = try await f.js("""
            const original = window.notchEditor.setDocument;
            window.notchEditor.setDocument = async next => {
                window.notchEditor.setDocument = original;
                await new Promise(resolve => { window.releaseSwitch = resolve; });
                window.notchEditor.testAction('insert', 'latest ');
                return original(next);
            };
            """)
        f.store.addTab(); let second = f.store.activeTabID
        f.editor.requestDocument()
        var waiting = false
        for _ in 0..<100 {
            waiting = try await f.js("return typeof window.releaseSwitch === 'function'") as? Bool ?? false
            if waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(waiting)
        f.store.selectTab(first); f.editor.requestDocument()
        _ = try await f.js("window.releaseSwitch()")
        await f.editor.flush()
        XCTAssertTrue(f.editor.isReady)
        XCTAssertTrue(f.store.text(for: first).contains("latest first"))
        XCTAssertEqual(f.store.text(for: second), "")
        let rendered = try await f.js("return document.querySelector('.ProseMirror').textContent") as? String
        XCTAssertEqual(rendered, "latest first")
    }

    func testExternalReplacementResetsHistoryAndHiddenEditorCanFlush() async throws {
        let f = Fixture("original"); defer { f.close() }
        try await f.ready()
        try await f.insert("edit ")
        await f.editor.flush()
        f.store.updateText("replacement")
        f.editor.requestDocument()
        await f.editor.flush()
        _ = try await f.js("return window.notchEditor.command('undo')")
        f.window.orderOut(nil)
        await f.editor.flush()
        XCTAssertEqual(f.store.text, "replacement")
        XCTAssertTrue(f.editor.isReady)
    }

    func testListCommandsConvertAndToggleWithoutNestingSyntax() async throws {
        let f = Fixture("item"); defer { f.close() }
        try await f.ready()
        for (command, expected) in [("todoList", "* [ ] item"), ("orderedList", "1. item"),
                                    ("unorderedList", "* item"), ("unorderedList", "item")] {
            let handled = try await f.js("return window.notchEditor.command(value)", ["value": command]) as? Bool
            XCTAssertEqual(handled, true)
            await f.editor.flush()
            XCTAssertEqual(f.store.text.trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
    }

    func testImageUploadStoredEmbedRenderingAndRoundTrip() async throws {
        let f = Fixture("image"); defer { f.close() }
        try await f.ready()
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = try await f.js("return await window.webkit.messageHandlers.imageUpload.postMessage({data, name: '한글.png'})", ["data": data.base64EncodedString()]) as? String
        XCTAssertTrue(try XCTUnwrap(url).hasPrefix("notchnotes-image://asset/"))
        _ = try await f.js("return window.notchEditor.command('insertImage', value)", ["value": try XCTUnwrap(url)])
        await f.editor.flush()
        XCTAssertTrue(f.store.text.contains("![[한글.png|"))
        var rendered = false
        for _ in 0..<100 {
            rendered = try await f.js("return !!document.querySelector('img')?.naturalWidth") as? Bool ?? false
            if rendered { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(rendered, "The real WKURLSchemeHandler must serve the stored image")
    }

    func testWikiNavigationUsesStableIDAndKeepsBundledPageLoaded() async throws {
        let f = Fixture("first"); defer { f.close() }
        try await f.ready()
        let first = f.store.activeTabID
        f.store.addTab(); let second = f.store.activeTabID
        f.store.updateText("renamed destination")
        f.store.selectTab(first)
        _ = try await f.js("""
            const link = document.createElement('a');
            link.href = 'notchnotes-wiki://note/' + encodeURIComponent('old title|' + id);
            document.body.append(link); link.click(); link.remove();
            """, ["id": second.uuidString.lowercased()])
        try await f.wait { f.store.activeTabID == second }
        f.editor.requestDocument(); try await f.ready()
        XCTAssertTrue(f.editor.webView.url?.isFileURL == true)
        XCTAssertEqual(f.store.text, "renamed destination")
    }
}
