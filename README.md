# blank_

A quiet native macOS editor for [Typst](https://typst.app), built with SwiftUI and AppKit. Your documents stay ordinary local `.typ` projects.

![blank_ with a heading outline, formatted writing and a native table](Resources/Screenshots/editor.png)

- **Write, Source and Preview** — native rich text, exact source editing and typeset PDFs; shared undo and formatted clipboard.
- **Structured writing** — headings, lists, tables, figures, links, footnotes, formatted citations/bibliographies and collapsible code blocks.
- **Navigation** — a movable outline, thumbnails, contact sheet and live search across project files.
- **Templates** — Standard, Thesis, Paper, Letter A4, Book and Slides (16:9 projector); preview, create, duplicate, edit or delete your own.
- **Native document tools** — PDF export/sharing, Zotero integration, statistics, recovery and macOS save/move controls.

Citation search filters while you type. The document’s style controls formatting; Citation display chooses a standard citation, one within a sentence, author only or year only. Write shows Typst’s formatted citations and bibliography, while Source retains their exact expressions. New insertions consistently use `#cite`.

New Document opens an empty editor. Empty writing blocks show subtle hints; headings and lists apply their formatting before typing. Backspace at the start of a heading/list removes its formatting. Delete toward an adjacent table selects it; a second Delete removes it, and Undo restores it. Find templates in **File → Templates…** or Cmd-K. Try the [Field notes](examples/Field%20notes.typ) sample.

## Projects and references

**New Document** stays empty. **File → New Project…** creates a dedicated folder containing only an empty `main.typ`. Projects are ordinary Typst folders, with no entry manifest. Opening a `.typ` selects it for compilation; opening a folder uses its remembered entry or a single document that is not included/imported by another file, otherwise a native panel lets you choose. Selections are stored in the app’s data directory. A directly opened file uses its parent as the root unless it belongs to a folder previously opened as a project.

Includes and imports keep their names and structure. Relative paths resolve from the referring file; `/…` resolves from the project root. Adding a literal chapter include creates its empty `.typ` automatically. Existing missing/unreadable files are reported rather than overwritten. Packages must already be cached or vendored in `packages/`.

Zotero insertion uses the document’s declared bibliography, including external BibLaTeX `.bib` and Hayagriva `.yaml`/`.yml`. Multiple inputs offer a destination choice. The app never attaches bibliographies merely because they share a folder. Without a bibliography, the first import embeds readable BibLaTeX in the document using Typst’s `bibliography(bytes(...))` input; independent documents can share a folder without generated reference-file collisions. There is no `writer-references.json` or beta-storage migration.

Zotero item keys, library identifiers (`users/…` or `groups/…`) and the exported field list live in `x-blank-zotero-*` metadata alongside each entry. **Refresh Zotero References** is manual: it retains citation keys, changes only linked entries and keeps unrelated entries, comments, macros and custom fields. Citation insertion and refresh use canonical range history; cross-file insertion undoes the citation and bibliography together. Write uses Typst’s formatted citations/bibliographies; Source keeps the complete editable expressions. **Bibliography style** accepts standard style names or a custom CSL file.

Save As preflights dependency collisions and copies literal dependencies plus files read by a background Typst evaluation. A nested entry’s literal paths are rebased; when computed paths require their original location, an ordinary `.typ` include wrapper keeps the original entry and folder structure intact. Unreached computed dependencies cannot be discovered automatically. Computed raw-byte bibliography data and package-owned bibliographies remain editable in Source but are not rewritten by Zotero. Hayagriva Zotero edits require block mappings; flow mappings/aliases still compile and remain source-editable.

Checks cover external projects, nested/root paths, embedded/external references, Zotero refresh with isolated responses, custom CSL, assets, Unicode, selection/clipboard, Undo and Save As. Compiler checks compare reference presentation with and without the metadata fields. These checks do not establish live Zotero coverage.

## Download

Download the last release from https://github.com/gagarine/blank_/releases (no auto-update yet)

⚠️ Releases are not notarized. If macOS blocks blank_, click **Done**, then **System Settings → Privacy & Security → Open Anyway**. Authenticate if asked, then click **Open**. [Apple’s instructions](https://support.apple.com/en-us/102445).

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
- Zotero group discovery and citation-picker keyboard navigation. Custom citation show rules and note-style footnote presentation in Write remain unverified.
- Continuous editing across included files and repeated includes.
- Settings synchronization, disjoint external-change merging and broader recovery checks.
- Large-table and Source performance; long-document memory/latency measurements.
- Opt-in MCP/agent access with revision-checked transactions and selective undo.

Live Zotero, physical IME candidates, bidirectional editing, VoiceOver and Writing Tools remain unverified. An empty-editor release run measured 0.14% of one CPU core and 14.5 MiB RSS; compiler memory was excluded. Use `--measure` with disposable `BLANK_DATA_DIR` data.

[MIT](LICENSE) · Built with OpenAI Codex.
