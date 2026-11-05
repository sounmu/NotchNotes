import Foundation

/// Source escapes are part of the Markdown representation, never editable
/// characters in formatted mode. Code spans/blocks keep backslashes literal.
enum MarkdownEscaping {
    static let punctuation = CharacterSet(charactersIn: #"\`*~_[]{}()#+-.!>"#)

    static func isEscaped(_ offset: Int, in text: NSString) -> Bool {
        var index = offset - 1
        var count = 0
        while index >= 0, text.character(at: index) == 92 { count += 1; index -= 1 }
        return !count.isMultiple(of: 2)
    }

    static func markerRanges(in text: String, tokens: [MarkdownToken]) -> [NSRange] {
        let source = text as NSString
        let literals = tokens.filter { [.codeBlock, .inlineCode, .inlineLatex, .blockLatex].contains($0.kind) }
        var result: [NSRange] = []
        var index = 0
        while index + 1 < source.length {
            if source.character(at: index) == 92,
               let scalar = UnicodeScalar(source.character(at: index + 1)), punctuation.contains(scalar),
               !literals.contains(where: { NSLocationInRange(index, $0.range) }) {
                result.append(NSRange(location: index, length: 1))
                index += 2
            } else { index += 1 }
        }
        return result
    }

    static func literal(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if ["\\", "*", "~", "`", "_"].contains(character) { result.append("\\") }
            result.append(character)
        }
    }
}
