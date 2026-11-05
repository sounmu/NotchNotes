//
//  MarkdownDetection.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Helper checks for questions like "is the cursor inside code or LaTeX?"
// and "which Markdown part is currently active?".
import Foundation

enum MarkdownDetection {

    // MARK: - Active Token Indices

    static func computeActiveTokenIndices(
        selectionRange: NSRange,
        tokens: [MarkdownToken],
        in text: NSString
    ) -> Set<Int> {
        var indices: Set<Int> = []
        let caretLocation = selectionRange.location
        for (index, token) in tokens.enumerated() {
            let start = token.range.location
            let end = NSMaxRange(token.range)
            // Completed inline formatting collapses as soon as the caret passes
            // its closing delimiter. A selection reveals every format it touches.
            let isInlineFormatting = token.kind == .strikethrough || token.kind == .bold
                || token.kind == .italic || token.kind == .boldItalic
            if isInlineFormatting {
                if selectionRange.length > 0 {
                    if NSIntersectionRange(selectionRange, token.range).length > 0 {
                        indices.insert(index)
                    }
                } else if caretLocation >= start && caretLocation < end {
                    indices.insert(index)
                }
                continue
            }
            if selectionRange.length > 0 && (token.kind == .inlineLatex || token.kind == .blockLatex) && NSIntersectionRange(selectionRange, token.range).length > 0 {
                indices.insert(index)
                continue
            }
            if caretLocation >= start && caretLocation < end {
                indices.insert(index)
                continue
            }
            if caretLocation == end {
                let lastIndex = end - 1
                if lastIndex >= start && lastIndex < text.length {
                    let lastChar = text.substring(with: NSRange(location: lastIndex, length: 1))
                    if lastChar != "\n" {
                        indices.insert(index)
                    }
                }
            }
        }
        return indices
    }

    // MARK: - Code Block Detection

    /// Slow: parses tokens each call
    static func isInsideCodeBlock(range: NSRange, in text: String) -> Bool {
        let codeTokens = MarkdownTokenizer.parseTokens(in: text).filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
        return isInsideCodeBlock(range: range, codeTokens: codeTokens)
    }

    static func isInsideCodeBlock(location: Int, in text: String) -> Bool {
        isInsideCodeBlock(range: NSRange(location: location, length: 0), in: text)
    }

    /// Fast: uses pre-parsed tokens
    static func isInsideCodeBlock(range: NSRange, codeTokens: [MarkdownToken]) -> Bool {
        guard !codeTokens.isEmpty else { return false }
        for token in codeTokens {
            let start = token.range.location
            let end = start + token.range.length
            if range.length == 0 {
                if range.location >= start && range.location <= end { return true }
            } else {
                if range.location < end && range.location + range.length > start { return true }
            }
        }
        return false
    }

    static func isInsideCodeBlock(location: Int, codeTokens: [MarkdownToken]) -> Bool {
        isInsideCodeBlock(range: NSRange(location: location, length: 0), codeTokens: codeTokens)
    }

    // MARK: - Input Code Context

    /// Code context for editing commands (Shift+Enter, Enter, Tab, …).
    ///
    /// Unlike the styling-oriented `isInsideCodeBlock`, a caret immediately
    /// after a closed token is outside the code: after ``- `code` `` a hard
    /// break belongs to the surrounding Markdown, not to the inline code.
    /// Fenced blocks are scanned line-by-line so an unclosed fence, a language
    /// info string, and tilde fences all count as code too.
    static func isInsideCodeContext(location: Int, in text: String) -> Bool {
        let nsText = text as NSString
        guard location >= 0, location <= nsText.length else { return false }
        if isInsideFencedCode(location: location, in: nsText) { return true }

        let inlineCodeTokens = MarkdownTokenizer.parseTokens(in: text).filter { $0.kind == .inlineCode }
        for token in inlineCodeTokens {
            let start = token.range.location
            let end = NSMaxRange(token.range)
            if location >= start && location < end { return true }
        }
        return false
    }

    private struct FenceMarker {
        let character: Character
        let length: Int
    }

    /// Returns true when `location` is inside a backtick or tilde fenced code
    /// block, including a fence that has not been closed yet.
    private static func isInsideFencedCode(location: Int, in text: NSString) -> Bool {
        guard text.length > 0 else { return false }

        var openFence: FenceMarker?
        var blockStart = 0
        var lineStart = 0

        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = text.substring(with: lineRange)
                .trimmingCharacters(in: .newlines)

            if let fence = openFence {
                if let closingOffset = closingFenceOffset(in: line, matching: fence) {
                    let fenceEnd = lineRange.location + closingOffset
                    if location >= blockStart && location < fenceEnd { return true }
                    openFence = nil
                }
            } else if let fence = openingFence(in: line) {
                openFence = fence
                blockStart = lineRange.location
            }

            lineStart = NSMaxRange(lineRange)
        }

        return openFence != nil && location >= blockStart
    }

    private static func openingFence(in line: String) -> FenceMarker? {
        guard let run = fenceRun(in: line), run.count >= 3 else { return nil }
        // A backtick info string may not contain another backtick.
        if run.character == "`" && run.remainder.contains("`") { return nil }
        return FenceMarker(character: run.character, length: run.count)
    }

    private static func closingFenceOffset(in line: String, matching fence: FenceMarker) -> Int? {
        guard let run = fenceRun(in: line),
              run.character == fence.character,
              run.count >= fence.length,
              run.remainder.allSatisfy({ $0 == " " || $0 == "\t" }) else {
            return nil
        }
        return line[..<run.remainder.startIndex].utf16.count
    }

    private static func fenceRun(in line: String) -> (character: Character, count: Int, remainder: Substring)? {
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            indent += 1
            if indent > 3 { return nil }
            index = line.index(after: index)
        }
        guard index < line.endIndex,
              line[index] == "`" || line[index] == "~" else { return nil }

        let character = line[index]
        var count = 0
        while index < line.endIndex, line[index] == character {
            count += 1
            index = line.index(after: index)
        }
        return (character, count, line[index...])
    }

    // MARK: - LaTeX Detection

    static func isInsideLatex(location: Int, in text: String) -> Bool {
        let tokens = MarkdownTokenizer.parseTokens(in: text)
        let latexTokens = tokens.filter { $0.kind == .inlineLatex || $0.kind == .blockLatex }
        return isInsideLatex(location: location, latexTokens: latexTokens)
    }

    static func isInsideLatex(location: Int, latexTokens: [MarkdownToken]) -> Bool {
        guard !latexTokens.isEmpty else { return false }
        for token in latexTokens {
            let start = token.range.location
            let end = start + token.range.length
            if location >= start && location <= end { return true }
        }
        return false
    }

    static func isInsideInlineLatex(range: NSRange, in text: String) -> Bool {
        let latexTokens = MarkdownTokenizer.parseTokens(in: text).filter { $0.kind == .inlineLatex }
        return isInsideInlineLatex(range: range, latexTokens: latexTokens)
    }

    static func isInsideInlineLatex(location: Int, in text: String) -> Bool {
        isInsideInlineLatex(range: NSRange(location: location, length: 0), in: text)
    }

    static func isInsideInlineLatex(range: NSRange, latexTokens: [MarkdownToken]) -> Bool {
        guard !latexTokens.isEmpty else { return false }
        for token in latexTokens {
            let start = token.range.location
            let end = start + token.range.length
            if range.length == 0 {
                if range.location >= start && range.location <= end { return true }
            } else {
                if range.location < end && range.location + range.length > start { return true }
            }
        }
        return false
    }

    static func isInsideInlineLatex(location: Int, latexTokens: [MarkdownToken]) -> Bool {
        isInsideInlineLatex(range: NSRange(location: location, length: 0), latexTokens: latexTokens)
    }
}
