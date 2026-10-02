import { EditorState, TextSelection } from "prosemirror-state";

// Selections may include section wrappers (Select All), or span several files.
// Replace their contents, keeping each section's source identity intact.
export function replaceAcrossSections(state: EditorState, text = "") {
  const { from, to, $from, $to } = state.selection;
  if (
    from === to ||
    ($from.depth > 0 && $to.depth > 0 && $from.node(1) === $to.node(1))
  )
    return null;

  const ranges: { from: number; to: number }[] = [];
  state.doc.forEach((section, offset) => {
    const lo = Math.max(from, offset + 1);
    const hi = Math.min(to, offset + section.nodeSize - 1);
    if (lo < hi) ranges.push({ from: lo, to: hi });
  });
  if (!ranges.length) return null;
  const tr = state.tr;
  for (const range of ranges.reverse()) tr.delete(range.from, range.to);
  tr.setSelection(
    TextSelection.near(tr.doc.resolve(Math.min(from, tr.doc.content.size))),
  );
  if (text) tr.insertText(text);
  return tr.scrollIntoView();
}
