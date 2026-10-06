# blank_

A quiet native macOS editor for [Typst](https://typst.app), built with SwiftUI and AppKit. Your documents stay ordinary local `.typ` projects.

![blank_ with a heading outline, formatted writing and a native table](Resources/Screenshots/editor.png)

- **Write, Source and Preview** — native rich text, exact source editing and typeset PDFs; shared undo and formatted clipboard.
- **Structured writing** — headings, lists, tables, figures, links, footnotes, citations and collapsible code blocks.
- **Navigation** — a movable outline, thumbnails, contact sheet and live search across project files.
- **Templates** — Standard, Thesis, Paper, Letter A4 and Book; preview, create, duplicate, edit or delete your own.
- **Native document tools** — PDF export/sharing, Zotero integration, statistics, recovery and macOS save/move controls.

New Document opens an empty editor. Find templates in **File → Templates…** or Cmd-K. Try the [Field notes](examples/Field%20notes.typ) sample.

## First launch

Releases are not notarized. If macOS blocks blank_, click **Done**, then **System Settings → Privacy & Security → Open Anyway**. Authenticate if asked, then click **Open**. [Apple’s instructions](https://support.apple.com/en-us/102445).

## Development

Requires macOS 26+, Swift 6 with a macOS 26/27 SDK, Rust 1.98.1 (pinned) and Python 3.

```sh
bash scripts/build.sh release  # omit release for debug
open build/blank_.app
bash scripts/check.sh
```

Both builds update the same app; quit and reopen after rebuilding. Checks cover the document model, compiler, native editing/files and a relocated bundle; native checks need an unlocked desktop session.

The Cargo workspace shares a lockfile/cache for the in-process parser and separate PDF compiler, both using Typst 0.15.1. See [AGENTS.md](AGENTS.md) for architecture and build conventions.

[CI](.github/workflows/build-macos.yml) checks pushes and pull requests on macOS 26/27. Publishing a `vX.Y.Z` release attaches the Apple Silicon app and checksum after both builds pass. Apps are ad-hoc signed; Intel support is unverified.

## Remaining work

- Rich controls for editing existing links, footnotes, citations and figures; PDF-page selection and broader image-format validation.
- Zotero group discovery, citation-picker keyboard navigation and custom CSL styles.
- Continuous editing across included files and repeated includes.
- Settings synchronization, disjoint external-change merging and broader recovery checks.
- Large-table and Source performance; long-document memory/latency measurements.
- Opt-in MCP/agent access with revision-checked transactions and selective undo.

Live Zotero, physical IME candidates, bidirectional editing, VoiceOver and Writing Tools remain unverified. An empty-editor release run measured 0.14% of one CPU core and 14.5 MiB RSS; compiler memory was excluded. Use `--measure` with disposable `BLANK_DATA_DIR` data.

[MIT](LICENSE) · Built with OpenAI Codex.
