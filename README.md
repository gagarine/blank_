# blank_

A quiet native macOS editor for [Typst](https://typst.app), built with SwiftUI and AppKit. Your documents stay ordinary local `.typ` projects.

![blank_ with a heading outline, formatted writing and a native table](Resources/Screenshots/editor.png)

- **Write, Source and Preview** — native rich text, exact source editing and typeset PDFs; shared undo and formatted clipboard.
- **Structured writing** — headings, lists, tables, figures, links, footnotes, formatted citations/bibliographies and collapsible code blocks.
- **Navigation** — a movable outline, thumbnails, contact sheet and live search across project files.
- **Templates** — Standard, Thesis, Paper, Letter A4, Book and Slides (16:9 projector); preview, create, duplicate, edit or delete your own.
- **Native document tools** — PDF export/sharing, Zotero integration, statistics, recovery and macOS save/move controls.

**Format** and the text’s **Font** context menu offer Bold, Italic, Underline (⌘U) and Strikethrough. Styles combine, toggle on selected text or subsequent typing, and work in native table cells. Underline and Strikethrough use Typst’s `#underline[…]` and `#strike[…]`; Write renders native text decorations, and Source retains the complete expressions. Structured clipboard and RTF paste preserve these styles, with shared Undo across views.

Selecting editable text in Write opens a native style panel beside the selection without taking the caret’s focus. It uses the same popover style as slash and handle menus, with hover-only button backgrounds and pointing-hand cursors. It offers supported whole-block conversions, Bold/Italic/Underline/Strikethrough, inline code, links, text and highlight palettes, and superscript/subscript. Colors open as visible text/highlight swatches in one panel, with Default/None choices. Alignment applies to whole blocks; **Default alignment** removes explicit alignment, and justification is available for paragraphs. The same additions appear in **Format**. Links stay ordinary selectable text in Write; clicking places the caret instead of opening a destination. Hovering reveals a native panel with the URL, **Open Link** and **Remove Link**. Removal preserves the text, inline formatting and native selection, including table cells. Selected links also use a native URL sheet with Apply and Remove Link. Panel actions use canonical source/history and work in native table cells; block conversion is omitted in cells.

**Code block** in `/`, Format, the handle menu, or the selection panel turns the whole block into a displayed Typst raw-code example. Write shows literal code in monospace and keeps Return inside it; source fences and language tags survive ordinary edits. Inline code is a separate style. The existing **Code** command still inserts executable Typst source. Source exposes every character of both forms. Colors, links, super/subscript and alignment compile through standard Typst functions. Structured clipboard retains their source; external RTF import currently preserves bold/italic/underline/strikethrough only.

Citation search filters while you type. References already cited in the project appear first with an **Already cited** marker and can be reused without contacting Zotero. Inline citations have a subtle gray background; click to edit their reference, locator and display. Rich or computed citations retain an exact-source editor. The document’s style controls formatting; Citation display chooses a standard citation, one within a sentence, author only or year only. Write shows Typst’s formatted citations and bibliography, while Source retains their exact expressions. New insertions consistently use `#cite`.

Slash commands also appear in the macOS **Format** (paragraph styles) and **Insert** (objects) menus. **Code** creates an empty collapsible Typst source block with the caret inside. Write colors its Typst syntax, keeps Return inside the block with indentation, and protects its outer `#{` / `}` from partial edits; select the whole block to delete it. Source permits editing every delimiter. Code input disables prose substitutions and restores them when returning to prose.

Cross-reference insertion offers existing literal labels from the project, including unsaved edits, and accepts custom targets. Computed and package-created labels can be entered by name. New references use explicit `#ref` calls so label names and adjacent prose remain separate.

Write gives literal labels such as `<intro>` a subtle gray background. They stay ordinary editable text and copy with their existing source; the background is display-only. Find temporarily highlights matches in yellow. Source keeps its existing syntax styling.

Image figures with literal paths, plain captions and integer widths from 5–100% offer the insertion controls when double-clicked or edited through their block menu. Apply changes only the edited values; comments and custom options stay intact. Choose image stages a replacement until Apply, and Undo retains both image assets. **Edit source…** remains available; computed paths, rich captions and unsupported widths open the exact-source editor. Width affects the typeset PDF; Write retains its existing figure sizing.

Every Write block handle identifies its current type and shows supported **Turn into** choices directly, omitting the current type. It also offers **Edit source…**, including prose, native tables and folded code. The sheet edits that block’s exact Typst source, preserving surrounding source and sharing Write/Source Undo. Table controls and **Edit image…** remain available.

New Document opens an empty editor. Empty writing blocks show subtle hints; headings and lists apply their formatting before typing. Backspace at the start of a heading/list removes its formatting. Delete toward an adjacent table or folded/expanded code block selects it; a second Delete removes it, and Undo restores its exact source. Deleting outward from code also selects the block instead of joining it to prose. Find templates in **File → Templates…** or Cmd-K. Try the [Field notes](examples/Field%20notes.typ) sample.

## Projects and references

Unnamed documents save privately in the app’s data directory while you write. The **Reopen unsaved documents on launch** setting is enabled by default and restores available drafts with their exact source, included files, assets, active file, editing view and text selection. Close and Quit retain macOS’s standard save review; explicitly discarded documents do not reopen and remain available as manual recovery copies. Turn the setting off to skip unsaved drafts at launch. Empty documents stay closed. **Save** still lets you choose an ordinary `.typ` file, after which normal file autosave and conflict protection apply. Undo history starts afresh after relaunch. Failed retention blocks normal closing/quitting; unreadable recovery records remain intact and report a restoration error.

**New Document** stays empty. **File → New Project…** creates a dedicated folder containing only an empty `main.typ`. Projects are ordinary Typst folders, with no entry manifest. Opening a `.typ` selects it for compilation; opening a folder uses its remembered entry or a single document that is not included/imported by another file, otherwise a native panel lets you choose. Selections are stored in the app’s data directory. A directly opened file uses its parent as the root unless it belongs to a folder previously opened as a project.

Includes and imports keep their names and structure. Relative paths resolve from the referring file; `/…` resolves from the project root. Adding a literal chapter include creates its empty `.typ` automatically. Existing missing/unreadable files are reported rather than overwritten. Packages must already be cached or vendored in `packages/`.

Zotero insertion uses the document’s declared bibliography, including external BibLaTeX `.bib` and Hayagriva `.yaml`/`.yml`. Multiple inputs offer a destination choice. The app never attaches bibliographies merely because they share a folder. Without a bibliography, the first import embeds readable BibLaTeX in the document using Typst’s `bibliography(bytes(...))` input; independent documents can share a folder without generated reference-file collisions. There is no `writer-references.json` or beta-storage migration.

Zotero item keys, library identifiers (`users/…` or `groups/…`) and the exported field list live in `x-blank-zotero-*` metadata alongside each entry. **Refresh Zotero References** is manual: it retains citation keys, changes only linked entries and keeps unrelated entries, comments, macros and custom fields. Citation insertion and refresh use canonical range history; cross-file insertion undoes the citation and bibliography together. Write uses Typst’s formatted citations/bibliographies; Source keeps the complete editable expressions. **Bibliography style** accepts standard style names or a custom CSL file.

**Convert Bibliography…** is available in Cmd-K and the File menu. Choose a bibliography input, then embedded BibLaTeX, external `.bib`, or external Hayagriva `.yaml`. Moving BibLaTeX between embedded and external storage preserves its exact text; format changes preserve Zotero linkage and keep an encoded original-source snapshot in a comment for an unchanged round trip. Citation keys, call options and styles stay intact. Existing external files are retained, new-file collisions are rejected, and conversion shares source Undo. Conversion requires direct literal paths/bytes inputs; variable or computed inputs stay editable in Source. Hayagriva-to-BibLaTeX conversion is refused when the official parser cannot recover identical reference data.

Save As preflights dependency collisions and copies literal dependencies plus files read by a background Typst evaluation. A nested entry’s literal paths are rebased; when computed paths require their original location, an ordinary `.typ` include wrapper keeps the original entry and folder structure intact. Unreached computed dependencies cannot be discovered automatically. Computed raw-byte bibliography data and package-owned bibliographies remain editable in Source but are not rewritten by Zotero. Hayagriva Zotero edits require block mappings; flow mappings/aliases still compile and remain source-editable.

Checks cover external projects, nested/root paths, embedded/external references, Zotero refresh with isolated responses, custom CSL, assets, Unicode, selection/clipboard, Undo and Save As. Compiler checks compare reference presentation with and without the metadata fields. Native checks also cover citation clicks and local edits, table-cell fields, already-cited search/reuse, menu parity, Code insertion/colors, delimiter protection, indented Return, composition and exact-source Undo. Disposable app inspection verifies the gray fields, citation controls, picker markers and native menu layout; live Zotero insertion/refresh remain unverified.

Selection-panel checks cover combined Unicode styles, whole-block conversion/alignment, default-alignment reset, panel cursor ownership, non-clickable links, hover actions, exact link removal with adjacent links and table options preserved, native link-sheet focus, table cells, literal code editing, composition and shared Undo. Disposable app inspection verifies the popover layout and formatting actions. Ten unchanged panel updates in a small debug fixture measured 0.2 ms wall time and 0.3 ms CPU; the acceptance process used 153.3 MiB RSS. One hundred link-hover hit checks in a small release fixture measured 4.3 ms wall time and 4.0 ms CPU, with 128.7 MiB process RSS. These measurements exclude initial panel creation and the compiler process and do not establish long-document performance.

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

Draft checks launch three disposable app processes to cover native Close/Cancel and discard cleanup, final termination snapshots, the persistent opt-out setting and native-restoration suppression, committed composition, exact multi-file/asset restoration, native Unicode selection, stable session identities, empty/saved exclusions and failed or damaged recovery. A release acceptance run restored two small draft projects and their native windows in 220.5 ms wall time and 221.5 ms CPU, with 138.4 MiB process RSS. This small desktop fixture excludes compiler-process memory and does not establish large-project or full-launch performance.

Write figures scroll with their text instead of sticking to the viewport. Block dragging keeps document-relative targets and continues scrolling while held beyond the viewport edge. Native regressions cover moves past 80 blocks, exact Unicode Undo and figure removal/restoration across scrolls; disposable app checks also verify image scrolling and block placement visually.

The Cargo workspace shares a lockfile/cache for the in-process parser and separate PDF compiler, both using Typst 0.15.1. See [AGENTS.md](AGENTS.md) for architecture and build conventions.

[CI](.github/workflows/build-macos.yml) checks pushes and pull requests on macOS 26/27. Publishing a `vX.Y.Z` release attaches the Apple Silicon app and checksum after both builds pass. Apps are ad-hoc signed; Intel support is unverified.

## Remaining work

- Rich controls for editing footnotes, grouped/complex citations and custom figures; PDF-page selection and broader image-format validation.
- Zotero group discovery and citation-picker keyboard navigation. Custom citation show rules and note-style footnote presentation in Write remain unverified.
- Continuous editing across included files and repeated includes.
- Settings synchronization, disjoint external-change merging and broader recovery checks.
- Large-table and Source performance; long-document memory/latency measurements.
- Opt-in MCP/agent access with revision-checked transactions and selective undo.

Live Zotero insertion/refresh, physical IME candidates, bidirectional editing, VoiceOver and Writing Tools remain unverified. An empty-editor release run measured 0.14% of one CPU core and 14.5 MiB RSS; compiler memory was excluded. Use `--measure` with disposable `BLANK_DATA_DIR` data.

[MIT](LICENSE) · Built with OpenAI Codex.
