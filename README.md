# blank_

A quiet native macOS editor for [Typst](https://typst.app). Write, Source and PDF Preview share ordinary local `.typ` files. SwiftUI/AppKit interface with native typography, integrated text tables and the official Typst compiler. The editor uses the native macOS system font by default and installed fonts only; PDF compilation includes Typst’s standard bundled fonts.

Supports block editing and dragging, sidebar contents/thumbnails with an order lock, a full-window zoomable contact sheet in all three views, collapsible code, inline table row/column menus, shared undo, formatted clipboard, figures/captions, links, footnotes, citations with Zotero, included files/chapter movement, live document/project search, statistics, settings, document windows and recovery. Generated or complex Typst stays editable in Source.

**File → Templates…** (also Cmd-K) opens a thumbnail library with Standard, Thesis, Paper, Letter A4 and Book. Create independent documents, preview, add, duplicate, edit or trash templates; Save in a template editor updates the library. **Save as Template…** captures the current project. New Document remains empty.

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
