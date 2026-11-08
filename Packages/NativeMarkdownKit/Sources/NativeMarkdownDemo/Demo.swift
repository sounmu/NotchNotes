import AppKit
import NativeMarkdownCore
import NativeMarkdownAppKit

@MainActor
final class Demo: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var editor: NativeMarkdownEditor!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let document = try! MarkdownDocument(markdown: "# NativeMarkdownKit\n\n기존 NotchNotes 디자인으로 **네이티브 문서**를 편집합니다.\n\n- [ ] 체크박스를 클릭해 보세요\n- [x] 문단을 가로질러 선택할 수 있습니다\n\n새 줄에서 - 또는 ## 뒤에 공백을 입력해 보세요.")
        editor = NativeMarkdownEditor(document: document)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "NativeMarkdownKit — NotchNotes native editor"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 0
        let buttons = NSStackView(); buttons.spacing = 4
        buttons.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        buttons.wantsLayer = true
        buttons.layer?.backgroundColor = NSColor(red: 0.055, green: 0.055, blue: 0.065, alpha: 1).cgColor
        let commands = [("bold", "Bold"), ("italic", "Italic"), ("strikethrough", "Strikethrough"), ("chevron.left.forwardslash.chevron.right", "Code"),
                        ("link", "Link"), ("quote.opening", "Quote"), ("list.bullet", "Bulleted list"), ("list.number", "Numbered list"), ("checklist", "Task list")]
        for (index, item) in commands.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: item.0, accessibilityDescription: item.1)!, target: self, action: #selector(command(_:)))
            button.tag = index; button.isBordered = false; button.toolTip = item.1
            button.contentTintColor = NSColor.white.withAlphaComponent(0.66)
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            buttons.addArrangedSubview(button)
        }
        buttons.addArrangedSubview(NSView())
        let exportButton = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export Markdown")!, target: self, action: #selector(export))
        exportButton.isBordered = false; buttons.addArrangedSubview(exportButton)
        let separator = NSBox(); separator.boxType = .separator
        root.addArrangedSubview(editor); root.addArrangedSubview(separator); root.addArrangedSubview(buttons)
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        separator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        buttons.heightAnchor.constraint(equalToConstant: 38).isActive = true
        window.contentView = root; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func bold() { editor.toggle(.bold) }
    @objc func undo() { editor.undo() }
    @objc func redo() { editor.redo() }
    @objc func command(_ sender: NSButton) {
        switch sender.tag {
        case 0: editor.toggle(.bold)
        case 1: editor.toggle(.italic)
        case 2: editor.toggle(.strikethrough)
        case 3: editor.toggle(.code)
        case 4: editor.insertLink()
        case 5: editor.toggleBlock(.quote)
        case 6: editor.toggleBlock(.bullet(depth: 0))
        case 7: editor.toggleBlock(.ordered(number: 1, depth: 0))
        case 8: editor.toggleBlock(.task(checked: false, depth: 0))
        default: break
        }
    }
    @objc func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "native-markdown.md"
        if panel.runModal() == .OK, let url = panel.url { try? editor.session.document.markdown().write(to: url, atomically: true, encoding: .utf8) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = Demo()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
