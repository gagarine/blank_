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

Write supports paragraphs, headings, simple lists, bold and italic. Return continues a list; Return on an empty item exits it. At the start of a paragraph, `= `, `== ` and `=== ` create headings; `- ` and `+ ` create lists. `*bold*` and `_italic_` apply inline formatting.

Type `/` to open block commands beside the caret. Continue typing to filter, use arrow keys and Return to choose, or Escape to keep the literal text. Hover beside a block to reveal its handle; click for Turn into, Duplicate and Delete. ⌥↑ / ⌥↓ moves the current block.

Copying in Write preserves heading levels, list kinds and inline formatting when pasted back into the editor. Source displays every Typst character, with syntax colors, heading sizes and bold/italic markup. Copying in Source uses exact plain source text. Delimiters support basic pairing. Write and Source share undo/redo; custom expressions can be edited in Source.

Preview displays typeset pages. Compilation errors preserve the last successful preview. Export PDF requires a successful compilation of the current document; clicking preview text navigates to its source position.

Saved documents autosave after 650 ms of inactivity. An external file change blocks overwriting and offers Save As. Unsaved changes prompt before closing or replacing the document.

## Architecture

The desktop interface uses eframe/egui and egui_richedit, with macOS menus through muda. `crates/document` owns the canonical Typst source and lossless syntax tree. Editable projections map visible characters to UTF-8 source spans; editing transactions patch ranges and incrementally reparse the tree while preserving unchanged source. Other Typst expressions remain source objects in Write.

`crates/typst-helper` runs compilation, PDF export, page rendering and source mapping in a separate Rust process. Preview compilation runs on demand, and leaving Preview releases page textures.

The current GUI was selected for editor transactions and fast iteration. Alternatives assessed:

| Library | Findings |
|---|---|
| GPUI + gpui-component | Source editor and retained GUI APIs inspected; a structured rich editor would still need its own model. |
| text-document + text-typeset | Unicode editing, formatting, tables and undo tested in `crates/library-assessment`; integration would require a lossless Typst adapter. |
| Parley | Shaping/layout and plain-editor APIs inspected; a possible foundation for typography improvements. |
| Iced text_editor | Plain multiline editor API inspected; rich editing would require additional model and UI work. |

References: [egui_richedit](https://docs.rs/egui_richedit/0.7.0/egui_richedit/), [GPUI Editor](https://github.com/longbridge/gpui-component/blob/main/website/docs/components/editor.md), [text-document](https://github.com/FernTech-EU/text-document), [Parley](https://github.com/linebender/parley), [Iced text_editor](https://docs.iced.rs/iced/widget/text_editor/index.html).

## Roadmap

- [ ] Structured tables, figures and images.
- [ ] Citations, footnotes and link dialogs.
- [ ] Multi-file rich editing and chapter movement.
- [ ] Multiple windows and recovery.
- [ ] Search, settings and statistics.
- [ ] Validate native pointer dragging, IME, VoiceOver and grapheme-aware rich cursor movement.
- [ ] Test Linux and Windows; macOS has been exercised.
- [ ] Native scrollbar integration; egui currently draws the scrollbar.
- [ ] Incremental document projection and layout; both currently scan the document.
- [ ] Render preview pages on demand; rasterization currently processes all pages.
- [ ] Reduce undo memory use; history currently retains up to 200 source snapshots.

The bundled tutorial includes instructions for some features on this roadmap.

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
