# blank_

A quiet native macOS editor for [Typst](https://typst.app). Write, edit source and preview typeset PDFs in a SwiftUI/AppKit interface, using ordinary local `.typ` projects.

Native typography and tables, structured block editing, collapsible code, an outline and page thumbnails, shared undo, formatted clipboard, figures, links, footnotes, Zotero citations, live search and recovery. Complex Typst stays editable in Source. Try the [Field notes](examples/Field%20notes.typ) sample.

**File → Templates…** (also Cmd-K) offers Standard, Thesis, Paper, Letter A4 and Book. Preview, add, duplicate, edit or trash templates; Save updates an edited template. **Save as Template…** captures the current project. New Document stays empty.

## First launch

Current releases are not notarized. If macOS blocks the app:

1. Click **Done** in the warning.
2. Open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway** for blank_.
3. Authenticate if asked, then click **Open**.

See [Apple’s instructions](https://support.apple.com/en-us/102445).

## Development

Requires macOS 26+, Swift 6 with a macOS 26/27 SDK, Rust 1.98.1 (pinned) and Python 3 for checks.

```sh
bash scripts/build.sh release  # omit release for debug
open build/blank_.app
bash scripts/check.sh
```

The root Cargo workspace shares `Cargo.lock` and `target/` between the in-process `typst-syntax-bridge` library and the separate `typst-compiler` executable; Typst is pinned to 0.15.1.

Both configurations update `build/blank_.app`; quit and reopen after rebuilding. Checks cover the document model, official compiler, native editing/file behavior and a relocated app bundle. Native checks require a logged-in desktop session. See [AGENTS.md](AGENTS.md) for architecture and development conventions.

[GitHub Actions](.github/workflows/build-macos.yml) tests pull requests and pushes on macOS 26 and 27. Publishing a release tagged `vX.Y.Z` (prerelease suffixes supported) builds that commit and attaches `blank_-macos-arm64.zip` and `SHA256SUMS` after both jobs pass. Builds are ad-hoc signed and not notarized; Intel support remains unverified.

## Remaining work

- Refine existing link/footnote/citation editing and figure size, alternative text and PDF-page controls; validate SVG, multipage PDFs and clipboard/drop formats.
- Validate live Zotero integration; add group-library discovery, citation-picker keyboard selection and custom CSL styles.
- Continuous editing across included files and repeated includes; improve chapter navigation and manuscript search/counting across file boundaries.
- Synchronize settings across windows; validate window lifetime, long-document scrolling/dragging, real IME candidate panels, international keyboards, bidirectional selection, VoiceOver and Writing Tools.
- Merge disjoint external changes; broaden relaunch, disk-full and abrupt-termination recovery checks.
- Optimize large-table editing and full Source reprojection; measure total editor/compiler memory on long and image-heavy documents.
- Opt-in per-window MCP/agent access with revision-checked multi-file transactions and selective agent undo.

Live Zotero, real IME candidates, bidirectional editing and VoiceOver remain unverified. One Apple Silicon release run on macOS 27 measured 0.14% of one core over five seconds with an empty editor and 14.5 MiB RSS; 100-row table key transactions took about 55 ms. Compiler memory and physical key-to-screen latency were excluded. Reproduce with the app's `--measure` option and a disposable `BLANK_DATA_DIR`.

[MIT](LICENSE) · Built with OpenAI Codex.
