# NativeMarkdownKit

An experimental **macOS-only Markdown WYSIWYG editor** and the default editor
in the current NotchNotes development build. Milestone 2 replaces the original
block-per-view prototype with one continuous AppKit text surface. It is not a
feature-complete Swift port of Crepe.

## Run

Requires macOS 14+ and Swift 6.2+ (also required by swift-markdown 0.9.0).
From this directory:

```sh
swift test
swift run NativeMarkdownDemo
```

The demo edits an in-memory sample and exports Markdown through a save panel.
It does not access NotchNotes' notes.

## Structure

- **NativeMarkdownCore**: visible-text document model, Markdown import/export,
  document-wide UTF-16 selections, transactions and document/selection Undo/Redo.
  Depends on Swift Markdown, with no AppKit or WebKit dependency.
- **NativeMarkdownAppKit**: one continuous NSTextView, measured list/checkbox
  decorations, cross-block selection, text input, keyboard commands and scrolling.
- **NativeMarkdownDemo**: standalone macOS executable.

```swift
import NativeMarkdownCore
import NativeMarkdownAppKit

let document = try MarkdownDocument(markdown: "- [ ] **A task**")
let editor = NativeMarkdownEditor(document: document) // MainActor
editor.onChange = { markdown in
    // Persist through the host application's storage layer.
}
```

Markdown delimiters are never stored in the editable text. Stable block IDs
and visible UTF-16 offsets identify edits. The core rejects ranges that split
a surrogate pair or composed character. Undo/Redo restore document and
selection together.

## Milestone 2 scope

Import supports paragraphs, headings, simple paragraph-only quotes,
bullet/ordered lists, unordered tasks, nested lists, fenced code, and
bold/italic/strike/code runs and ordinary links. Export normalizes Markdown and
soft wraps; it is not byte-for-byte source preservation. Unsupported images,
tables, HTML, titled links and complex containers throw `EditingError.unsupportedMarkdown`
rather than being dropped during import.

Implemented: cross-block selection/replacement/formatting, Backspace/Delete
joins at block separators, task continuation and empty-list exit on Enter,
list indent/outdent, ordered-list renumbering, pending inline formatting,
Cmd+B/I/Z/Shift+Z, basic typing undo grouping, and Markdown typing rules for
headings/lists/quotes/bold/italic/strike/code. Checkbox drawing and mouse hit
testing share layout rectangles; there are no hidden source delimiters.

The adapter uses TextKit 1 for mature continuous NSTextView selection and input
composition. It does not rebuild attributed storage while marked text is active;
committed composition becomes a document transaction. Native colors, 15pt system
body font, heading ratios, 12pt insets and 18pt list indentation match the original
NotchNotes configuration. The application reuses its original SwiftUI toolbar.

NotchNotes caches native editors/history per note, persists native selections
separately, and preserves original source until an edit. Unsupported documents
use an explicitly labelled native source mode so editing does not discard their
content. Native note editing does not create a WKWebView. The Crepe implementation
remains available in source and integration tests as a comparison reference.

Clipboard copy/paste preserves native block structure and blank lines through
a native document-fragment representation, alongside Markdown, RTF and plain
text for other applications. RTF paste retains bold, italic, strike,
code font and links; plain-text paste remains literal text. Pasting is one
document/selection undo transaction. Source-mode toolbar commands and Cmd+B/I
edit Markdown delimiters while preserving the surrounding unsupported source.

Still incomplete: image/table rendering, local reference UI, HTML clipboard
import and RTF attachments, accessibility for drawn list
decorations, comprehensive typing rules/history grouping and large-document
incremental rendering. Arbitrary programmatically constructed models are not
guaranteed to serialize losslessly. Public APIs and the Codable model are unstable.

Tests cover visible text and marks, Unicode range validation, task toggling
and splitting, history, literal punctuation/code serialization, unsupported
input rejection, and actual AppKit text insertion/checkbox hit testing/layout.
Synthetic NSTextInputClient composition is tested, including tab-switch commit;
physical Korean IME use and OS-delivered mouse events remain to be verified.

## Next milestones

1. Establish an editor conformance corpus shared with the Crepe integration:
   mixed marks, list transformations, clipboard, composition and history.
2. Refine incremental rendering, accessible list decorations and history/IME
   behavior against real Korean input and clipboard workflows.
3. Expand the schema to links, images and tables; add round-trip fixtures and
   large-document benchmarks before treating the native build as production-ready.
4. Stabilize package APIs, accessibility and documentation, choose the project
   license, and extract into a public repository if approved.

## Attribution and publication

This package is an independent Swift implementation inspired by Crepe's
document-model approach; it does not embed Crepe or copy its JavaScript.
Its Markdown parser is [swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown)
0.9.0, which depends on [swiftlang/swift-cmark](https://github.com/swiftlang/swift-cmark).
See [THIRD_PARTY.md](THIRD_PARTY.md).

The project's own open-source license and copyright holder have not been
selected. No public package/repository release has been made.
