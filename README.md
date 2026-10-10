# blank_

A quiet native macOS editor for [Typst](https://typst.app), built with SwiftUI and AppKit. Documents stay ordinary local `.typ` projects.

![blank_ with a garden photograph, heading outline, inline formatting and color palettes](Resources/Screenshots/editor.jpg)

## Download

Get the [latest release](https://github.com/gagarine/blank_/releases) for Apple Silicon and macOS 26+. Automatic updates are not available yet.

Releases are not notarized. If macOS blocks blank_, click **Done**, then **System Settings → Privacy & Security → Open Anyway**. [Apple’s instructions](https://support.apple.com/en-us/102445).

## Writing

- **Write, Source and Preview** — native rich text, exact Typst source and typeset PDFs, with shared Undo and formatted clipboard.
- **Blocks** — headings, lists, native tables, figures, footnotes, citations, bibliographies and collapsible Typst source. Displayed code blocks and inline code are also supported.
- **Text styles** — bold, italic, underline, strikethrough, links, text/highlight colors and superscript/subscript. Select text to open the formatting panel; alignment and block styles apply to the whole block.
- **Navigation** — movable heading outline, thumbnails, contact sheet and live project search.
- **Document tools** — PDF export/sharing, statistics, recovery and native macOS save/move controls.
- **Templates** — Standard, Thesis, Paper, Letter A4, Book and Slides, plus your own editable templates.

New Document opens an empty editor. Use `/` for blocks and objects, **⌘K** for commands, and **⌘1 / ⌘2 / ⌘3** for Write / Source / Preview. The same commands appear in **Format** and **Insert**. Block handles show the current type, conversion choices and exact-source editing. Try [Field notes](examples/Field%20notes.typ) or **Help → Tutorial**.

Links stay selectable in Write; hover to open or remove them. Click gray citation fields to edit them. **Code** inserts executable Typst source with syntax colors and protected outer delimiters; **Code block** inserts a displayed code example. Source exposes every character. Edits preserve surrounding comments and custom expressions.

## Projects and references

Open a `.typ` file or a project folder. Folders remember their entry document or offer a choice. **File → New Project…** creates a folder with an empty `main.typ`. Includes, imports and assets retain their structure; packages must already be cached or vendored in `packages/`.

Unnamed documents save privately while you write. **Reopen unsaved documents on launch** in Settings restores drafts, files, assets, view and selection. Close and Quit use native macOS save review; explicitly discarded documents do not reopen. Save chooses a normal `.typ` location. Undo history starts afresh after relaunch.

Save and Save As protect against external changes and dependency collisions. Save As copies discovered dependencies and adjusts literal paths when needed; unreached computed dependencies cannot be discovered automatically.

Zotero insertion uses the declared BibLaTeX or Hayagriva bibliography, or embeds BibLaTeX when none exists. Already-cited references appear first and can be reused locally. Typst supplies citation/bibliography formatting, including custom CSL styles. **Refresh Zotero References** updates linked entries while retaining citation keys and unrelated data. **Convert Bibliography…** moves between embedded/external BibLaTeX and supported Hayagriva inputs. Computed inputs remain editable in Source.

## Development

Requires Swift 6 with a macOS 26/27 SDK, Rust 1.98.1 (pinned) and Python 3.

```sh
bash scripts/build.sh release  # omit release for debug
open build/blank_.app
bash scripts/check.sh
```

Both builds update the same app; quit and reopen after rebuilding. Checks cover the document model, official Typst compiler, native editing/files and a relocated bundle. Native checks need an unlocked desktop session and use disposable data.

The Rust parser and separate PDF compiler share a Cargo workspace, lockfile and cache, using Typst 0.15.1. See [AGENTS.md](AGENTS.md) for architecture, build and verification conventions.

[CI](.github/workflows/build-macos.yml) checks macOS 26/27. Publishing a `vX.Y.Z` release attaches the Apple Silicon app and checksum after both builds pass. Apps are ad-hoc signed; Intel support is unverified.

## Remaining work

- Rich controls for footnotes, complex citations and custom figures; PDF-page selection and broader image-format validation.
- Zotero group discovery and citation-picker keyboard navigation.
- Continuous editing across included files and repeated includes.
- Settings synchronization, disjoint external-change merging and broader recovery checks.
- Large-table/Source performance and long-document resource measurements.
- Opt-in MCP/agent access with revision checks and selective undo.

Live Zotero, physical IME candidates, bidirectional editing, VoiceOver and Writing Tools remain unverified, as do custom citation show rules and note-style footnotes in Write.

[MIT](LICENSE) · Built with OpenAI Codex.
