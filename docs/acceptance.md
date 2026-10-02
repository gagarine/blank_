# Implementation checkpoint and release acceptance

Date: 2026-10-01. Development build: 0.1.0.

This is a working macOS application and a tested preservation checkpoint, not a claim that every v1 release criterion has passed.

## Evidence collected

- Go `go test -race ./...` and `go vet ./...` pass. Tests cover source no-ops, UTF-8 range rejection, stale revisions, multi-file atomic validation, external replacement/deletion, disjoint merges, overlapping conflicts, selective undo/redo, recovery, project path/symlink boundaries, new dependencies, helper restart/concurrent parsing, agent access, export revision identity, compiler failures, Zotero outage/group identity/stable keys, offline compilation, import collisions, SVG and PDF-figure compilation, both templates, creation-date retention across atomic saves, disk/unsaved file metadata, blank-file creation without overwrites, independent window sockets, fresh tutorial recovery copies, draft Save As with assets and collision checks, filename changes with project settings, selection and undo/redo history preservation.
- Thirty-six frontend tests pass, using the actual bundled Typst parser. They cover unchanged CRLF/custom syntax, local prose edits, nested formatting with unknown inline content, includes, malformed/dynamic syntax, tables, Unicode, paragraph splitting, block conversion, parser-backed nested outlines, repeated heading identities, slash-to-heading transactions, byte-preserving block moves, subsequent typing after moves, chapter-boundary rejection, thesis-scale repeated edits, native Typst typing shortcuts with nested marks/Unicode, whole-section and chapter-include reordering, stale move rejection, manuscript word counts, parse-cache revision races, Unicode patch boundaries, PDF canvas cancellation/cleanup, startup restoration, empty native file-drop events, table row/column edits, and exact block duplication/deletion.
- Native packaged Wails/WebKit app launched and opened a project. Write → Source → Preview → Write left the sample's SHA-256 unchanged (`c87474400b05e9c19ca16e083c4213d3787aa338417d633062e65137cc9519f1`). Typing and Enter splitting were exercised. A DOM replacement/caret regression found in this check was fixed by retaining editable node views as source metadata changes.
- The actual native app opened the 20-chapter continuous thesis and accepted Unicode typing. Comparing against a regenerated fixture confirmed that only the intended heading span in `chapters/01.typ` changed; every other source byte was preserved.
- Native Source reflected an externally replaced file during manual inspection. This establishes live synchronization, not a measured sub-second end-to-end latency claim.
- Native UI refinement: a white-page writing view with no permanent header/footer or save indicators; app commands through ⌘K; optional scrollable nested outline. The actual macOS webview exercised a 20-chapter subtitle tree, slash filtering and heading conversion, and keyboard block movement. A distant-heading scroll issue was found and corrected by resolving deferred section layout before revealing the target. A user-reported drag-handle hover gap was fixed with a continuous gutter hit area and a larger handle target. The final pointer-drag and distant-heading retests were interrupted by active user interaction; these remain native validation items.
- Native SVG import, caption and alternative-text editing were verified through the macOS file chooser. A PDF figure rendered in the rich view through PDF.js.
- PDF preview displayed the compiled sample. Successful export and refusal to export an invalid revision are tested through the same app service.

- Native refinement check: ⌘, opened Settings with the requested appearance controls; the compact PDF page field jumped from 1 to 3 in a three-page fixture. Source hashes before and after selection, Write/Preview switches and Settings matched for all three files. The 44px title strip clears the preview background from the window-control area.
- Right-click defaults are enabled in the production Wails configuration, with native context menus allowed on both editors. Block controls hide during text selections. The system Writing Tools accessibility action was exposed, but the UI automation could not establish a successful proofreading round trip or a visible context menu; native Siri beta interoperability remains unverified.

- The bundled Help document is a 441-word hands-on guide. A first launch in an isolated native app opened an unsaved tutorial automatically. The native name popover, first Save sheet, and renaming a saved copy were exercised successfully. The filename is left-aligned; renaming stays in the current folder. The popover uses AppKit controls; it does not implement TextEdit’s Tags/Move To controls.
- Native table checks exercised Tab from the final cell, the added row’s caret position, and the separate add-column button. The block menu exposed Turn into, Duplicate and Delete; duplication was exercised. Native Edit → Undo was verified after routing the menu to shared document history; native text fields keep their own undo manager.
- The native Wails bridge sends an empty file-drop path for drags without file URLs. The UI now discards these callbacks before moving selection or importing assets. Regression coverage distinguishes these internal drags from real file paths; the reported `open : no such file or directory` path is eliminated.
- In the browser webview, a vertical paragraph-handle drag in the gutter moved the block and shared Undo restored it. Proportional sidebar opacity, the protected handle gap, double-click pin/unpin, no item tooltips, and 60 prepared outline entries while hidden were checked. At 800px, the sidebar remained compact and the handle area stayed outside its reveal zone. Full native pointer acceptance remains separate.
- Writing background was changed to `#f4eddf` through Settings: the writing surface computed to RGB(244,237,223) while the Settings dialog remained RGB(255,255,255). Defaults were restored afterward. The final short tutorial rendered its three view shortcuts and literal Typst examples correctly.

## Performance measurements

Host: Apple M1, **8 GB RAM**. This is not the specified 16 GB reference hardware. The synthetic thesis contains 150,000 body words, 20 chapters and 1,000 citation entries and compiles to **527 pages** with the bundled fonts/compiler.

| Measurement | Observed | What it measures |
| --- | --- | --- |
| First helper compilation | 0.894 s | Compiler request including PDF serialization, on this host |
| Two warm edited compilations | 0.368 s, 0.271 s | Changed chapter text, persistent helper/cache |
| One chapter parse | 1.29 ms | Helper CST request |
| Rich model edits p95, 60 samples | 5.27 ms | ProseMirror model transaction, source patches, source reanchoring; excludes native input/DOM/paint |

The source-patch calculation for a 500,000-byte Unicode buffer improved from p95 **11.72ms** to **1.49ms** over 40 isolated samples. This excludes native input, layout and paint. Parser requests/results are shared across editor, outline and statistics; offscreen PDF canvases are released and in-progress rendering is cancelled safely. Overall process RSS has not been benchmarked before/after, so there is no quantified RAM reduction claim.

These observations do **not** establish the p95 <50 ms native typing target, <1 s externally changed text display target or <3 s end-to-end preview refresh target on the release reference machine. Re-run the scripts and a native latency capture on the target machine before release.

## Remaining release validation

- Native pointer hover/drag checks for the temporary contents panel and section reordering, and Siri beta proofreading/context-menu integration.
- Full native IME composition across incoming external/agent edits, international keyboard layouts, spellcheck replacement, VoiceOver reading/navigation, and long selection/clipboard operations across chapters. Ordinary native typing has been exercised; this matrix has not been certified.
- Long-running memory pressure, repeated includes, deeply nested formatting, nontrivial imported Typst templates, and real thesis projects beyond the deterministic fixture.
- Native clipboard image and Finder drag/drop variants, GIF/WebP variants, multipage/encrypted/newer-version PDF diagnostics, and large images near the size limit. SVG import and PDF-figure display were exercised in the native app; Go import and Typst SVG/PDF compilation paths are automated.
- Integration with a configured Codex desktop MCP client. The packaged stdio adapter passed an isolated black-box test (10 tools, disabled access, atomic multi-file edits, stale rejection, selective undo and PDF export). No user MCP configuration was changed.
- Abrupt OS termination and disk-full/permission failures beyond journal reconstruction tests; races with arbitrary external processes can only be reconciled after observation.
- macOS 15 on reference hardware, Developer ID signing, notarization and distributable packaging.

## Current boundaries

The rich view intentionally handles a conservative Typst subset. Unknown expressions, templates, generated content and complex tables remain editable source regions. Equations are edited as source and typeset in Preview. Literal includes expand; dynamic includes do not. Blocks can be reordered within a chapter using their hover handle or ⌥↑/↓, preserving source-backed content and shared undo. Cross-chapter block moves stay protected. The table of contents reorders sibling sections and standalone literal include statements; arbitrary nesting and dynamic project structure remain in Source. The PDF preview currently uses page canvases and does not expose a selectable PDF text layer; the accessible source/rich views remain available.

Undo is transaction-based; rapidly typed characters are individual transactions in this build. In-memory undo history does not survive restarting the app; recovery journals preserve unsaved content. On a rejected UI transaction, a local recovery draft is retained and an error is displayed; there is not yet a dedicated recovery-draft browser.

The default project root is the opened file's parent directory. For nested chapters, open the root file/folder first. A project's external package cache must already exist for offline compilation. Zotero refresh updates bibliography metadata while retaining identity-based keys; it does not migrate existing arbitrary author-year keys.

## Final bundle verification

`build/bin/blank_.app` contains arm64 executables and passes `codesign --verify --deep --strict` with its ad-hoc development signature. The UI is now named **blank_**, including the application bundle, native window title and main executable. Existing application identity, local preferences, recovery paths and RPC socket naming remain stable across this rename. The previous build was moved to `.tools/previous-build/`.

The Go race tests and vet and thirty-six frontend tests pass after the multi-window migration. The earlier packaged adapter check covered ten tools, revision rejection, selective undo and PDF export; the native window migration does not change the stdio MCP protocol. The native Wails 3 check created a new document and a Help copy alongside the original document. All three appeared in one Window menu, and process inspection showed one application process with three compiler helpers. Switching windows preserved their contents; closing Help left the other two open. Closing the original window also left the second document usable. Closing the last window kept the application process alive and released its compiler helpers. Editing, native Undo, the name popover/rename, and PDF Preview were verified in the second window. The final startup adjustment was checked with a visible first window and the retained `wails://wails/` storage origin. Regression tests cover independent document edits/history, rejection of calls to closed sessions, project boundaries and three distinct same-process agent sockets. The isolated first-launch tutorial, native Save/rename, table changes and Edit → Undo were exercised separately. Temporary UI tests used app-owned copies, preserving the user’s test documents. Do not treat model tests as proof of pointer/VoiceOver/IME acceptance.

The outline refinement adds ⌘⇧L and a native View-menu command for pin/unpin, removes double-click pinning, omits a sole document-title wrapper and unrelated files from the outline, and centres block grips on the first text line using the actual line height. Native checks verified section-level tutorial entries, shortcut pinning/unpinning and the ⌘K shortcut hint, a double-click followed by moving into the document without losing the pinned panel, and paragraph/title grip alignment. The frontend suite now has 36 passing tests, including section moves after title elision. The earlier double-click pin/unpin evidence above describes the superseded interface.

Final executable SHA-256:

- `blank_`: `7dd722d9788ad25937409126e076d9ce4872ffeac2c4f545e900167ebaefb6ae`
- `writer-helper`: `0d865147e7013e233976ff2347604931d922754f527c9fd93c13c0d3def3433c`

The custom AppKit filename popover has been removed at user request; its earlier checks above are historical. The left-aligned title is now plain text, and Save still uses the system dialog. The unpinned sidebar uses a white translucent backdrop with 24px blur. Native compact-window checks exposed a WebKit compositing issue when opacity was applied to the filter layer; fading the surface and text separately fixed it. The final native screenshot confirmed blurred document text underneath a sharp contents list, and ⌘⇧L restored the solid pinned sidebar. The production bundle builds and passes the signature check.

The floating sidebar tint was subsequently reduced from 72% to 58%, and its maximum blur from 24px to 8px, to retain visible document shapes once fully revealed. The pinned surface and reduced-transparency fallback remain opaque.
The light appearance now uses explicit neutral white and desaturates the backdrop so editor colors cannot tint the glass. Dark appearance keeps its matching surface.
A native compact-window check confirmed that blurred document shapes remain visible after full reveal and after moving the pointer inside the panel. Production build and signature verification passed.

Settings now reads available font families through CoreText instead of limiting the picker to five presets. The native picker displayed installed families, and selecting Academy Engraved LET visibly changed the editor. The CoreText test returned 179 families; 38 frontend tests passed, including saved-family preservation and CSS name escaping. The macOS build and signature verification passed.
The installed-font selection was also retained after quitting and relaunching the isolated native app.

Startup now leaves empty sessions on Home; the earlier automatic last-document and first-launch tutorial behavior above is superseded. Home provides New/Open, explicit Help and Settings, and up to ten recent saved documents with folders and unavailable-file removal. Native open/new/help actions reuse an empty Home window; existing document sessions remain independent. Recent paths are stored atomically in the shared app data directory, excluding unsaved tutorial copies. Regression checks cover startup without restoration, explicitly opened documents, recent-list persistence/deduplication, missing files, removal without file deletion, concurrent window updates and rename tracking. The targeted Go race checks and 38 frontend tests passed.
Native Home-flow verification used an isolated bundle and disposable recent-file fixtures: initial launch displayed Home, a recent-file click reused that window, closing the last document and relaunching via the Dock returned to Home, and removing an unavailable entry updated the list. The production bundle passed signature verification. No sidebar appearance changes were made in this iteration.

### Untitled document flow
New Document now opens an unsaved `Untitled.typ` immediately, reusing Home or opening a separate native window. The first explicit Save asks for a destination. Regression tests cover independent drafts, recovery autosave, first Save retaining text, and leaving existing documents untouched; existing draft Save As tests cover assets, undo and collision protection. Targeted Go race checks and the production build passed. An isolated native app confirmed Home → blank editor without a dialog, typing before Save, the native Save sheet on ⌘S, cancellation retaining text, and ⌘N opening a separate blank window while the original draft stayed intact.


### Reading position and solid contents panel
View shortcuts and command-menu actions capture the visible cursor or reading passage before switching. Write and Source reveal that source range; Preview uses a compiled text-run map with page geometry, retained alongside a last-successful PDF after errors. Native checks on a twelve-page fixture confirmed page 8 → Source → Write → Preview stayed on page 8; scrolling Write without moving the cursor advanced Preview to page 10. Go race checks cover chapter mapping, Unicode byte boundaries and stale-preview retention; all 41 frontend tests passed. The sidebar now uses a solid surface with a short reveal/dismiss fade; all backdrop blur and resting transparency have been removed.


### Navigation around non-text blocks
Added the standard ProseMirror gap-cursor plugin with source context at section-level selections. Explicit clicks above/below blocks and arrows out of selected blocks or outer table rows can create an editable paragraph; adjacent text is reused, IME and modified-arrow selections are not intercepted, and paragraph insertion stays within a source chapter. All 45 frontend tests pass, including source-preserving insertion around standalone images/equations/source blocks, table row boundaries, selection protection, existing paragraph reuse, and chapter isolation. Native WKWebView checks confirmed typing after clicking above/below an image-only document and using Up/Down to type before/after a table-only document. Fixture source retained the original image/table syntax. Production build passed.
