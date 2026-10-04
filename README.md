# blank_

**Made using AI (OpenAI Codex). Open source under the [MIT license](LICENSE).**

A quiet native Rust app for writing in Typst. Write, edit source, and preview typeset pages; documents stay ordinary local `.typ` files.

## Build and run

Requires Rust 1.98 or newer and, on macOS, Xcode Command Line Tools.

```sh
cargo xtask dev --demo       # launch with the tutorial
cargo xtask dev document.typ
cargo xtask check            # formatting, Clippy and tests
cargo xtask bundle           # release application
cargo xtask bundle --debug   # debug application
```

On macOS, open `target/release/bundle/blank_.app`, or `target/debug/bundle/blank_.app` for a debug build. The bundle contains the editor and its Typst compiler. Development runs use an optimized compiler alongside the debug editor.

## Editing

Launch opens a focused empty document, ready to write. Use ⌘1 / ⌘2 / ⌘3 for Write / Source / Preview, ⌘K for commands, ⌘⇧L for the collapsible heading outline, and ⌘S to save. Help → Tutorial opens an editable copy of [the original tutorial](examples/Tutorial.typ).

Write supports paragraphs, headings, simple lists, bold and italic, along with literal quotations, rectangular tables and image figures. Return continues a list; Return on an empty item exits it. At the start of a paragraph, `= `, `== ` and `=== ` create headings; `- ` and `+ ` create lists. `*bold*` and `_italic_` apply inline formatting.

Type `/` to open block commands beside the caret. Continue typing to filter, use arrow keys and Return to choose, or Escape to keep the literal text. Hover beside a block to reveal its handle; click for Turn into, Duplicate and Delete. ⌥↑ / ⌥↓ moves the current block.

Copying in Write preserves heading levels, list kinds and inline formatting when pasted back into the editor. Source displays every Typst character, with syntax colors, heading sizes and bold/italic markup. Copying in Source uses exact plain source text. Delimiters support basic pairing. Write and Source share undo/redo; custom expressions can be edited in Source.

Preview displays typeset pages. Compilation errors preserve the last successful preview. Export PDF requires a successful compilation of the current document; clicking preview text navigates to its source position.

Saved documents autosave after 650 ms of inactivity. An external file change blocks overwriting and offers Save As. Unsaved changes prompt before closing or replacing the document.

⌘F searches the active file, with case matching and replacement. Settings selects a system reading font, text size and page/text colors; statistics reports the active file's counts. Paragraph focus and typewriter scrolling are available through commands. New documents and tutorials open in separate windows when the current document contains text. Recovery journals retain unsaved source, included files and imported assets.

Literal `#include "chapter.typ"` files inside the project folder appear in the sidebar. Switching files retains each file's cursor and undo history; Preview compiles the project entry with in-memory chapter edits. Dragging a heading in the outline moves its section and nested contents among sibling headings.

The `/` menu includes dialogs for tables, images, quotations, links, footnotes, mathematics, labels and references. Supported literal tables expose editable cells and row/column controls; image figures expose caption and alternative-text fields. Other expressions remain editable in Source. Citation insertion connects to a running Zotero desktop app and maintains a local bibliography; live Zotero integration still needs validation.

## Architecture

The desktop interface uses eframe/egui and egui_richedit, with macOS menus through muda. `crates/document` owns the canonical Typst source and lossless syntax tree. Editable projections map visible characters to UTF-8 source spans; editing transactions patch ranges, incrementally reparse the tree and reproject a bounded neighborhood when safe, preserving unchanged source. Layouts are cached by paragraph identity, width and reading style. Other Typst expressions remain source objects in Write.

`crates/typst-helper` runs compilation, PDF export, page rendering and source mapping in a separate Rust process. Preview compilation runs on demand. Page rasterization is requested for visible pages, distant textures are evicted, and leaving Preview releases its retained typeset document.

### Text pipeline and library choice

Write uses **egui_richedit 0.7.0 with egui/epaint 0.36.2**. [epaint](https://docs.rs/epaint/0.36.2/epaint/) shapes text with HarfRust and uses Skrifa for font outlines and metrics; Parley is not a dependency. Paragraph galleys provide painting, caret positions, hit testing and selection geometry. The default macOS reading font is Iowan Old Style; Source uses Menlo. Their font collection bytes are loaded once and shared between faces. Other platforms try installed Georgia/Liberation/DejaVu faces before egui's bundled fallback fonts. Typst independently shapes and lays out Preview and PDF output.

Our `EditorModel` adapter implements `egui_richedit::Model`: text insertion, paragraph splitting and formatting are translated into transactions on the canonical Typst source. The library has no built-in Typst support. It handles editing interactions over paragraph layouts that the application supplies. This avoids a second editor-owned rich-document store and made it practical to test selection, lists, clipboard formatting and shared source undo while preserving unknown Typst.

This choice reduced integration work; its typography quality has not been compared with the alternatives. Shaping, paragraph layout and glyph rasterization are separate parts of the pipeline. Sharing HarfRust and Skrifa with Parley does not make the two pipelines equivalent. Font fallback, line breaking, baseline metrics and rendering quality still need a controlled visual comparison. Unicode shaping alone does not establish correct bidirectional navigation or screen-reader behavior; those require editor-level validation.

| Alternative | Evidence and tradeoff |
|---|---|
| [GPUI / GPUI Kit](https://gpui-kit.com/) | Official component/editor documentation reviewed. It has a substantial source editor and desktop component system; a lossless structured Typst editor would still need a custom document adapter. No equivalent application was built or benchmarked, so performance and platform support are not reasons to rule it out. |
| [text-document](https://github.com/FernTech-EU/text-document) | Version 1.12.5 was compiled and tested for Unicode cursor edits, change events, character formatting, tables and undo in `crates/library-assessment`. Its own rich-document store would require synchronizing with the canonical Typst tree and retaining opaque source. Its snapshot-based history uses a persistent rope; snapshots alone are not evidence of excessive memory use. It remains a viable alternative if its table/document model outweighs that integration cost. |
| [text-typeset](https://github.com/FernTech-EU/text-typeset) | Companion rendering library reviewed in upstream documentation; it was not compiled, rendered or benchmarked in this repository. The text-document tests are not evidence of its rendering quality. |
| [Parley](https://github.com/linebender/parley) | Official shaping, font fallback, rich layout and editing APIs reviewed. It is a text engine, not a complete desktop toolkit, and could coexist with egui. Integration would require replacing the current Galley painting, hit testing, caret/selection and accessibility geometry. Deferred, not rejected for poor typography; no rendering or memory comparison has been performed. |
| [Iced text_editor](https://docs.iced.rs/iced/widget/text_editor/index.html) | Official multiline editor and action APIs reviewed. Its supplied editor does not provide our structured Typst block model; rich display widgets are separate from rich editing. A custom editor and lossless adapter would still be required. No equivalent implementation or benchmark was performed. |

## Roadmap

- [x] Editable literal tables, image figures and quotations, with insertion dialogs.
- [x] Link, footnote, mathematics, label and reference insertion dialogs.
- [x] Citation search and bibliography storage through Zotero's local API.
- [ ] Validate citation insertion and bibliography refresh against a running Zotero library.
- [ ] Extend object editing to existing inline links/footnotes, image clipboard paste and image size/PDF-page controls; add object drag handles and insertion positions around objects.
- [x] Switch between literal included files with independent editing histories; move heading sections with their contents.
- [ ] Continuous editing across included files, include-based chapter reordering, and refreshing the include graph after edits.
- [ ] Preserve project dependencies and assets when using Save As; merge disjoint external changes.
- [x] Independent document windows and recovery journals containing project files and imported assets.
- [ ] Finish native multi-window validation, including the Window menu and accessibility in secondary windows.
- [x] Active-file search/replace, appearance settings, statistics, paragraph focus and typewriter scrolling.
- [ ] Project-wide search/statistics and consistent settings across open windows.
- [x] Grapheme-aware rich cursor movement/deletion and IME composition handling, covered by synthetic input tests.
- [ ] Validate native IME candidate windows, VoiceOver and bidirectional caret/selection behavior.
- [ ] Test Linux and Windows; macOS has been exercised.
- [x] Native macOS scrollers at the document viewport edge; other platforms use egui scrollers.
- [ ] Complete native scrollbar interaction checks in every view and secondary window.
- [x] Bounded incremental document projection for local edits and cached paragraph layouts.
- [ ] Reduce remaining document-wide scans, full undo reprojection and source-view layout work on large files.
- [x] Render preview pages on demand, evict distant page textures and release the retained typeset document after leaving Preview.
- [ ] Bound image-object texture caching and measure total editor/compiler memory on representative documents.
- [x] Store grouped undo/redo edits and selections; retain changed text rather than document snapshots, with a 200-step / 8 MiB payload budget (the latest operation is always kept).

Checked entries describe implemented behavior, not complete legacy feature parity. Native and integration validation remains open where listed. The bundled tutorial includes instructions for some features that are still pending.

## Development

`cargo xtask check` covers document transactions, actual egui input, source typography/copying, and the compiler protocol with PDF/PNG output and invalid-source diagnostics. Run it before submitting changes.

For compiler and source-model benchmarks:

```sh
cargo run -p writer-helper --example thesis_fixture
cargo build --release -p writer-helper
cargo run -p writer-helper --example benchmark
cargo run --release -p blank-document --example measure -- 1000
```

The isolated library evaluation runs with `cargo test --manifest-path crates/library-assessment/Cargo.toml --locked`. Dependencies retain their own licenses.
