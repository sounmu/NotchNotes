# Third-party dependencies

Resolved revisions are recorded in `Package.resolved`.

- **swift-markdown 0.9.0** — Apple Inc. and the Swift project authors.
  Apache License 2.0 with Runtime Library Exception.
  [License](https://github.com/swiftlang/swift-markdown/blob/0.9.0/LICENSE.txt)
  · [Notice](https://github.com/swiftlang/swift-markdown/blob/0.9.0/NOTICE.txt)
- **swift-cmark 0.9.0** — Swift's fork of cmark-gfm/cmark, with upstream
  copyright holders and component-specific terms recorded in
  [COPYING](https://github.com/swiftlang/swift-cmark/blob/0.9.0/COPYING).

SwiftPM fetches these source dependencies with their license files. NotchNotes'
packaging script copies their full license/notice texts into the app's
`Contents/Resources/ThirdParty` directory. Other binary distributions must do so too.
Milkdown Crepe is used by the parent application's WebEditor, not by this
package; its bundled notices live in the application's Crepe resources.
