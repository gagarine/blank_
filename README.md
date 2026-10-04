# blank_

A native macOS Swift frontend for writing Typst. SwiftUI supplies the interface, AppKit/TextKit 2 supplies text editing and typography, and PDFKit displays the official Typst compiler's PDF. There is no web renderer.

The reference is `codex/legacy-go`. The Rust prototype remains preserved on `codex/rust-native-prototype` at `d8e8448`. This branch reuses the Go version's exact tutorial and compiler helper, not the Rust prototype's frontend or document model.

## Build and run

Requires macOS 14+, Swift 6 Command Line Tools and Rust. Current verification is on Apple Silicon/macOS 27. The Rust dependencies are pinned; remove `--offline` in the build script for a first dependency download when caches are empty.

```sh
bash scripts/build.sh          # debug app; optimized compiler/parser
open build/blank_.app
bash scripts/build.sh release  # optimized frontend
bash scripts/check.sh          # model checks, parser checks, native acceptance
```

The app starts in an empty, focused editor. ⌘1/⌘2/⌘3 switch Write/Source/Preview. ⌘K opens application commands; `/` opens formatting and insertion beside the caret. Help → Tutorial opens an independent editable copy of the exact Go tutorial.

The native menus provide new/open/save, PDF export, shared undo/redo, copy/paste, formatting and search. Saved files autosave after 650 ms of inactivity. Unsaved documents get recovery copies; File → Open Recovery Copy opens one as an unsaved document. Existing external changes prompt before overwriting. Native windows, scrolling, selections, file panels and confirmation sheets are used.

## Implementation and limits

Swift owns canonical Typst source, conservative syntax-backed projections, UTF-16/native-to-UTF-8/source mapping, localized patches, and shared Write/Source undo. History retains changed ranges and source selections, groups adjacent typing, and is limited to 200 operations/8 MiB (the latest operation is retained). Unknown expressions and comments remain source regions. Source always displays and copies every source character.

Rust is used only for the official Typst parser and compiler: a small C-compatible parser library and the original Go branch's JSON-line compiler helper. Compilation runs on a serial background queue. Preview retains the last successful PDF after an error. PDFKit performs native page drawing as needed; the app retains one successful PDF per window and no raster page cache.

Implemented: paragraphs/headings/lists, real font faces for bold/italic, native clipboard with structured internal fragments, list Return/empty-item exit, block menus and dragging, hierarchy sidebar and section movement, source styling/delimiter pairs, included-file switching, search/replace, settings, statistics, insertion dialogs, table-cell/dimension editing sheets, image/figure importing, links/footnotes/math/labels, Zotero search/insertion/refresh, bibliography styles, document windows and recovery.

The application is in active development. The exact tutorial describes Go behaviors and is deliberately unmodified; it is not a promise that every step has passed Swift acceptance. Track implementation and actual validation in [docs/parity.md](docs/parity.md). Inline table editing, native figure display, continuous manuscript editing, asset paste/drop, project-wide statistics/search and agent/MCP access are not complete yet. Native IME candidate panels, VoiceOver and bidirectional navigation require manual verification. Zotero requests follow the Go local API but live integration has not been verified.

Model parsing/projection and styling currently refresh the active file after an edit. Resource measurements and the TextEditor/TextKit assessment will be recorded in [docs/acceptance.md](docs/acceptance.md); there are no unmeasured resource-use guarantees.

MIT license. Third-party dependencies retain their licenses.
