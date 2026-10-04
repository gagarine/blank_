# blank_

A quiet native macOS app for academic writing in [Typst](https://typst.app). SwiftUI supplies the interface, AppKit/TextKit 2 supplies editing and typography, and PDFKit displays the official Typst compiler's PDF. Documents remain ordinary local `.typ` files. There is no web renderer.

**Made using AI (OpenAI Codex). Open source under the [MIT license](LICENSE).**

The Go implementation on `codex/legacy-go` is the reference for document behavior and feature coverage. Its tutorial is bundled unchanged. macOS conventions guide the interface: the app opens an empty focused editor, uses the system menu bar and a customizable native Liquid Glass toolbar, and leaves text layout, input, selection and scrolling to Apple frameworks. The Rust prototype and its earlier work remain preserved on `codex/rust-native-prototype` at `d8e8448`.

## Build and run

Requires macOS **26 or newer**, Swift 6.4 Command Line Tools with the macOS 27 SDK, Rust and Python 3 for checks. Current verification is on Apple Silicon/macOS 27. The pinned Rust dependencies build offline when cached; remove `--offline` in the build script for a first dependency download.

```sh
bash scripts/build.sh          # debug app; optimized compiler/parser
open build/blank_.app
bash scripts/build.sh release  # optimized frontend
bash scripts/check.sh          # model, parser, compiler and native acceptance
```

Both build configurations update the same `build/blank_.app`. The obsolete QA/layout/review app copies have been removed; debug binaries and compiler caches remain in `.build` and the Rust target directories for iteration.

Write follows native text-substitution and spelling preferences; Source disables prose substitutions to preserve Typst code. Native Services and saved-document title proxies are available.

Use ⌘1/⌘2/⌘3 for Write/Source/Preview, ⌘K for application commands and `/` for formatting and insertion beside the caret. Help → Tutorial opens an independent editable copy of the original Go tutorial. The toolbar uses system controls, including macOS 27's native tab role for the view switcher.

In Write, Return starts a new paragraph with a visible gap, including empty paragraphs, and retains the focused native caret. Shift-Return inserts a line break within the current paragraph. Return continues lists; Return on an empty item exits the list. Hover a block to reveal its handle, then drag it to the single horizontal insertion line.

The native menus provide document windows, New Paper/New Thesis, Open Recent, save/rename, PDF export, shared undo/redo, formatting and search. Saved files autosave after 650 ms of inactivity. Unsaved writing gets recovery copies; File → Open Recovery Copy opens one as an unsaved document. External conflicts and deleted files require resolution before overwriting. Save As copies known project dependencies and imported assets after checking collisions. Local imports are loaded as dependencies; literal image/read/bibliography/custom-CSL paths are discovered from syntax rather than commented examples. Dynamic dependencies and package caches still need separate handling.

## Architecture

Swift owns the canonical Typst source, conservative syntax-backed projections, UTF-16/native-to-UTF-8/source mapping and localized transactions. Ordinary edits reparse the affected block and update its native attributes when safe; structural or uncertain edits use a full parse. Comments, custom expressions and unaffected source remain unchanged. Source displays and copies every source character.

Write and Source share range-based undo/redo with source selections, adjacent typing groups, a 200-operation/8 MiB payload budget, and retention of the latest operation. Included files keep independent histories. Native TextKit 2 supplies font fallback, shaping, layout, input and selections; the reading font initially uses the original Iowan Old Style with real bold/italic faces. Attributed SwiftUI TextEditor was evaluated; NSTextView supplies the pre-edit, composition, clipboard and caret geometry hooks needed here.

Rust is used only for Typst integration: the official parser behind a small C-compatible library and the Go version's official compiler helper behind a JSON-line process interface. Compilation runs on a background queue. Preview retains the last successful PDF on failure. PDFKit draws pages on demand; the app keeps one successful PDF per window and no raster page cache. The page counter follows native PDF navigation. Export requested during compilation waits for its revision rather than being dropped. Visible native table/figure controls are mounted using TextKit 2 attachment geometry; figure thumbnails have a bounded cache.

## Functionality roadmap

This carries forward the functionality plans from the Rust README and the Go guide/acceptance notes, adapted to a macOS-only native frontend. Checked items describe implemented behavior; they do not claim every native or integration scenario has passed. Detailed evidence and limitations are in [parity](docs/parity.md) and [acceptance](docs/acceptance.md).

- [x] Paragraphs, headings, lists and quotations; splitting/joining, list continuation and empty-item exit; Typst heading/bold/italic typing shortcuts.
- [x] Shared Write/Source undo, Unicode source mapping and structured internal clipboard preserving heading/list kinds and inline formatting.
- [x] Caret-adjacent slash commands, block menus/handles, drag previews and block movement; collapsible heading hierarchy and section movement.
- [x] Native table cells, Tab navigation/final-cell row addition, and row/column editing; native figures with insertion/import and captions.
- [x] Link, footnote, mathematics, label and cross-reference insertion dialogs.
- [ ] Edit existing inline links/footnotes directly; richer figure width/alternative-text/PDF-page controls and complete insertion/navigation around objects.
- [x] Image clipboard paste and file drop; project-relative asset paths and bounded native thumbnails.
- [ ] Validate every clipboard/drop format, SVG display and multipage PDF figures; measure memory with large images.
- [x] Zotero local-API citation search, stable identity keys, local bibliography/metadata, refresh and bibliography style selection.
- [ ] Validate against a live Zotero library; finish group-library discovery, citation-picker keyboard selection, custom CSL and existing citation editing.
- [x] Literal included-file loading/switching with independent histories, live include-graph refresh and include-based chapter reordering; Preview compiles in-memory chapter edits.
- [ ] Continuous editing across included files and repeated include occurrences; richer chapter movement/navigation controls.
- [x] Save As dependency/asset preservation, rename, article/thesis templates and native recent documents.
- [ ] Merge disjoint external changes; broaden relaunch, creation-date, disk-full and abrupt-termination checks.
- [x] Independent native document windows and recovery journals containing project source and imported assets.
- [ ] Finish multi-window keyboard, Window-menu, accessibility and document-lifetime validation.
- [x] Active-file/project search and replacement, per-file/project statistics, font/size/colors, paragraph focus and typewriter scrolling.
- [ ] Keep settings consistent across existing windows; count continuous manuscript occurrences and finish chapter-boundary search/selection checks.
- [x] Native keyboard navigation/deletion and marked-text handling; synthetic Japanese composition acceptance.
- [ ] Validate real IME candidate panels, international keyboard layouts, VoiceOver, bidirectional selection and Writing Tools round trips.
- [x] Native scrolling at the viewport edge, customizable macOS toolbar and system selection appearance.
- [ ] Finish long-document scrolling and pointer-drag checks in every view and secondary window.
- [x] Bounded local projection, cached fonts, changed-range history and background compilation with last-good Preview/PDF export.
- [ ] Reduce full Source styling/undo projection work on large files; measure total editor/compiler memory on representative theses and long-running sessions.
- [ ] Add opt-in per-window agent/MCP access, revision-checked multi-file transactions and selective agent undo through a native API.

Windows/Linux releases are outside this frontend's scope. Pandoc exchange, cloud collaboration, Word review, visual equation construction and built-in AI chat remain future product work, as in the Go guide.

## Validation

`bash scripts/check.sh` exercises the production source model, official parser/compiler, real native text views and disposable project files. The Command Line Tools environment lacks XCTest, so the 20 model checks run through the `BlankCoreChecks` executable. Native checks cover typing, paragraph/line breaks and empty insertion slots, formatting, clipboard, block drag handlers/geometry, synthetic composition, tables, figures, view switching, Source font faces, caret-menu geometry, PDF failure retention/export, saving, conflicts, deletion recovery, chapter history and Save As dependencies.

Resource measurements and their limits are recorded in [docs/acceptance.md](docs/acceptance.md). Native IME candidates, VoiceOver, bidirectional navigation and live Zotero remain unverified. The unchanged tutorial describes the Go app; some steps await Swift parity.

Issues and contributions are welcome. Third-party dependencies retain their licenses.
