# Native acceptance

## Architecture and interface assessment

The macOS 27 SDK's attributed `TextEditor` accepts `Binding<AttributedString>` and optional `Binding<AttributedTextSelection>` (macOS 26+), including typing attributes and transformations. NSTextView is chosen because this editor needs pre-edit delegates, marked-text hooks, caret rectangles, custom clipboard handling and block mouse tracking. The deployment target is macOS 26; compatibility with older macOS is not a reason for this choice.

`NSTextView(usingTextLayoutManager: true)` explicitly requests TextKit 2. Geometry uses native character rectangles and insertion-position hit testing, without querying NSLayoutManager or falling back to TextKit 1. Acceptance checks verify that TextKit 2 stays active through view switches, composition, tables and figures.

On this SDK, attachment providers were requested for bounds but their views were not mounted by NSTextView. The implementation therefore reserves native attachment geometry and mounts visible AppKit table/figure controls as text-view subviews. Offscreen controls are removed, except the active table editor. Generated or complex tables stay source blocks. This is a tested compatibility workaround, not an assertion that every NSTextAttachment feature works in TextKit 2.

The toolbar is a standard customizable NSToolbar with unified window layout and macOS 27 tab-role view selection. Full-size content and a transparent titlebar let scrolling content extend beneath it; native scrolling supplies its automatic edge treatment. No custom toolbar glass or white titlebar background is drawn. Controls follow system appearance by default. Write retains native spelling/substitution preferences, including changes made through native controls; Source disables prose substitutions and restores those preferences when returning to Write. Standard Services and represented-document title behavior are included. Document page/font colors remain writing preferences. Large Go-style paragraph metrics have been replaced with native font metrics, moderate line spacing and spacing before paragraphs, avoiding inflated insertion-caret height.

Apple references: [TextKit](https://developer.apple.com/documentation/appkit/textkit), [NSTextView](https://developer.apple.com/documentation/appkit/nstextview), [AppKit's new design](https://developer.apple.com/videos/play/wwdc2025/310/), [transparent titlebars](https://developer.apple.com/documentation/appkit/nswindow/titlebarappearstransparent), [adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass). The system controls adapt to accessibility transparency/motion preferences; those configurations still need visual acceptance.

## Automated checks

Host: Apple Silicon, macOS 27.0.1, Swift 6.4, Rust 1.98.1, Typst 0.15.1. Checks run on 2026-10-04 using disposable documents. The existing Rust/Go branches and user files were preserved.

- Pinned parser/compiler builds pass offline; debug and release application builds pass ad-hoc signature verification.
- Nineteen standalone production-model checks pass: Unicode mappings/patch inverses, source preservation, formatting toggles and typing inside words, list continuation/exit, paragraph joining, structured clipboard, history/selections, consecutive code, section movement, incremental whitespace and local/full projection equivalence, literal includes/prose statistics, byte-preserving include moves, conditional include boundaries and syntax-based literal dependencies that ignore commented examples.
- Native acceptance passes focused empty launch, scalar-by-scalar Unicode typing, Return, selection/formatting, structured/plain clipboard, exact Source copying, shared view-switch undo/redo, synthetic Japanese marked-text composition, bold typing on/off, Go's typed heading/formatting shortcuts and literal Source delimiters/indentation. Source renders explicit strong/emph functions with real font faces and grows headings while retaining every character. Slash-menu rows, caret geometry and single-transaction choice undo pass.
- Native table fields mount in the real document window, update source with Unicode, retain native cell focus through shared Undo/Redo and add a valid row after the final cell. Native figures render in NSImageView while retaining TextKit 2.
- The official compiler produces PDF/source maps. Errors retain the prior PDF; export requested during compilation includes a native imported figure and caption. The page counter follows direct PDFKit navigation in a two-page fixture, using the same notification as wheel/trackpad page changes; physical wheel acceptance remains pending. The exact tutorial compiles to two pages. Nested includes, links, footnotes, tables, math and Unicode pass the compiler protocol check.
- Disposable project checks pass include/import loading, exact UTF-8 saves, overlap rejection, deletion/recovery, rename/history retention, Save As dependencies/configuration and preflight collision rejection, nested-chapter asset paths, live includes, directory creation events and chapter undo/redo. Imports remain outside the expanded manuscript; Save As ignores commented asset examples and accepts project configuration with non-string values.

The CLT environment lacks XCTest; `BlankCoreChecks` exercises the production model directly. The SDK's SwiftUI State macro lacks a CLT plugin; `NativeState` aliases the stable property wrapper.

## Native inspection

The isolated native app was inspected through real macOS keyboard input. Cmd-1/Cmd-2 changed the toolbar's selected tab and restored editor focus. Exact Source insertion followed by Write displayed Japanese, emoji, heading sizes and real bold/italic faces. The ordinary keyboard automation tool did not inject Japanese characters through `typeText`; clipboard insertion and synthetic marked-text checks succeeded. This does not validate a real IME candidate-panel session.

Native tutorial scrolling visibly placed text behind the glass controls, with the scrollbar at the viewport edge. A fresh document confirmed the corrected caret height and paragraph rhythm. Real slash filtering and Down/Return choice passed. Manual inspection found a collapsed popover; constraining its hosted root height fixes the missing visible rows. Pointer drag, VoiceOver and bidirectional input require expanded acceptance. Track remaining functionality separately in [parity.md](parity.md).

## Resource measurements

Measured using the production `--measure` harness in a release build. These are short local observations, not targets or a whole-thesis benchmark. RSS is the editor process only; compiler process memory is excluded.

| Measurement | Observed |
|---|---|
| Empty editor, five seconds idle | 0.006 CPU seconds, 0.12% of one core; 72.6 MiB RSS |
| 100 paragraphs / 9,988 source bytes | Load 20.7 ms; local edit median 0.8 ms, max 1.3 ms |
| 1,000 paragraphs / 100,888 source bytes | Load 91.4 ms; local edit median 2.7 ms, max 3.0 ms; 114.6 MiB RSS |
| 1,000-paragraph native key transaction, ten edits | Median 9.7 ms, max 12.9 ms; 128.0 MiB RSS |

The measurements include the toolbar/paragraph/statistics, live-include and native input-preference refinements. Different runs have different font/window warm-up and resident-memory states; these values are observations, not guaranteed limits. The key metric includes the synchronous native edit/model/attribute update; it excludes complete display presentation and physical key-to-screen latency. Edits in the model measurement retained ten bytes of changed text in history. Full structural parsing, Source styling and undo reprojection still scale with document length.

The compiler protocol check observed 0.705 s cold for the two-page tutorial and 0.160 s warm for a smaller edited fixture; these exclude PDFKit presentation. Representative thesis files, long sessions, memory pressure, image-heavy projects and total compiler/editor RSS remain to be measured. To reproduce the editor harness, launch the built app with `--measure` and a disposable `BLANK_DATA_DIR`.
