import { EditorState, TextSelection } from "prosemirror-state";

// Interpret newly typed Typst markup only in Write, never on load,
// paste, source edits or while an IME composition is in progress.
export function typingShortcut(
  state: EditorState,
  from: number,
  to: number,
  text: string,
) {
  if (from !== to || text.length !== 1) return null;
  const $from = state.doc.resolve(from);
  if (
    !$from.parent.isTextblock ||
    $from.marks().some((m) => m.type.name === "code")
  )
    return null;
  const start = $from.start();
  const before =
    $from.parent.textBetween(0, $from.parentOffset, "\n", "\ufffc") + text;
  const heading = before.match(/^(=+) $/);
  if (heading && $from.depth === 2 && $from.parent.type.name === "paragraph") {
    const tr = state.tr
      .delete(start, from)
      .setNodeMarkup($from.before(), state.schema.nodes.heading, {
        ...$from.parent.attrs,
        level: heading[1].length,
        prefix: "",
        suffix: "",
      });
    return tr.setSelection(TextSelection.create(tr.doc, start));
  }
  if (text !== "*" && text !== "_") return null;
  const delimiter = text;
  const close = before.length - 1;
  if (before[close - 1] === delimiter) return null;
  const open = before.lastIndexOf(delimiter, close - 1);
  if (
    open < 0 ||
    before[open - 1] === delimiter ||
    before[open - 1] === "\\" ||
    before[open + 1] === delimiter
  )
    return null;
  const inner = before.slice(open + 1, close);
  if (!inner || /^\s|\s$/.test(inner) || /[\n\ufffc]/.test(inner)) return null;
  // Typst emphasis delimiters inside words are literal (e.g. snake_case).
  if (
    /\p{L}|\p{N}/u.test(before[open - 1] || "") &&
    /\p{L}|\p{N}/u.test(inner[0])
  )
    return null;
  const tr = state.tr.insertText(text, from, to);
  tr.delete(start + close, start + before.length);
  tr.delete(start + open, start + open + 1);
  const lo = start + open,
    hi = lo + inner.length;
  tr.addMark(
    lo,
    hi,
    state.schema.marks[delimiter === "*" ? "strong" : "em"].create(),
  );
  tr.setSelection(TextSelection.create(tr.doc, hi));
  tr.setStoredMarks(state.storedMarks ?? $from.marks());
  return tr;
}
