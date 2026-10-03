# Native Rust prototype

The Rust desktop application on `codex/rust-native-prototype`. No JavaScript, embedded browser or Qt. The earlier Go/Wails implementation is preserved on `codex/legacy-go`.

```sh
scripts/dev.sh --demo
scripts/build.sh         # build/bin/blank-native.app on macOS
scripts/build.sh --debug # faster iteration
scripts/check.sh
```

The first build downloads dependencies. Subsequent checks can use Cargo's `--offline` flag. The build scripts use the repository-local Rust/Cargo setup.

## Current behavior

The white writing surface, muted green selection, left contents sidebar and Write / Source / Preview workflow follow the existing application, using egui components with quiet typography and popup styling. macOS uses real AppKit menus via muda; there is no duplicated in-window toolbar. Other platforms have an egui menu bar.

- File: new/open Typst, save, save as, export PDF, close. Existing files autosave after 650 ms of inactivity. Changes on disk block overwriting; Save As preserves your work. Unsaved new documents prompt before replacement or closing.
- View: Write (Cmd-1), Source (Cmd-2), Preview (Cmd-3), sidebar (Cmd-Shift-L), refresh, zoom.
- Edit / Format: shared undo/redo across views, clipboard operations, bold/italic, paragraphs, headings 1–3, bullet and numbered lists.
- Cmd-K opens a searchable command picker. Typing `/` at the writing caret opens the block picker. Arrow keys, Enter and Escape work; dismissing `/` retains a literal slash. These pickers currently expose the prototype's supported commands, not all of the original app's insertion dialogs.
- Hover block dots support dragging, Turn into, Duplicate and Delete; Option-Up/Down moves blocks. Return continues lists, and an empty list item exits on Return. Typst heading/list and bold/italic typing shortcuts are supported.
- Source is a full-area syntax-colored editor with basic delimiter pairing. Switching views preserves an approximate reading/caret position. Sidebar headings navigate in each view. Clicking preview text chooses the nearest source anchor.
- Preview uses the existing Rust Typst helper to render PDF and PNG pages, with stale-result rejection and source diagnostics.

## Document model

`crates/document/` is GUI-independent. A lossless Typst syntax tree and exact source text are canonical. Editable paragraph projections map individual visible characters to UTF-8 source spans. GUI transactions patch the affected range and incrementally reparse it; unchanged source remains byte-for-byte intact. Both views share history.

Headings, ordinary paragraphs, simple lists and bold/italic spans are editable. Unknown expressions, equations, references, raw text and custom Typst retain source-backed opaque representations. Deleting across opaque blocks is refused. Formatting newly changed spans uses explicit `#strong[…]` and `#emph[…]` to avoid Typst's delimiter word-boundary ambiguities. Temporary invalid source remains editable and saveable.

This preserves the user's Typst rather than regenerating a document on every edit. It does not yet provide a complete semantic model for every Typst program.

## Performance and iteration measurements

Measurements on this development Mac, cached dependencies, not a controlled cross-toolkit benchmark:

| Check | Observed |
|---|---:|
| Warm debug edit/build | roughly 3–4 seconds |
| Warm release edit/build (thin LTO) | roughly 19–30 seconds |
| Release application build, compiled dependencies initially uncached | 106 seconds |
| Release app executable + compiler executable | about 63 MiB on disk |
| 1,000 paragraphs / 94 kB, core load | 3.63 ms |
| Same, core edit p50 / p95 | 2.13 / 2.87 ms |
| 10,000 paragraphs / 949 kB, core load | 46.99 ms |
| Same, core edit p50 / p95 | 27.46 / 65.29 ms |

Core timing includes the source patch, incremental parser and rebuilding the paragraph projection; it excludes GUI layout and Typst compilation. Reproduce with:

```sh
source scripts/env.sh
cargo run --release --manifest-path crates/document/Cargo.toml --locked --example measure -- 1000
cargo test --manifest-path tools/library-assessment/Cargo.toml --locked
```

A real idle redraw bug was found: sending the Cocoa window title on every frame caused a feedback loop. Before the fix the debug tutorial window consumed approximately 45–52% CPU. Caching title changes brought the sampled debug Write window to approximately 3.6% CPU; that intermediate build still occupied about 132 MiB of physical memory. Those are intermediate measurements, not the final release numbers.

Additional fixes: Write and Source do not compile/rasterize previews; leaving Preview drops page textures. PDF export requests PDF without raster images. Compilation completion wakes the GUI instead of polling the worker; autosave uses a deadline rather than a repeating timer. Native menu properties are only updated when their values change. The caret stops blinking after four seconds of inactivity and resumes on input.

Compare complete process trees, using the same Activity Monitor metric. The user's screenshot shows 38.6 MB for the Go main process, plus 155.9 MB for its WebView and 25.2 MB for its graphics process. The screenshot cannot establish either implementation's complete total or steady-state workload.

## Library assessment

| Candidate | Evidence checked | Fit and recommendation |
|---|---|---|
| eframe/egui + egui_richedit 0.7.0 | Implemented, compiled, exercised real input and actual macOS windows | Best current prototype fit: fast iteration, default controls, editor transactions target our own model. Production choice remains provisional. |
| GPUI + gpui-component 0.7 | Source and documented Editor/TextView APIs inspected; not built or benchmarked | Strong source editor and retained UI. Its rich TextView displays formatted content; it does not remove the need for a structured WYSIWYG editor. Worth a second GUI spike if egui's input/layout limits become blocking. |
| text-document 1.12.5 + text-typeset | text-document built in isolated `tools/library-assessment/`; two tests cover Unicode cursors/change events/undo and formatting/table undo. Companion typesetter docs inspected, not integrated | Promising richer structure and table ecosystem. No Qt runtime dependency despite Qt-inspired API. Would need a lossless Typst adapter. Baseline model pulls in substantial import/export dependencies: 212 resolved packages in this isolated test. |
| Parley 0.11.1 | Source and official docs inspected | Strong shaping/layout foundation and basic plain editor; a structured editing UI, tables and source adapter still have to be built. Good candidate for future typography and multilingual input work. |
| Iced text_editor | Official API inspected | Useful default multiline source editor; no ready-made structured document editor established in this assessment. Changing toolkit alone does not solve the rich editor model. |

Sources: [egui_richedit](https://docs.rs/egui_richedit/0.7.0/egui_richedit/), [GPUI Editor](https://github.com/longbridge/gpui-component/blob/main/website/docs/components/editor.md), [GPUI TextView](https://docs.rs/gpui-component/0.7.0/gpui_component/text/struct.TextView.html), [text-document](https://github.com/FernTech-EU/text-document), [text-typeset](https://github.com/FernTech-EU/text-typeset), [Parley](https://github.com/linebender/parley), [Iced text_editor](https://docs.iced.rs/iced/widget/text_editor/index.html), [muda](https://docs.rs/muda/0.21.0/muda/).

Recommendation: retain the isolated source-backed core and use this egui implementation to validate the workflow. Before choosing the production GUI, test multilingual text, IME, accessibility and large documents against a retained/layout alternative. The isolated text-document tests are an assessment, not a replacement for the preservation-oriented core.

## Remaining work

This is a working prototype, not feature parity. Structured tables, figures, citations/Zotero, footnotes, links, chapter management, insertion dialogs, source search, preferences and recovery/session persistence remain to port.

The rich editor needs grapheme-aware navigation, IME preedit composition and broader accessibility verification. Paragraph projections and layout still scan the whole document; preview rasterizes all pages eagerly when requested. Virtualized layout, page rendering on demand and bounded compiler/font caches are needed for long documents. Current undo stores up to 200 source snapshots. The first optimized compiler build after consolidating the workspace took 3m 55s; that is a one-time dependency build, separate from warm UI iteration. Only macOS has been exercised; Linux/Windows compilation and native behavior still need validation.
