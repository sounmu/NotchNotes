//
//  ContextMenu.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 20.06.25.
//
//  Right-click menu with toggleable Markdown formatting actions.
//

import Cocoa
import SwiftUI

extension NativeTextViewWrapper.Coordinator {
    public func textView(_ textView: NSTextView,
                  menu: NSMenu,
                  for event: NSEvent,
                  at charIndex: Int) -> NSMenu? {
        let customMenu = menu.copy() as? NSMenu ?? NSMenu()
        insertImageAssetItemsIfNeeded(into: customMenu, textView: textView, charIndex: charIndex)

        if let fontIndex = customMenu.items.firstIndex(where: { $0.title == "Font" }) {
            customMenu.removeItem(at: fontIndex)
            let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
            let formatSubmenu = NSMenu(title: "Format")
            let boldItem = NSMenuItem(title: "Bold", action: #selector(didMarkdownBold(_:)), keyEquivalent: "")
            boldItem.target = self
            formatSubmenu.addItem(boldItem)
            let italicItem = NSMenuItem(title: "Italic", action: #selector(didMarkdownItalic(_:)), keyEquivalent: "")
            italicItem.target = self
            formatSubmenu.addItem(italicItem)
            formatItem.submenu = formatSubmenu
            customMenu.insertItem(formatItem, at: fontIndex)

            let headingItem = NSMenuItem(title: "Heading", action: nil, keyEquivalent: "")
            let headingSubmenu = NSMenu(title: "Heading")
            for level in 1...3 {
                let item = NSMenuItem(title: "H\(level)", action: #selector(didMarkdownHeading(_:)), keyEquivalent: "")
                item.target = self
                item.tag = level
                headingSubmenu.addItem(item)
            }
            headingItem.submenu = headingSubmenu
            customMenu.insertItem(headingItem, at: fontIndex + 1)

            let listItem = NSMenuItem(title: "Lists", action: nil, keyEquivalent: "")
            let listSubmenu = NSMenu(title: "Lists")
            let unorderedItem = NSMenuItem(title: "Bullet", action: #selector(didMarkdownUnorderedList(_:)), keyEquivalent: "")
            unorderedItem.target = self
            listSubmenu.addItem(unorderedItem)
            let orderedItem = NSMenuItem(title: "Numbered", action: #selector(didMarkdownOrderedList(_:)), keyEquivalent: "")
            orderedItem.target = self
            listSubmenu.addItem(orderedItem)
            listItem.submenu = listSubmenu
            customMenu.insertItem(listItem, at: fontIndex + 2)
            customMenu.insertItem(NSMenuItem.separator(), at: fontIndex + 3)
        }

        return customMenu
    }

    private func insertImageAssetItemsIfNeeded(into menu: NSMenu, textView: NSTextView, charIndex: Int) {
        guard let provider = configuration.services.images as? any EmbeddedImageFileProvider,
              let imageReference = imageReference(at: charIndex, in: textView) else {
            return
        }

        let request = imageReference.providerRequest
        let storedURL = provider.storedFileURL(for: request)
        let originalURL = provider.originalFileURL(for: request)

        let copyImageItem = NSMenuItem(title: "复制图片", action: #selector(didCopyEmbeddedImage(_:)), keyEquivalent: "")
        copyImageItem.target = self
        copyImageItem.representedObject = request
        copyImageItem.isEnabled = configuration.services.images.image(for: request) != nil

        let copyStoredFileItem = NSMenuItem(title: "复制图片文件", action: #selector(didCopyEmbeddedImageFile(_:)), keyEquivalent: "")
        copyStoredFileItem.target = self
        copyStoredFileItem.representedObject = storedURL
        copyStoredFileItem.isEnabled = storedURL != nil

        let copyOriginalFileItem = NSMenuItem(title: "复制原始文件", action: #selector(didCopyEmbeddedImageFile(_:)), keyEquivalent: "")
        copyOriginalFileItem.target = self
        copyOriginalFileItem.representedObject = originalURL
        copyOriginalFileItem.isEnabled = originalURL != nil

        let revealStoredItem = NSMenuItem(title: "在 Finder 中显示副本", action: #selector(didRevealEmbeddedImageFile(_:)), keyEquivalent: "")
        revealStoredItem.target = self
        revealStoredItem.representedObject = storedURL
        revealStoredItem.isEnabled = storedURL != nil

        let revealOriginalItem = NSMenuItem(title: "在 Finder 中显示原始文件", action: #selector(didRevealEmbeddedImageFile(_:)), keyEquivalent: "")
        revealOriginalItem.target = self
        revealOriginalItem.representedObject = originalURL
        revealOriginalItem.isEnabled = originalURL != nil

        let copyMarkdownItem = NSMenuItem(title: "复制 Markdown 引用", action: #selector(didCopyEmbeddedImageMarkdown(_:)), keyEquivalent: "")
        copyMarkdownItem.target = self
        copyMarkdownItem.representedObject = imageReference.markdown

        [
            copyImageItem,
            copyStoredFileItem,
            copyOriginalFileItem,
            revealStoredItem,
            revealOriginalItem,
            copyMarkdownItem,
            NSMenuItem.separator()
        ].reversed().forEach { item in
            menu.insertItem(item, at: 0)
        }
    }

    private func imageReference(at charIndex: Int, in textView: NSTextView) -> ImageEmbedReference? {
        let text = textView.string as NSString
        guard text.length > 0 else { return nil }

        let fallbackLocation = min(textView.selectedRange().location, text.length)
        let clickLocation = charIndex >= 0 ? min(charIndex, text.length) : fallbackLocation
        let parsed = parsedDocument(for: textView.string)

        let token = parsed.imageEmbedTokens.first { token in
            token.containsSelectionOrStandaloneParagraph(clickLocation, in: text)
                || token.containsSelectionOrStandaloneParagraph(fallbackLocation, in: text)
        }

        guard let token else { return nil }
        let content = text.substring(with: token.contentRange)
        return ImageEmbedReference(content: content)
    }

    @objc private func didCopyEmbeddedImage(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EmbeddedImageRequest,
              let image = configuration.services.images.image(for: request) else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    @objc private func didCopyEmbeddedImageFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    @objc private func didRevealEmbeddedImageFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func didCopyEmbeddedImageMarkdown(_ sender: NSMenuItem) {
        guard let markdown = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }

    /// Returns the smallest bold or boldItalic token that fully contains the selection, or nil when the selection isn't enclosed by emphasis with a bold trait.
    func enclosingBoldToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { token in
            (token.kind == .bold || token.kind == .boldItalic) && tokenEncloses(token, selection: selection)
        }
    }

    /// Returns the smallest italic or boldItalic token that fully contains the selection, or nil when the selection isn't enclosed by emphasis with an italic trait.
    func enclosingItalicToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { token in
            (token.kind == .italic || token.kind == .boldItalic) && tokenEncloses(token, selection: selection)
        }
    }

    func isSelectionBold(in nsText: NSString, range: NSRange) -> Bool {
        if configuration.inlineEditingMode == .formatted, range.length == 0,
           let tv = textView, let styles = formattedTypingState?.styles(in: tv) { return styles.contains(.bold) }
        return enclosingBoldToken(for: range, in: nsText as String) != nil
    }

    func isSelectionItalic(in nsText: NSString, range: NSRange) -> Bool {
        if configuration.inlineEditingMode == .formatted, range.length == 0,
           let tv = textView, let styles = formattedTypingState?.styles(in: tv) { return styles.contains(.italic) }
        return enclosingItalicToken(for: range, in: nsText as String) != nil
    }

    private func tokenEncloses(_ token: MarkdownToken, selection: NSRange) -> Bool {
        return selection.location >= token.range.location
            && NSMaxRange(selection) <= NSMaxRange(token.range)
    }

    /// Replaces the marker characters of an emphasis token with `replacement` on each side, preserving the inner content.
    private func unwrapToken(_ token: MarkdownToken, leftReplacement: String, rightReplacement: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let content = nsText.substring(with: token.contentRange)
        let newText = leftReplacement + content + rightReplacement
        let selection = NSRange(location: token.range.location + leftReplacement.utf16.count,
                                length: content.utf16.count)
        MarkdownFormatting.replaceSource(in: tv, range: token.range, with: newText, selectionAfter: selection)
    }

    func isSelectionHeading(level: Int, in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLine.hasPrefix(String(repeating: "#", count: level) + " ")
    }

    func isSelectionList(in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        return line.hasPrefix("\t• ") || line.hasPrefix("1. ")
    }

    private func applyHeading(level: Int) {
        guard let tv = textView else { return }
        if MarkdownFormatting.applyBlock(.heading(level), in: tv) { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let lineRange = nsText.lineRange(for: range)
        var contentsEnd = 0
        nsText.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lineRange)
        let rawLine = nsText.substring(with: NSRange(location: lineRange.location, length: contentsEnd - lineRange.location))
        let suffix = nsText.substring(with: NSRange(location: contentsEnd, length: NSMaxRange(lineRange) - contentsEnd))
        var content = String(rawLine.drop(while: { $0 == " " || $0 == "\t" }))
        while content.hasPrefix("#") { content.removeFirst() }
        content = String(content.drop(while: { $0 == " " || $0 == "\t" }))
        let prefix = String(repeating: "#", count: level) + " "
        let newLine = prefix + content + suffix
        let selection = NSRange(location: lineRange.location + prefix.utf16.count, length: content.utf16.count)
        MarkdownFormatting.replaceSource(in: tv, range: lineRange, with: newLine, selectionAfter: selection)
    }

    @objc func didMarkdownHeading(_ sender: NSMenuItem) {
        applyHeading(level: sender.tag)
    }

    private func applyList(prefix: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let selRange = tv.selectedRange()
        let startLine = nsText.lineRange(for: selRange)
        var contentsEnd = 0
        nsText.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: startLine)
        let lineText = nsText.substring(with: NSRange(location: startLine.location, length: contentsEnd - startLine.location))
        var content = lineText
        if content.hasPrefix(prefix) {
            content = String(content.dropFirst(prefix.count))
        }
        let newLine = prefix + content
        let suffix = nsText.substring(with: NSRange(location: contentsEnd, length: NSMaxRange(startLine) - contentsEnd))
        let replacement = newLine + suffix
        let selection = NSRange(location: startLine.location + prefix.utf16.count, length: content.utf16.count)
        MarkdownFormatting.replaceSource(in: tv, range: startLine, with: replacement, selectionAfter: selection)
    }

    @objc func didMarkdownUnorderedList(_ sender: Any?) {
        if let tv = textView, MarkdownFormatting.applyBlock(.unorderedList, in: tv) { return }
        applyList(prefix: "\t• ")
    }

    @objc func didMarkdownOrderedList(_ sender: Any?) {
        if let tv = textView, MarkdownFormatting.applyBlock(.orderedList, in: tv) { return }
        applyList(prefix: "1. ")
    }

    @objc func didMarkdownBold(_ sender: Any?) {
        guard let tv = textView else { return }
        if MarkdownFormatting.apply(.bold, in: tv) { return }
        let range = tv.selectedRange()

        if let token = enclosingBoldToken(for: range, in: tv.string) {
            // Toggle off: bold → plain, boldItalic → italic.
            let (left, right) = token.kind == .boldItalic ? ("*", "*") : ("", "")
            unwrapToken(token, leftReplacement: left, rightReplacement: right)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("**")
            return
        }

        wrapSelection(with: "**")
    }

    @objc func didMarkdownItalic(_ sender: Any?) {
        guard let tv = textView else { return }
        if MarkdownFormatting.apply(.italic, in: tv) { return }
        let range = tv.selectedRange()

        if let token = enclosingItalicToken(for: range, in: tv.string) {
            // Toggle off: italic → plain, boldItalic → bold.
            let (left, right) = token.kind == .boldItalic ? ("**", "**") : ("", "")
            unwrapToken(token, leftReplacement: left, rightReplacement: right)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("*")
            return
        }

        wrapSelection(with: "*")
    }

    private func insertEmptyMarkers(_ marker: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let insertion = marker + marker
        let selection = NSRange(location: range.location + marker.utf16.count, length: 0)
        MarkdownFormatting.replaceSource(in: tv, range: range, with: insertion, selectionAfter: selection)
    }

    private func wrapSelection(with marker: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let original = nsText.substring(with: range)
        let leadingWS = original.prefix { $0.isWhitespace }.count
        let trailingWS = original.dropFirst(leadingWS).reversed().prefix { $0.isWhitespace }.count
        let coreStart = original.index(original.startIndex, offsetBy: leadingWS)
        let coreEnd = original.index(original.endIndex, offsetBy: -trailingWS)
        let core = coreStart <= coreEnd ? String(original[coreStart..<coreEnd]) : ""
        let leading = String(original[..<coreStart])
        let trailing = String(original[coreEnd...])
        let newText = leading + marker + core + marker + trailing
        let selection = NSRange(location: range.location + leading.utf16.count + marker.utf16.count,
                                length: core.utf16.count)
        MarkdownFormatting.replaceSource(in: tv, range: range, with: newText, selectionAfter: selection)
    }
}

// MARK: - Menu Item Validation
extension NativeTextViewWrapper.Coordinator: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let tv = textView else { return true }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        switch menuItem.action {
        case #selector(didMarkdownBold(_:)):
            menuItem.state = isSelectionBold(in: nsText, range: range) ? .on : .off
            return true
        case #selector(didMarkdownItalic(_:)):
            menuItem.state = isSelectionItalic(in: nsText, range: range) ? .on : .off
            return true
        case #selector(didMarkdownHeading(_:)):
            if configuration.inlineEditingMode == .formatted { return tv.isEditable }
            return !isSelectionHeading(level: menuItem.tag, in: nsText, range: range)
        case #selector(didMarkdownUnorderedList(_:)),
              #selector(didMarkdownOrderedList(_:)):
            if configuration.inlineEditingMode == .formatted { return tv.isEditable }
            return !isSelectionList(in: nsText, range: range)
        case #selector(didCopyEmbeddedImage(_:)):
            return menuItem.representedObject is EmbeddedImageRequest
        case #selector(didCopyEmbeddedImageFile(_:)),
             #selector(didRevealEmbeddedImageFile(_:)):
            return menuItem.representedObject is URL
        case #selector(didCopyEmbeddedImageMarkdown(_:)):
            return menuItem.representedObject is String
        default:
            return true
        }
    }
}
