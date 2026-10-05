# Go reference audit

Reference: `codex/legacy-go`, inspected safely from a Git archive. Evidence comes from App.tsx, RichEditor.tsx, SourceEditor.tsx, projection.ts, blockCommands.ts, ContentsSidebar.tsx, Settings.tsx, Statistics.tsx, sectionEditing.ts, internal/document, internal/zotero, cmd/blank_, the unchanged tutorial, guide and acceptance notes. The Rust README supplied additional roadmap items; it was not treated as a complete feature specification.

Native framework defaults take precedence over early Go presentation choices. MCP/agent access will be designed for the native app rather than reproducing the Go API.

| Feature | Swift state | Evidence or remaining gap |
|---|---|---|
| Launch/New/Open/recents/templates/rename | Empty focused launch, native menus and separate windows | Startup, include opening, rename and Save As checked; recent-menu/template pointer checks pending |
| Reading typography and white paper | System-installed Iowan Old Style, real faces, native metrics | Native tutorial/new-document screenshots checked; ligature/complex wrapping matrix pending |
| Native macOS window/toolbar | macOS 26+ standard Liquid Glass NSToolbar; macOS 27 tab role | Real Cmd-1/Cmd-2 tab synchronization/focus and scrolling beneath glass checked |
| Typing/selection/Unicode/shared history | NSTextView/TextKit 2; range transactions | Model/native acceptance passes; physical latency, bidi and real IME candidates unverified |
| Bold/italic and typing shortcuts | Syntax-backed commands and typed markup | Selected formatting, toggles inside words, repeated typing and nested shortcuts checked |
| Slash/app commands | Caret popover and SwiftUI sheet, filtering/arrows/Return/Escape | Real slash filtering/keyboard choice checked; menu geometry corrected; app-command pointer inspection pending |
| Splitting/joining/list continuation/empty exit | Source transactions retaining inline formatting | Model/native Return, Shift-Return, empty slots, headings, selected replacement/undo and list continuation/exit pass |
| Clipboard | Exact Source text, structured internal Write, external RTF and images | Native internal/plain clipboard passes; external list/heading kinds unverified |
| Block handles/menu/drag | Native cursors, translucent snapshot, one insertion line | Real pointer block reorder and native cursor/preview/centered-line checks pass; object-adjacent and long-document drag coverage pending |
| Hierarchy/section movement | Collapsible outline with elision and source section moves | Movement checked; pointer and repeated-title identity checks pending |
| Scrolling at viewport edge | NSScrollView independent of text padding | Implemented; all-view/secondary-window long-document scrolling pending |
| Source characters/colors/fonts/delimiters | Native attributed full source, literal delimiters and indent continuation | Exact clipboard/native delimiters, explicit bold/italic faces and heading sizes checked; large-file styling remains full-file |
| Preview/PDF/navigation/error retention | Background official compiler, native PDFKit/source maps | Compiler protocol, error retention, queued export and native page-counter notification pass; passage navigation/physical scroll inspection pending |
| Tables | Native NSTableView grid and NSTextField cells, Tab/Shift-Tab/final Tab row, dimensions sheet | Mounting, Unicode typing, shared cell undo/redo/focus and valid row addition pass. Rows have fixed height; rich cell styling and tall/multiline content need more work. Embedded cell controls are not exposed in the outer NSTextView accessibility tree in current inspection; VoiceOver needs acceptance. All dimension cases pending |
| Images/figures/captions/drop/paste | Native importing and NSImageView/PDF thumbnails, bounded cache | Native PNG/caption PDF export passes; PDF-page/size editing and SVG/multipage/drop variants pending |
| Links/footnotes/math/labels/references | Native insertion sheets, conservative inline/source projection | Compiler fixture passes; existing-object editing needs refinement |
| Zotero/citations/bibliography | Local API, stable keys, saved metadata/refresh, preset styles | Implemented; live integration, library picker, custom CSL and citation UI acceptance pending |
| Multi-file manuscripts | Literal include loading and independent file editors; local imports as dependencies | Live graph refresh, directory creation events, include reordering/undo, import-aware Save As and in-memory nested compilation implemented; continuous view/repeated occurrences and dynamic dependencies pending |
| Search/replace/statistics | Active/project search and per-file/project counts, file metadata | Implemented; includes parsed from AST, prose counts checked; project grouping and continuous occurrences pending |
| Settings/focus/typewriter | Persisted installed fonts, size/colors, dark option and focus modes | Implemented; synchronization across windows and system-theme refinement pending |
| Document windows/Window menu | Native independent NSWindow sessions | Implemented; expanded secondary-window/lifetime/accessibility acceptance pending |
| Autosave/recovery/external changes | Debounced writes, guarded collisions/conflicts/deletions, recovery | Disposable file checks pass; disjoint merge and relaunch/disk failure matrix pending |
| Agent/MCP/selective agent undo | Planned native interface; disabled by default design | Not implemented; includes atomic revision-checked multi-file edits and per-window access |

This records actual implementation and gaps. Automated input does not establish pointer, VoiceOver, real IME, bidirectional or release-distribution acceptance. Windows/Linux are outside the Swift frontend scope.
