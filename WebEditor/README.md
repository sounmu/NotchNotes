# NotchNotes Crepe integration

The current development build uses NativeMarkdownKit by default. This Crepe
implementation is retained as a comparison/reference and tested independently;
the native note view does not instantiate its WKWebView.

Milkdown Crepe 7.23.0 runs inside one lazily created WKWebView. JavaScript,
CSS, fonts and third-party notices are bundled locally; no editor server or
CDN is required. HTTPS images in user documents can still load remotely.

## Build

Requires Node.js 22+ and npm. From this directory:

```sh
npm ci
npm test
npm run build
```

Commit source, `package-lock.json`, and the generated
`Sources/NotchNotes/Resources/Crepe` directory together. Swift builds consume
those checked-in assets without Node.js. `Scripts/package-app.sh` includes the
SwiftPM resource bundle in the app. The build also collects licenses from
bundled npm packages in `THIRD_PARTY_NOTICES.txt`.

## Bridge contract

- `CrepeEditorController` owns the webview and queues document replacements.
  The drawer creates it on its first opening, then reuses it.
- Each snapshot carries a note UUID, generation UUID, strictly increasing
  sequence number, Markdown, ProseMirror selection and inline format state.
  Deleted notes, old generations and duplicate/older snapshots are rejected.
- Switching returns an outgoing snapshot before applying the next note.
  Queued requests read the latest store contents when executed. Flush awaits
  queued replacements; app termination awaits flush before disk persistence.
- Original source is retained until editing changes the serialized document.
  Afterwards Crepe normalizes Markdown (for example bullet style and trailing
  newlines). Selection-only updates reuse the serialized document.
- Per-note EditorState caches retain Undo/Redo, selection and scroll while the
  source matches. External replacements reset history. Deleted-note caches
  are removed; process recovery reloads the last accepted store snapshot.
- ProseMirror positions are persisted separately as `crepeSelection`, never
  interpreted as Markdown source offsets.
- The codec adapts `![[image|id]]` and `[[note|id]]` in text nodes, preserving
  literal examples inside code. Image uploads go through LocalImageStore;
  `notchnotes-image:` serves local PNGs. Wiki navigation prefers stable UUIDs.

## Verification

Run `swift test` at the repository root. Crepe tests create real WKWebViews
with isolated stores and check DOM checkbox toggles, formatting, Unicode,
history, rapid tab switching, replacement, hidden-window flushing, disk
reload, image upload/rendering and wiki navigation.

Physical Korean IME composition, OS-level mouse hit-testing, cross-application
rich clipboard behavior and notch-window focus transitions still need manual
acceptance testing. Automated Unicode insertion is not an IME test.

Resource measurements for the comparison prototype are in
`Prototypes/EditorComparison/README.md`; they are not production-app benchmarks.
