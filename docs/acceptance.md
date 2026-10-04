# Native acceptance

## Architecture evaluation

The installed macOS 27 SDK was inspected directly. The attributed `TextEditor` initializer accepts `Binding<AttributedString>` and optional `Binding<AttributedTextSelection>` (macOS 26+). It supports selection/typing attributes and transformations. It does not expose NSTextView's pre-edit delegate, marked-text lifecycle, caret screen rectangles, custom clipboard overrides, or the block mouse tracking required by this editor. NSTextView is chosen for those hooks and macOS 14 compatibility, not because SwiftUI cannot edit rich text.

TextKit 2 is explicitly requested with `NSTextView(usingTextLayoutManager: true)`. Geometry uses native `firstRect(forCharacterRange:actualRange:)` and insertion-position hit testing. No NSLayoutManager query is used. The native acceptance executable checks `textLayoutManager != nil` at startup, after view switches, and after marked-text composition. It passed those checks. Tables will use attachment views rather than assuming NSTextTable supports this pipeline.

Apple references: [TextKit](https://developer.apple.com/documentation/appkit/textkit), [NSTextView](https://developer.apple.com/documentation/appkit/nstextview), [What's new in TextKit and text views](https://developer.apple.com/videos/play/wwdc2022/10090/). Accessing `layoutManager` may switch a view to TextKit 1; this implementation avoids it.

## Checks to date

2026-10-04, Apple Silicon, macOS 27.0.1, Swift 6.4, Rust 1.98.1, Typst 0.15.1.

- Both pinned Rust builds pass offline.
- Debug .app builds and ad-hoc signature verification passes.
- Ten standalone model checks pass: Unicode mapping, lossless styled edits, lists, joining, structured clipboard, grouped history/selections, cross-mark deletion, consecutive code, section movement, Unicode patch inverses.
- Initial native acceptance passes: TextKit 2, focused empty launch, whole-string typing/Unicode, Return, selection/bold, Write clipboard, exact Source copy, view switching, shared undo/redo, synthetic Japanese marked-text composition.
- Real keyboard inspection found trailing spaces being trimmed by projection. This was fixed and an incremental-character test added. Retest is pending.

Command Line Tools lack XCTest on this machine. `BlankCoreChecks` is a standalone executable exercising the production model. No XCTest installation is necessary. The macOS 27 SDK State macro has no CLT plugin; `NativeState` aliases the stable SwiftUI property wrapper.

Performance, PDF integration, object rendering, scrolling, native file handling and sustained keyboard acceptance remain to be measured/verified. See parity.md for actual gaps.
