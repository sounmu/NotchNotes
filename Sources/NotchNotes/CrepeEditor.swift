import AppKit
import SwiftUI
import WebKit

@MainActor
final class CrepeEditorController: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKURLSchemeHandler {
    struct Request {
        let id: UUID
        let source: String
        let generation = UUID()
    }
    let store: NoteStore
    let images: LocalImageStore
    weak var interaction: EditorInteractionState?
    private(set) var webView: CrepeWebView!
    private(set) var displayedID: UUID?
    private(set) var error: String?
    private var loaded = false
    private var loading = false
    private var loadTask: Task<Void, Never>?
    private var pageGeneration = UUID()
    private var pending: Request?
    private var inFlight: Request?
    private var sources: [UUID: String] = [:]
    private var bridge = CrepeBridgeState()
    private var wantsFocus = false
    var isReady: Bool { loaded && !loading && pending == nil && displayedID == store.activeTabID }
    private var searchText = ""

    func find(action: Int) {
        if action == NSTextFinder.Action.showFindInterface.rawValue || searchText.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Find in note"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = searchText; alert.accessoryView = field
            alert.addButton(withTitle: "Find"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            searchText = field.stringValue
        }
        guard !searchText.isEmpty else { return }
        let options = WKFindConfiguration()
        options.backwards = action == NSTextFinder.Action.previousMatch.rawValue
        options.wraps = true
        webView.find(searchText, configuration: options) { _ in }
    }

    init(store: NoteStore, images: LocalImageStore, interaction: EditorInteractionState) {
        self.store = store; self.images = images; self.interaction = interaction
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let proxy = CrepeMessageProxy(self)
        configuration.userContentController.add(proxy, name: "editor")
        configuration.userContentController.addScriptMessageHandler(proxy, contentWorld: .page, name: "imageUpload")
        configuration.setURLSchemeHandler(proxy, forURLScheme: "notchnotes-image")
        webView = CrepeWebView(frame: .zero, configuration: configuration)
        webView.controller = self
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.isInspectable = false
        requestDocument()
        loadPage()
    }

    private func loadPage() {
        guard let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Crepe") else {
            report("The bundled editor is missing. Rebuild WebEditor assets."); return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func requestDocument() {
        let id = store.activeTabID, source = store.text
        let ids = Set(store.tabs.map(\.id))
        bridge.forget(except: ids)
        sources = sources.filter { ids.contains($0.key) }
        if loaded { Task { _ = try? await invoke("forget", arguments: ["value": ids.map(\.uuidString)]) } }
        if pending?.id == id, pending?.source == source { return }
        if inFlight?.id == id, inFlight?.source == source { pending = nil; return }
        if displayedID == id, sources[id] == source, pending == nil, !loading { return }
        pending = Request(id: id, source: source)
        startLoading()
    }

    private func startLoading() {
        guard loaded, !loading else { return }
        loading = true
        let page = pageGeneration
        loadTask = Task {
            defer {
                if pageGeneration == page { loading = false; inFlight = nil; loadTask = nil }
            }
            while let queued = pending {
                // The preceding outgoing snapshot may have advanced this note
                // since it was queued during a rapid A → B → A switch.
                guard store.tabs.contains(where: { $0.id == queued.id }) else { pending = nil; continue }
                let request = Request(id: queued.id, source: store.text(for: queued.id))
                pending = nil; inFlight = request
                bridge.begin(request.id, generation: request.generation)
                var payload: [String: Any] = ["id": request.id.uuidString, "generation": request.generation.uuidString,
                                              "markdown": request.source]
                if let selection = store.crepeSelection(for: request.id) {
                    payload["selection"] = ["anchor": selection.anchor, "head": selection.head]
                }
                do {
                    let result = try await invoke("setDocument", arguments: ["value": payload]) as? [String: Any]
                    guard pageGeneration == page else { return }
                    if let outgoing = result?["outgoing"] as? [String: Any] { receive(outgoing) }
                    displayedID = request.id
                    if let current = result?["current"] as? [String: Any] { receive(current) }
                    error = nil; interaction?.editorError = nil
                    inFlight = nil
                    if wantsFocus && request.id == store.activeTabID { focus() }
                } catch {
                    guard pageGeneration == page else { return }
                    report(error.localizedDescription); pending = nil
                }
            }
        }
    }

    func invoke(_ method: String, arguments: [String: Any] = [:]) async throws -> Any? {
        // Method names are internal constants; document text only travels as arguments.
        try await webView.callAsyncJavaScript("return await window.notchEditor.\(method)(value)",
            arguments: ["value": arguments["value"] ?? NSNull()], in: nil, contentWorld: .page)
    }

    func flush() async {
        await loadTask?.value
        guard loaded, displayedID != nil else { return }
        do { if let result = try await invoke("flush") as? [String: Any] { receive(result) } }
        catch { report(error.localizedDescription) }
        store.flush()
    }

    func focus() {
        wantsFocus = true
        guard loaded, displayedID == store.activeTabID else { return }
        wantsFocus = false
        webView.window?.makeFirstResponder(webView)
        Task { _ = try? await invoke("focus") }
    }

    func command(_ command: String, value: String? = nil) {
        guard loaded, displayedID == store.activeTabID, !loading else { return }
        let id = store.activeTabID.uuidString
        Task {
            do {
                _ = try await webView.callAsyncJavaScript("return window.notchEditor.command(name, value, id)",
                    arguments: ["name": command, "value": value ?? NSNull() as Any, "id": id], in: nil, contentWorld: .page)
            } catch { report(error.localizedDescription) }
        }
    }

    func receive(_ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let snapshot = try? JSONDecoder().decode(CrepeSnapshot.self, from: data),
              bridge.accept(snapshot, existingIDs: Set(store.tabs.map(\.id))) else { return }
        sources[snapshot.id] = snapshot.markdown
        store.updateText(snapshot.markdown, for: snapshot.id)
        store.updateCrepeSelection(snapshot.selection, for: snapshot.id)
        if snapshot.id == store.activeTabID {
            interaction?.setFormattingState(active: snapshot.active, mixed: snapshot.mixed)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "loaded": loaded = true; startLoading()
        case "snapshot": receive(body)
        case "error": report(body["message"] as? String ?? "Editor error")
        default: break
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let encoded = body["data"] as? String,
              let data = Data(base64Encoded: encoded),
              let embed = images.saveImage(data: data, name: body["name"] as? String ?? "image"),
              let url = Self.imageURL(embed: embed) else {
            replyHandler(nil, "Could not save image"); return
        }
        replyHandler(url, nil)
    }

    static func imageURL(embed: String) -> String? {
        guard embed.hasPrefix("![["), embed.hasSuffix("]]"), embed.count > 5 else { return nil }
        let reference = String(embed.dropFirst(3).dropLast(2))
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard let encoded = reference.addingPercentEncoding(withAllowedCharacters: safe) else { return nil }
        return "notchnotes-image://asset/" + encoded
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "asset",
              let data = images.editorImageData(reference: String(url.path.dropFirst())) else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)); return
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.isFileURL, navigationAction.navigationType != .linkActivated { return .allow }
        if navigationAction.navigationType == .linkActivated {
            if ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            else if url.scheme == "notchnotes-wiki" {
                let reference = String(url.path.dropFirst()).components(separatedBy: "|")
                let targetID = reference.count > 1 ? UUID(uuidString: reference[1]) : nil
                if let tab = store.tabs.first(where: { $0.id == targetID }) {
                    store.selectTab(tab.id)
                } else if targetID == nil, let tab = store.tabs.first(where: { store.title(for: $0.id) == reference.first }) {
                    store.selectTab(tab.id)
                }
            }
        }
        return .cancel
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageGeneration = UUID(); loadTask = nil; loading = false; inFlight = nil; pending = nil
        bridge = CrepeBridgeState()
        loaded = false; displayedID = nil; sources.removeAll()
        requestDocument(); loadPage()
    }
    private func report(_ message: String) { error = message; interaction?.editorError = message }
}

/// WKUserContentController retains handlers; keep its back-reference weak.
@MainActor
private final class CrepeMessageProxy: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKURLSchemeHandler {
    weak var owner: CrepeEditorController?
    init(_ owner: CrepeEditorController) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { owner?.userContentController(controller, didReceive: message) }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let owner else { replyHandler(nil, "Editor closed"); return }
        owner.userContentController(controller, didReceive: message, replyHandler: replyHandler)
    }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) { owner?.webView(webView, start: task) }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { owner?.webView(webView, stop: task) }
}

@MainActor
final class CrepeWebView: WKWebView {
    weak var controller: CrepeEditorController?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": controller?.command("bold"); return true
        case "i": controller?.command("italic"); return true
        case "z": controller?.command(event.modifierFlags.contains(.shift) ? "redo" : "undo"); return true
        case "v":
            if let embed = controller?.images.saveImage(from: .general), let url = CrepeEditorController.imageURL(embed: embed) {
                controller?.command("insertImage", value: url); return true
            }
        default: break
        }
        return super.performKeyEquivalent(with: event)
    }
    @objc func applyMarkdownBold(_ sender: Any?) { controller?.command("bold") }
    @objc func applyMarkdownItalic(_ sender: Any?) { controller?.command("italic") }
}

struct CrepeEditorView: NSViewRepresentable {
    let store: NoteStore
    let images: LocalImageStore
    let interaction: EditorInteractionState
    func makeNSView(context: Context) -> CrepeWebView {
        let controller = interaction.crepeEditor ?? CrepeEditorController(store: store, images: images, interaction: interaction)
        interaction.bind(webEditor: controller)
        return controller.webView
    }
    func updateNSView(_ view: CrepeWebView, context: Context) { view.controller?.requestDocument() }
}
