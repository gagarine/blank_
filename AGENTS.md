# Working on blank_

## Start here

Read `README.md` for implemented features, the roadmap and known gaps. Keep project documentation there for now. Inspect Git status before editing and preserve existing changes. The unfinished Rust interface is not the specification.

The Go reference is preserved on `codex/legacy-go`. Inspect it with `git show` or a separate checkout without switching away from or resetting ongoing work. The Rust prototype, including its saved work, is preserved on `codex/rust-native-prototype` at `d8e8448`. Preserve both branches. The native Swift frontend has been merged into `main`; `codex/swift-native` retains its development history. Check current Git state rather than assuming these heads never change.

## Product direction

- macOS 26 and 27 are the targets. Prefer modern Apple GUI defaults and native Liquid Glass controls over imitating an early prototype.
- SwiftUI supplies the interface. AppKit supplies native windows, menus, panels, scrolling and text editing. There is no web renderer, Go frontend or UIKit `UITextView` in this app.
- Launch directly into an empty editor with a focused, blinking native caret. Do not restore a home/welcome screen.
- Keep the interface quiet and minimal, with readable typography and dependable editing. Use system fonts and real bold/italic faces; the default editor font is the native macOS system font (San Francisco). Offer installed fonts only in the frontend. The Typst compiler process includes Typst’s standard bundled fonts for dependable PDF typography, alongside installed fonts.
- The Go app is a reference for block/document behavior and feature coverage, not a mandate to copy its toolbar, paragraph spacing or other GUI decisions. Keep `examples/Tutorial.typ` concise and editable, with nested headings and section-movement exercises. Open tutorial copies with Contents pinned for feature discovery; ordinary new documents still open with an empty editor. The original Go tutorial remains preserved on `codex/legacy-go`. New features such as MCP should follow the current native architecture; they need not imitate Go.
- Use the standard menu bar, customizable unified toolbar and native sheets/file panels. Leave glass, selection colors and caret blinking to the system. Do not add white toolbar backgrounds, green selection highlighting, custom blink timers or draggable in-document dialogs.
- Keep scrollbars at the document viewport edge, independently of text padding. Page/text/table colors follow appearance by default, with an optional custom palette.

## Architecture and invariants

- `Sources/BlankCore` owns canonical Typst source, syntax-backed structured projections, UTF-16/native-to-UTF-8/source mapping, localized edits and range-based history. Preserve comments, custom expressions and unaffected source exactly. Never regenerate an entire document from its visible rich text.
- `Sources/BlankNative` owns SwiftUI views, AppKit integration, document sessions, file handling, background compilation and PDFKit preview.
- `NativeDocument` connects canonical sessions to AppKit's standard title, proxy icon, Edited status and rename/tag/location/lock popover. Keep shared source history and project-wide dirty state in the session; do not add a second undo stack or draw custom title controls. Drafts are real UTF-8 snapshots in an app-owned per-session directory, with durable JSON recovery remaining authoritative. Native save/move hooks retain dependency preflight and external-conflict protection. Lock checks use AppKit's recoverable unlock prompt before editing transactions. Native version browsing is disabled until project-aware version handling is implemented.
- `Sources/CTypst` and `typst-syntax-bridge` expose the official Typst parser through a C-compatible library. `typst-compiler` provides the official PDF compiler as a separate `typst-compiler` executable through a JSON-line process interface. Both crates belong to the root Cargo workspace, share `Cargo.lock` and `target/`, and inherit the pinned Typst version from the root manifest. Rust is used for Typst integration, not frontend rendering or a competing document model.
- **TextKit 1 is now an intentional, user-approved choice.** Create `NSTextView(usingTextLayoutManager: false)` explicitly for Write and Source. Integrated native `NSTextTable`/`NSTextTableBlock` editing was required, and TextKit 2 was evaluated and found to fall back for these tables. Do not silently switch engines, reintroduce separate per-cell field editors/NSTableView overlays, or replace native tables with a drawn grid. The original TextKit 2 evaluation and native acceptance notes remain in Git history.
- Table cells share the document's NSTextView/text storage. Their local projections map native positions into canonical cell spans. Synthetic cell terminators are layout characters, not source delimiters. Preserve table options and surrounding syntax during cell edits, composition, selection, clipboard and undo.
- Write and Source share canonical source/history and source selections. Included files retain independent histories. Keep sensible adjacent-typing groups and bounded changed-range history. Native AppKit pre-edit/change notifications and final selection updates are necessary for reliable caret behavior after model-driven changes.
- Write can collapse opaque source blocks to one line through a native disclosure button or block menu. Folding is per-file presentation state, never a source edit or undo step. Treat folded blocks atomically for selection/clipboard and reveal hidden source selections when returning from Source. Preserve comments and table options through localized row/column transactions.
- Source retains and copies every source character, with syntax colors and actual font faces. Disable prose substitutions in Source and restore native input preferences in Write.
- Use `typstStringLiteral` for generated Typst string arguments. JSON slash escaping (`\/`) breaks Typst file paths; do not use a plain JSONEncoder for path/URL insertion.
- Finish marked-text composition before Save, view/file changes and Quit snapshots. Ordinary autosave must not interrupt an active IME composition.
- Compile off the UI thread. Preserve the last successful PDF on compilation failure. Use PDFKit page rendering on demand and bounded app-owned caches. Keep export revision checks.
- Preflight all files before writes. External conflicts, deletion, unreadable UTF-8 and newly created dependency collisions must not overwrite another file. Selecting the disk version keeps discarded local writing in a separate durable conflict recovery copy. Save As rebases literal references when relocating a nested entry and preserves unrelated source/dependencies.
- `NativeState` names the SwiftUI State property wrapper explicitly for the CLT SDK's macro/plugin compatibility. Understand that workaround before replacing it.

## Editing behavior to preserve

- Cmd-1/2/3 selects Write/Source/Preview. Cmd-K opens application commands; `/` opens formatting/insertion beside the caret with filtering, arrows, Return and Escape.
- Typed characters remain visible, including incomplete `=`, `-` and `+` markers. Space completes supported heading/list shortcuts outside tables.
- Return makes a paragraph; Shift-Return makes a soft line break. Lists continue on Return and exit on an empty item. Return within a table makes a cell paragraph.
- Table insertion immediately creates an empty 2×2 table and focuses its first cell. Tab/Shift-Tab navigates cells; Tab at the end adds a row. Native row/column controls and context menus edit dimensions in place; do not duplicate cell editing in a sheet. Cell slash menus expose only supported cell operations.
- Structured clipboard preserves block kinds and inline marks; paste at a mid-paragraph caret splits there. Source clipboard contains exact plain source.
- Handles reveal only near the left text edge or handle gutter, use open-hand/closed-hand cursors, and offer Turn into, Duplicate and Delete. Exclude the current kind from Turn into. Dragging shows a translucent block preview, hides other handles and draws one insertion line between blocks.
- Keep the heading hierarchy collapsible and titles restrained; use the leading native toolbar toggle to show/hide it and retain the floating shadow. Use the first H1 as its title, ordinary arrow navigation and native click-drag section movement (closed hand only while moving); do not add a reorder mode or a pin button. The footer’s “Lock section order” toggle disables only sidebar moves; text/block editing stays available. Let NSDocument supply the native Edited label. In the taller unified toolbar it appears beneath the title; keep that default layout.

## Build, run and verify

Use the repository scripts, which package the native parser/compiler and sign the app:

```sh
bash scripts/build.sh          # debug frontend, release Rust components
bash scripts/build.sh release  # optimized frontend
open build/blank_.app
bash scripts/check.sh          # release build and full acceptance suite
```

Requirements: Swift 6 with a macOS 26 or 27 SDK, Rust 1.98.1 (root `rust-toolchain.toml`, including rustfmt) and Python 3 for checks. First builds download locked Rust dependencies; `BLANK_OFFLINE=1` requires cached dependencies. `BLANK_SDK_PATH` selects an installed SDK by absolute path. Both configurations update the **same** `build/blank_.app`; quit/reopen to test a newly built version. Keep `.build` and the shared root `target/` cache for iteration unless cleanup is needed; avoid accumulating alternate app bundles.

The build script guards SDK 27-only toolbar APIs at compile time and runtime, targets macOS 26, rewrites the parser dependency to the adjacent bundled dylib and verifies the ad-hoc signature. Do not bypass that packaging step by distributing the raw Swift executable. Verify relocated bundles when changing packaging; a build that works only with libraries in the checkout is not portable.

`scripts/check.sh` runs production-model checks, release workspace Rust tests, parser formatting checks, the bundled official compiler and native editing/file acceptance from a relocated app bundle, launched outside the checkout with development library paths cleared. `scripts/check-bundle.sh [app]` can repeat the packaging checks without rebuilding. The model harness is `BlankCoreChecks`, not XCTest in this CLT setup. Native checks need a logged-in macOS window-server session; restricted execution may require ordinary tool escalation. Use disposable documents and `BLANK_DATA_DIR` to isolate recovery data. The harness restores clipboard/recents and cleans temporary data. Do not test destructive file behavior on user documents or leave input tracing enabled.

Run checks appropriate to the change. Editing/model changes warrant meaningful Unicode, selection, history, composition and clipboard regressions, not tests that merely mirror implementation. Visually inspect typography/layout/interaction changes using the actual app. Update the README when behavior, remaining work or evidence changes. Measure CPU/memory/latency and state measurement limits; do not promise resource use without evidence.

GitHub Actions builds/checks macOS 26 and Xcode 27 and uploads app archives. Publishing a release (including a prerelease) builds its tagged commit, then attaches `blank_-macos-arm64.zip` and `SHA256SUMS` after both jobs pass. Use tags `vX.Y.Z` (optional prerelease/build suffix); `BLANK_VERSION` sets the app's numeric bundle version before signing. The distributed SDK 27 build runs on macOS 26+ and enables the tab role on macOS 27. Release upload is retryable and replaces assets of the same names without changing release notes. It does not create or publish a release itself. These apps are ad-hoc signed; notarization and Intel support are not verified. GitHub caches are branch-scoped, so the first build on a new/default branch can be slow.

## Remaining work and working style

Keep the functionality backlog and user-facing development documentation in the README, concise and current; do not recreate a separate docs folder. Real IME candidate panels, VoiceOver, bidirectional navigation, live Zotero and several broader file/window/object scenarios remain unverified; synthetic/native acceptance does not establish physical-session coverage. Large-table editing and full Source reprojection still need performance work. Keep these distinctions accurate.

Favor small, native improvements and fixes over adding UI complexity. Proceed with authorized local edits, builds and disposable testing; do not repeatedly ask for permission already given. Preserve user changes, make reviewable milestone commits, and merge/push only within the user's authorized scope. Do not infer permission to message others. Use independent review or parallel agents when the user requests it, rather than automatically delegating every task.
