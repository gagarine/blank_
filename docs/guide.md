# Using the Rust prototype

Open `build/bin/blank-native.app`, or run `bash scripts/dev.sh --demo`. File → Open accepts a `.typ` file. New Document creates an unsaved document in the current window; replacing unsaved writing prompts first. Multi-window sessions are not yet ported.

## Writing

Write (⌘1) presents serif text on a white surface with an optional contents sidebar. Editable blocks include paragraphs, headings, simple lists and bold/italic. Unknown Typst remains a preserved source object; use Source for those expressions.

Return splits paragraphs. In a list, Return continues the list; Return on an empty item exits it. Typing `= `, `== ` or `=== ` at the start converts a paragraph into a heading; `- ` and `+ ` start lists. Typing `*bold*` or `_italic_` applies the corresponding formatting.

Type `/` to open a menu beside the insertion point. Continue typing to filter, use ↑/↓ and Return to choose, or Escape to retain the literal text. The current menu supports block transformations. Hover beside a block to reveal its dots: drag to reorder, or click for Turn into, Duplicate and Delete. ⌥↑/↓ also moves a block. The source transaction participates in shared undo.

⌘K opens searchable app commands. Global commands also appear in standard macOS menus. ⌘⇧L shows or hides the sidebar; click a heading to navigate.

## Source and preview

Source (⌘2) fills the editing area with syntax-colored Typst. Headings are larger, and literal bold/italic markup uses the corresponding font faces, including nested marks and `#strong[...]` / `#emph[...]` content. All syntax remains visible; copying a selection puts only its exact plain Typst text on the clipboard. Presentation follows parsed literal markup rather than evaluating arbitrary Typst style code.

Parentheses, brackets, braces and quotes pair, selected text can be wrapped, closing characters can be skipped and Backspace removes an empty pair. Pairing is basic; language-context-sensitive completion and IME composition remain work to validate.

Preview (⌘3) compiles through the bundled Rust Typst helper. Invalid source shows diagnostics and preserves the last successful preview. Clicking preview text chooses the nearest source anchor. Export PDF requires a successful current document revision. Write and Source do not rasterize previews.

Both editors share the canonical source and undo/redo history. Unchanged source remains intact. Custom code, source expressions and comments can be inspected and edited through Source.

## Saving

⌘S asks for a location for a new document. Saved documents autosave after 650 ms of inactivity. If the on-disk file changes, the app blocks overwriting and offers Save As. Closing unsaved writing prompts to save, discard or keep writing. Crash recovery and live external-edit reconciliation are not yet ported.

The original tutorial is bundled unchanged. Its table editing, research insertion, settings, multi-window and chapter instructions describe the target workflow; those features are not all implemented in this prototype. See [validation and remaining work](acceptance.md).
