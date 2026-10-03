# Rust prototype validation

Branch: `codex/rust-native-prototype`. Date: 2026-10-03.

The application now lives in a Rust Cargo workspace. The previous Go/Wails and frontend implementation is available in Git history; its test results do not certify this rewrite.

## Evidence

- Document transaction tests cover exact source preservation, Unicode boundaries, nested formatting, empty insertion slots, Return, list continuation/exit, source grouping, block moves/duplication/deletion and shared history.
- Actual egui input tests cover typing and undo, character-by-character heading/list spacing, repeated Return and joins, formatting shortcuts, slash filtering and cancellation, command navigation, source pair insertion/deletion and accessibility focus-node validity.
- Compiler integration checks exercise the exact original tutorial, PDF bytes, native PNG pages, source maps, invalid-source diagnostics and compatibility of requests without native rendering.
- The macOS packaged application has been launched and visually inspected for the tutorial typography/sidebar, caret-anchored slash menu and full-area colored source view and successful two-page tutorial preview. Native menus, keyboard Undo, slash-to-heading conversion, heading spacing, block command popup and Option-arrow block movement have been exercised. The pointer-drag regression passes through actual egui input; native automation did not establish a completed pointer drag, which remains a manual acceptance item.
- All 33 application/document tests and both isolated library-assessment tests pass. Clippy runs with warnings denied. Standard Cargo checks and tests use the root workspace. `bash scripts/check.sh` is the reproducible validation entry point.

## Current boundaries

This is an editor/GUI trial, not complete feature parity. The original tutorial is preserved exactly, including instructions for features awaiting a port.

Remaining: multi-file rich projections and chapter/section movement, tables and figures as structured editors, images/citations/Zotero/footnotes insertion dialogs, links, search, settings, statistics dialogs, multi-window sessions, recovery and external-edit reconciliation.

The toolkit draws its scrollbar; it is positioned at the right window edge but is not a native AppKit scrollbar. Full native scroll physics, VoiceOver/IME integration and grapheme-aware rich cursor movement need further validation. macOS is exercised; Linux/Windows behavior is not yet certified.

Projection and layout still scan the document, and preview rasterizes pages eagerly. Large-document latency, multilingual shaping/input, page virtualization and compiler/font cache limits remain acceptance work. Undo holds up to 200 source snapshots.

See [the library assessment](native-assessment.md) for alternatives and measured iteration/resource costs. Earlier Go/frontend acceptance claims and demo footage are not validation of the Rust application.
