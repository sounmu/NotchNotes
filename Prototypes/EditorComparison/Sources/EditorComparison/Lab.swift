import AppKit
import SwiftUI
import WebKit
import MarkdownEngine

func argument(_ name: String, default fallback: String) -> String {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return fallback }
    return CommandLine.arguments[index + 1]
}

enum Fixture {
    static let short = """
    # 편집기 비교 · Editor comparison

    한글 조합 입력과 **굵은 글씨**, *기울임*, ~~취소선~~, `inline code`를 확인하세요.

    - [ ] 체크하고 다시 해제해 보세요
    - [x] 완료한 작업
    - 일반 목록
      - 중첩 목록

    1. Enter로 다음 항목
    2. Tab / Shift+Tab 들여쓰기

    > 같은 문서로 입력·선택·복사·Undo를 비교합니다.

    ```swift
    let message = "안녕하세요 😀"
    ```

    마지막 문장입니다. 이곳에서 입력해 보세요.
    """

    static func text(_ size: Int) -> String {
        guard size > 1000 else { return short }
        let paragraph = "\n\n한글과 English를 함께 씁니다. **서식이 있는 문장**과 평문을 선택하고 수정합니다. 목록과 체크박스도 비교합니다. 😀"
        var text = short
        while text.utf16.count < size { text += paragraph }
        return text
    }
}

@MainActor
final class Document: ObservableObject {
    @Published var id = "A"
    @Published var text: String
    var notes: [String: String]
    init(_ source: String) { text = source; notes = ["A": source, "B": "# 두 번째 노트\n\n- [ ] 별도 작업\n\n노트 전환 후 저장 내용을 확인하세요."] }
    func update(_ text: String, id: String) {
        notes[id] = text
        if self.id == id { self.text = text }
    }
}

struct NativeEditor: View {
    @ObservedObject var document: Document
    var body: some View {
        let id = document.id
        NativeTextViewWrapper(
            text: Binding(get: { document.notes[id] ?? "" }, set: { document.update($0, id: id) }),
            configuration: MarkdownEditorConfiguration(inlineEditingMode: .formatted),
            fontSize: 16, documentId: id
        )
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
final class Lab: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    let engine = argument("--engine", default: Bundle.main.object(forInfoDictionaryKey: "LabEngine") as? String ?? "crepe")
    let size = Int(argument("--size", default: "1000")) ?? 1000
    let reportPath = argument("--report", default: "")
    let automated = CommandLine.arguments.contains("--automated")
    let processStart = ProcessInfo.processInfo.systemUptime
    var loadStart = ProcessInfo.processInfo.systemUptime
    var document: Document!
    var window: NSWindow!
    var editor: NSView!
    var web: WKWebView?
    let status = NSTextField(labelWithString: "Loading…")
    var ready = false
    var firstReady = false
    var phase = "loading"
    var metrics: [String: Any] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        document = Document(Fixture.text(size))
        metrics = ["engine": engine, "utf16": document.text.utf16.count, "pid": ProcessInfo.processInfo.processIdentifier,
                   "readyDefinition": "native: layout/display flush; web: create + double requestAnimationFrame; not physical presentation"]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "NotchNotes Lab — \(engine == "native" ? "Native TextKit 2" : "Milkdown Crepe")"
        window.appearance = NSAppearance(named: .darkAqua)
        // A covered WKWebView may suspend rAF. Benchmark a visible editor,
        // and keep normal window behavior for the interactive prototype.
        if automated { window.level = .floating }
        window.isReleasedWhenClosed = false
        window.center()
        if !automated, let screen = NSScreen.main?.visibleFrame, screen.width >= 1380 {
            window.setFrameOrigin(NSPoint(x: screen.midX + (engine == "native" ? -690 : 10),
                                          y: screen.midY - window.frame.height / 2))
        }
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        window.contentView = root
        let controls = NSStackView()
        for (title, action) in [("노트 A/B", #selector(switchNote)), ("짧은 문서", #selector(shortNote)),
                                ("1만 자", #selector(mediumNote)), ("5만 자", #selector(longNote)),
                                ("MD 저장", #selector(exportMarkdown))] {
            controls.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        root.addArrangedSubview(controls)
        loadStart = ProcessInfo.processInfo.systemUptime
        if engine == "native" {
            editor = NSHostingView(rootView: NativeEditor(document: document))
        } else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(self, name: "lab")
            let web = WKWebView(frame: .zero, configuration: config)
            web.navigationDelegate = self
            web.setValue(false, forKey: "drawsBackground")
            self.web = web
            editor = web
        }
        root.addArrangedSubview(editor)
        root.addArrangedSubview(status)
        editor.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            editor.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 250)
        ])
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        installMenus()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let web {
            let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Web")!
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            Task { await nativeReady() }
        }
        writeReport()
    }

    func installMenus() {
        let menu = NSMenu()
        let app = NSMenuItem(); menu.addItem(app)
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Quit Editor Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); menu.addItem(edit); edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"),
                                   ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu?.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        if engine == "native" {
            edit.submenu?.addItem(withTitle: "Bold", action: Selector(("applyMarkdownBold:")), keyEquivalent: "b")
            edit.submenu?.addItem(withTitle: "Italic", action: Selector(("applyMarkdownItalic:")), keyEquivalent: "i")
        }
        NSApp.mainMenu = menu
    }

    func textView(in view: NSView? = nil) -> NSTextView? {
        let view = view ?? editor!
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    func nativeReady() async {
        for _ in 0..<100 {
            await pause(0.01)
            editor.layoutSubtreeIfNeeded()
            if let text = textView(), text.string == document.text {
                window.displayIfNeeded()
                CATransaction.flush()
                didBecomeReady()
                return
            }
        }
        fail("Native editor did not load the requested document")
    }

    func didBecomeReady() {
        ready = true
        let elapsed = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        status.stringValue = "\(engine) · 노트 \(document.id) · \(document.text.utf16.count) UTF-16 · 준비 \(Int(elapsed)) ms · 실험용 문서"
        if !firstReady {
            firstReady = true
            metrics["firstReadyMS"] = (ProcessInfo.processInfo.systemUptime - processStart) * 1000
            metrics["editorReadyMS"] = elapsed
            phase = automated ? "settling" : "interactive"
            if automated { Task { await benchmark() } }
        }
        writeReport()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "loaded": Task { await loadWeb() }
        case "ready":
            guard body["id"] as? String == document.id else { return }
            didBecomeReady()
        case "change":
            if let id = body["id"] as? String, let markdown = body["markdown"] as? String { document.update(markdown, id: id) }
        case "error": fail(body["message"] as? String ?? "Unknown JavaScript error")
        default: break
        }
    }

    func loadWeb() async {
        do { _ = try await web?.callAsyncJavaScript("await window.lab.load(id, markdown)",
                    arguments: ["id": document.id, "markdown": document.text], in: nil, contentWorld: .page) }
        catch { fail((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("Web content process terminated") }

    func load(_ id: String, text: String? = nil) async {
        ready = false
        loadStart = ProcessInfo.processInfo.systemUptime
        // Milkdown's change listener is debounced by 200ms. Capture the
        // outgoing document synchronously before changing its identity.
        do { document.update(try await markdown(), id: document.id) }
        catch { fail(error.localizedDescription); return }
        if let text { document.notes[id] = text }
        document.id = id
        document.text = document.notes[id] ?? ""
        if web != nil { await loadWeb() } else {
            await nativeReady()
            textView()?.undoManager?.removeAllActions()
        }
    }

    @objc func switchNote() { guard ready else { return }; ready = false; Task { await load(document.id == "A" ? "B" : "A") } }
    @objc func shortNote() { guard ready else { return }; ready = false; Task { await load("A", text: Fixture.short) } }
    @objc func mediumNote() { guard ready else { return }; ready = false; Task { await load("A", text: Fixture.text(10_000)) } }
    @objc func longNote() { guard ready else { return }; ready = false; Task { await load("A", text: Fixture.text(50_000)) } }

    func markdown() async throws -> String {
        if let web { return try await web.evaluateJavaScript("window.lab.markdown()") as? String ?? "" }
        return textView()?.string ?? document.text
    }

    @objc func exportMarkdown() {
        Task {
            do {
                let source = try await markdown()
                let panel = NSSavePanel(); panel.nameFieldStringValue = "\(engine)-comparison.md"
                if panel.runModal() == .OK, let url = panel.url { try source.write(to: url, atomically: true, encoding: .utf8) }
            } catch { fail(error.localizedDescription) }
        }
    }

    func benchmark() async {
        do {
            // External sampler measures the idle interval before automated edits.
            await pause(3)
            phase = "idle"; writeReport()
            await pause(6)
            if CommandLine.arguments.contains("--capture") { try await captureEditor() }
            phase = "typing"; writeReport()
            var edits: [Double] = []
            if let web {
                for _ in 0..<20 {
                    let elapsed = try await web.callAsyncJavaScript("return await window.lab.type('a')", arguments: [:], in: nil, contentWorld: .page)
                    edits.append(elapsed as? Double ?? -1)
                    await pause(0.05)
                }
            } else if let text = textView() {
                // Same insertion position as ProseMirror's initial text selection.
                text.setSelectedRange(NSRange(location: 2, length: 0))
                for _ in 0..<20 {
                    let start = ProcessInfo.processInfo.systemUptime
                    text.insertText("a", replacementRange: text.selectedRange())
                    await Task.yield()
                    window.displayIfNeeded(); CATransaction.flush()
                    edits.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    await pause(0.05)
                }
            }
            metrics["syntheticEditMS"] = edits
            metrics["editTimingCaveat"] = "native display flush vs web double rAF; not equivalent end-to-end keyboard latency"
            phase = "checks"; writeReport()
            let saved = try await markdown()
            await pause(0.35)
            metrics["bindingSaved"] = document.notes[document.id] == saved
            if let web {
                metrics["bridgeDiagnostics"] = try await web.evaluateJavaScript("window.lab.diagnostics()")
                if document.notes[document.id] != saved {
                    metrics["bindingFailure"] = ["stored": document.notes[document.id] ?? "", "expected": saved]
                }
            }
            let id = document.id
            // Switch again immediately after an edit, before the JS listener fires.
            if let web {
                _ = try await web.callAsyncJavaScript("return await window.lab.type('즉시전환')", arguments: [:], in: nil, contentWorld: .page)
            } else if let text = textView() {
                text.insertText("즉시전환", replacementRange: text.selectedRange())
            }
            let immediatelySaved = try await markdown()
            let otherNote = document.notes["B"]
            await load("B")
            // Let any queued callback from A arrive while B is actually active.
            await pause(0.35)
            metrics["otherNotePreserved"] = document.notes["B"] == otherNote
            await load(id)
            metrics["tabRoundTrip"] = try await markdown() == immediatelySaved
            if !reportPath.isEmpty {
                let url = URL(fileURLWithPath: reportPath).deletingPathExtension().appendingPathExtension("md")
                try saved.write(to: url, atomically: true, encoding: .utf8)
                let restored = try String(contentsOf: url, encoding: .utf8)
                await load("disk-reload", text: restored)
                metrics["diskRoundTrip"] = try await markdown() == saved
            }
            if let web {
                await load("smoke", text: Fixture.short)
                metrics["smoke"] = try await web.callAsyncJavaScript("return await window.lab.smoke()", arguments: [:], in: nil, contentWorld: .page)
            } else {
                await load("smoke", text: Fixture.short)
                if let text = textView(), let undo = text.undoManager {
                    text.setSelectedRange(NSRange(location: 2, length: 0))
                    text.breakUndoCoalescing()
                    undo.beginUndoGrouping()
                    text.insertText("테스트😀", replacementRange: text.selectedRange())
                    undo.endUndoGrouping()
                    let typed = text.string
                    undo.undo()
                    let undone = text.string
                    undo.redo()
                    metrics["smoke"] = ["unicode": typed.contains("테스트😀"), "undo": undone == Fixture.short, "redo": text.string == typed]
                }
            }
            phase = "done"; writeReport()
            NSApp.terminate(nil)
        } catch { fail((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription) }
    }

    func captureEditor() async throws {
        guard !reportPath.isEmpty else { return }
        let image: NSImage?
        if let web { image = try await web.takeSnapshot(configuration: nil) }
        else if let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) {
            editor.cacheDisplay(in: editor.bounds, to: bitmap)
            let result = NSImage(size: editor.bounds.size); result.addRepresentation(bitmap); image = result
        } else { image = nil }
        if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: reportPath).deletingPathExtension().appendingPathExtension("png"))
        }
    }

    func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func writeReport() {
        guard !reportPath.isEmpty else { return }
        metrics["phase"] = phase
        metrics["windowVisible"] = window?.occlusionState.contains(.visible) ?? false
        do {
            let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        } catch { fputs("Report error: \(error)\n", stderr) }
    }
    func fail(_ message: String) {
        phase = "error"; metrics["error"] = message
        status.stringValue = message; writeReport()
        if automated { NSApp.terminate(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Lab()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
