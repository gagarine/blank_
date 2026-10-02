# blank_ — a Typst academic writer

A local macOS desktop app built with Go, Wails 3 (pinned to `v3.0.0-beta.26`), React, ProseMirror, CodeMirror 6 and a bundled Rust/Typst 0.15.1 helper. Ordinary Typst source files are authoritative. There is no app-specific document database, cloud service, or built-in AI chat.

The desktop layer uses [Wails’ native multi-window API](https://v3.wails.io/features/windows/multiple/); it never launches another app process for New Document or Tutorial. Typst compilation still uses a background helper per document.

This repository includes a runnable **v0.1 development build**, automated preservation/integration tests and a reproducible thesis fixture. It is **not yet a release-certified v1**: native IME, VoiceOver, exhaustive cross-chapter clipboard behavior and end-to-end latency acceptance still need validation. See [the acceptance report](acceptance.md).

## Run

Open `build/bin/blank_.app` after building, or launch its executable with a project:

```sh
build/bin/blank_.app/Contents/MacOS/blank_ --project /path/to/thesis
```

Launch and Dock reopen show **Home**, with New Document, Open Document, a recent-document list, Tutorial and Settings. No previous document or tutorial is opened automatically. The recent list stores up to ten saved documents; unavailable files can be removed from the list without deleting files.

Use **Open Document** for any `.typ` file. Opening a file uses its containing directory as the project root. Open `main.typ` for a multi-file thesis. The CLI also accepts a folder with `main.typ`, or a `writer.json` specifying `{"entry":"main.typ"}`. **New Document** (`⌘N`, File menu or command menu) opens an unsaved **Untitled.typ** draft immediately, reusing Home or creating a separate native window when a document is already open. The first **Save** (`⌘S`) asks for a name and location; drafts use the local recovery area in the meantime. All document windows share one app process and Dock icon; each keeps its own editing session and undo history. Open and Tutorial also reuse Home when available or create document windows, and the native Window menu switches between them. Closing a window releases its session; ⌘Q quits the app. A sample is in `examples/paper`.

The bundled helper includes fonts, so offline writing and PDF export need no separate Typst install. Existing package imports can use Typst's local package cache or `packages/<namespace>/<name>/<version>` inside the project. Missing packages produce a diagnostic; this build does not fetch packages automatically.

## Writing

- **Write** edits prose, headings, bold/italic, lists, quotations, links and rectangular tables. Citations, footnotes, labels, cross-references, equations and unfamiliar Typst remain source-backed objects. Click an object to edit its Typst; image figures have a dedicated form.
- **Source** exposes the full file through CodeMirror. **Preview** renders the complete project as a PDF with lazy page canvases. An invalid document keeps the previous successful preview. PDF export compiles and identifies a successful current revision.
- The default writing view is a white page with a quiet filename in the title strip and no toolbar, footer, save indicator or visible sidebar. Move into the free margin to the left of the text to reveal the **Table of contents** temporarily; it dismisses when the pointer leaves. Press `⌘⇧L` to pin or unpin it, or use **Pin table of contents** / **Unpin table of contents** in `⌘K` or the View menu. Double-clicking does not pin the panel. The temporary panel uses a solid white surface (dark in dark mode), without blur or transparency, highlights the current chapter in bold, and has no header, tooltips or row hover backgrounds. Tree nodes expand and collapse, and headings navigate by their source position, including repeated titles. The tree belongs to the document open in this window: unrelated files are omitted, as is a sole document-title heading that groups its sections. The title remains unchanged in the document. Drag sibling headings to reorder entire sections, or chapters to reorder their literal include lines; `⌥↑/↓` on a tree entry does the same. Use `⌘K` → **Show all chapters** / **Show only current chapter** to switch the writing view. The tree stays prepared while hidden; it fades in on entering the reveal zone and fades out on leaving. The reveal zone reserves the paragraph handle plus a safety gap, including in narrow windows. Continuous mode expands literal, unconditional includes in source order while retaining file boundaries. Dynamic includes stay as source regions.
- Typing uses Typst markup: `= ` for headings (`== ` for subheadings), `*bold*` and `_italic_`. Existing source and pasted text are not converted by these typing shortcuts. Type `/` at the start of a block or after a space for the inline insertion/formatting menu. Filter by typing, use ↑/↓ and Return, or Escape to keep a literal slash. Hover beside a block to drag it within its chapter; click the handle for **Turn into**, **Duplicate**, and **Delete**, or use `⌥↑/↓` to move it. Reordering uses the shared source transaction and undo history. Block handles disappear while text is selected; native macOS context menus are enabled in the editors.
- Click the blank space before or after an image, table, equation, or source block to continue writing. Arrow keys leave selected blocks; ↑/↓ at the first/last visual line in the outer table rows moves to surrounding text. Existing paragraphs are reused and new ones stay in the same chapter. The editor also includes [ProseMirror’s gap cursor](https://code.haverbeke.berlin/prosemirror/prosemirror-gapcursor) for otherwise unreachable positions.
- `⌘K` opens app commands (open, save, sidebar, view, focus, theme, export), `⌘1/2/3` switches modes while keeping the visible passage nearby, `⌘S` saves, `⌘F` searches, `⇧⌘C` inserts citations. `⌘B/I` formats rich text. `⌘Z` and `⇧⌘Z` use the shared transaction history. Focus, typewriter scrolling, theme, fullscreen and sidebar controls are included.
- The filename sits on the left of the title strip as plain text. Use `⌘S` or File → Save for the native macOS Save dialog; there is no custom title popup.
- Simple tables have contextual row/column actions and edge buttons to add rows or columns. Tab advances between cells and adds a row at the end; each structural change is undoable.
- **Tutorial** in `⌘K` or the native Help menu opens an editable, unsaved copy of the bundled tutorial in a new window. Home also links to the tutorial; it opens only when requested. The first Save asks for a `.typ` location; local assets travel with the saved copy, existing files are protected, and undo history is retained. Unsaved copies are kept in the application’s recovery area.
- **Settings** (`⌘,`, File menu or `⌘K`) controls writing background, font, size and text color. The font picker includes the available macOS font families alongside quick choices; installed-family selections persist across restarts. The custom background and text color apply only to the writing surface; dialogs and app controls keep the system theme. Preferences persist locally and do not change Typst/PDF formatting. **Statistics & info** reports manuscript word/character counts and file metadata on demand. Atomic saves preserve macOS file creation dates where the filesystem supports it.
- Preview uses a small floating page/zoom control. Its editable current-page field accepts a page number followed by Return; the page number also follows scrolling.
- The table handle menu adds/removes rows and columns. Complex or generated tables belong in Source.

### Images

Insert **PNG, JPEG, GIF, SVG, WebP or PDF** through `/image`, clipboard paste or file drop. Choose a caption, alternative text and width; PDF figures also accept a page number. The app copies the original into `assets/`, preserves existing files on name collisions, and reuses an identical existing copy. Imports are capped at 32 MB. Offscreen thumbnails are deferred. Animated formats appear as the compiler's static image representation in the PDF.

Choose the original figure again by clicking it in Write. Paths are stored relative to the chapter that contains the figure. Assets remain plain files and compile outside blank_. See [Typst's supported image formats](https://typst.app/docs/reference/visualize/image/#parameters-format).

### Source preservation and recovery

Opening, mode switching and a save without edits do not serialize source. Rich edits produce localized UTF-8 source patches; comments and unknown syntax have raw source regions. Structural changes preserve unaffected source gaps. Source offsets use UTF-8 bytes; editor positions use JavaScript UTF-16 units. View switches use the visible cursor or reading passage. Preview carries a compact map from compiled text runs to source ranges, so switching to or from a PDF page finds the nearby source passage across chapter files. Comments and generated content use the nearest available text anchor; this is passage navigation, not exact visual equivalence.

Autosave runs after 750 ms idle. Each edit is journaled under `~/Library/Application Support/TypstWriter/recovery/` before the source is saved. Writes use temporary files, fsync and atomic replacement. Directory watches and a one-second rescan detect atomic external replacements, new chapters and changed dependencies. Focus triggers a rescan too.

Disjoint external changes merge against the last synchronized file. Overlaps and deleted files pause saving and present both versions for explicit resolution. A rejected editor transaction retains a browser-local recovery draft (`still-recovery-draft`) and an error; copy that draft before reloading. Recovery storage is local and is not a substitute for project backups. Arbitrary external writers cannot participate in the app's revision checks.

## Zotero

Open Zotero and go to **Settings → Advanced**, then enable **“Allow other applications on this computer to communicate with Zotero”** to turn on its local HTTP API at `http://localhost:23119/api`. Keep Zotero open while inserting citations or refreshing references. Zotero is optional: if its API is unavailable, these actions show setup instructions; writing and previewing saved citations continue to work. The picker searches personal or group libraries by title, creator and year (up to 40 matching items). Arrow keys move through results, Enter/Space selects references, and `⌘Enter` inserts selected citations. Locators and narrative/author/year forms are supported.

Citations save stable identity-based keys to `writer-zotero.bib` and an identity map to `writer-references.json`; existing entries are preserved. **Refresh Zotero references** replaces only saved entries, retaining keys. If Zotero is unavailable or an item is deleted, saved metadata is retained. Existing projects compile offline. Better BibTeX is not required. A bibliography style command changes ordinary same-line style settings; use Source for more complex templates or local CSL paths.

## Agent integration

Enable **agent access** in the command menu for the open project. Access starts disabled each time a project is opened. The app owns a user-only Unix socket; the MCP adapter never opens a separate document session.

Example Codex configuration (adjust the absolute path):

```toml
[mcp_servers.blank_]
command = "/absolute/path/to/blank_.app/Contents/MacOS/blank_"
args = ["mcp"]
```

The adapter supports stdio MCP initialization, tool discovery and calls. Tools cover project source/outline, selection, Zotero search, citation insertion, diagnostics, compilation, PDF export and transactions. Direct JSON-RPC uses one newline-delimited request/response per Unix-socket connection. Default socket: `$TMPDIR/still-writer-<uid>/rpc.sock`, mode `0600` in a `0700` directory. `WRITER_SOCKET` overrides the location for the initial document and its MCP adapter. Document windows share one process and have independent sessions. Additional windows get `window-<pid>-<sequence>.sock` endpoints instead of replacing another window’s socket. After enabling agent access, **Statistics & info** shows that window’s socket; configure an adapter with `args = ["mcp", "--socket", "/absolute/socket/path"]` to target it explicitly.

Every edit supplies a project identity and expected revision for each touched file. Ranges are half-open UTF-8 byte offsets. The entire transaction is validated before applying any edits:

```json
{
  "jsonrpc": "2.0", "id": 1, "method": "document.applyEdits",
  "params": {
    "projectId": "identity returned by project.read",
    "expected": {"chapters/01.typ": 7},
    "edits": [{"path":"chapters/01.typ","start":0,"end":0,"text":"= Introduction\n\n"}]
  }
}
```

Agent transactions appear live and record their origin. **Undo latest agent edit** preserves later disjoint user edits and rejects an overlapping undo. The service rejects stale revisions, path escapes and access to a disabled project. PDF export through agents is project-relative and requires a `.pdf` destination. The socket is intended for trusted processes running as the current macOS user.

## Build and check

macOS 15+, Apple Silicon or Intel, Xcode Command Line Tools, Node.js 22.12+ (or a compatible newer LTS), npm and Python 3 are needed. Bootstrap installs Go 1.27.1 and Rust 1.98.1 inside ignored `.tools/`, without changing system toolchains:

```sh
bash scripts/bootstrap.sh
bash scripts/build.sh
bash scripts/check.sh
```

The build produces `build/bin/blank_.app`, signed ad hoc for local development. It is not Developer ID signed or notarized for distribution. Lockfiles pin Go, npm and Rust dependencies. `scripts/env.sh` is a Bash environment helper.

For browser development, `bash scripts/dev.sh` serves the same Go service on `http://127.0.0.1:3415`. `npm run dev --prefix frontend` can provide Vite reloads on port 5173. The desktop build does not expose this HTTP server. Use a different `WRITER_SOCKET` and a separate fixture when running desktop and browser sessions simultaneously.

Reproduce the large manuscript:

```sh
python3 scripts/thesis-fixture.py
python3 scripts/benchmark.py
python3 scripts/rpc-check.py  # port 3415 must be free
```

It contains exactly 150,000 body words, 20 chapters and 1,000 citation entries. Explicit page breaks produce about 500 body pages plus bibliography pages. Frontend tests also measure 60 source-mapped rich model edits; `.tools/model-benchmark.json` reports that narrower metric, not native typing latency.

## Code map

| Location | Responsibility |
| --- | --- |
| `cmd/blank_` | Desktop executable, native macOS bridge and app orchestration |
| `frontend/assets.go`, `examples/embed.go` | Embedded interface and tutorial assets |
| `internal/document` | Revisions, validated transactions, selective undo, merge, atomic saving, recovery and directory watching |
| `internal/engine`, `helper` | Restartable JSON-RPC helper, Typst CST ranges, source cache, compiler, PDF output |
| `frontend/src/projection.ts` | Conservative rich projection, source serialization and UTF-8/UTF-16 mapping |
| `frontend/src/RichEditor.tsx` | One ProseMirror document, stable editable DOM, continuous chapter sections |
| `frontend/src/SourceEditor.tsx`, `PdfPreview.tsx` | CodeMirror, PDF.js and PDF-figure thumbnails |
| `internal/zotero`, `cmd/blank_/app.go` | Local Zotero access, stable bibliography entries, shared app operations |
| `cmd/blank_/assets.go`, `cmd/blank_/rpc.go` | Project-local image import, Unix RPC and stdio MCP |

Pandoc exchange, cloud collaboration, Word review, visual equation construction, built-in AI chat and Windows/Linux releases remain outside this build.
