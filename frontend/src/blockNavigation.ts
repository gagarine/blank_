import { EditorState, NodeSelection, TextSelection } from "prosemirror-state";
import type { EditorView } from "prosemirror-view";
import { blockAt } from "./blockCommands";

// Stay inside the originating section/file, including at chapter boundaries.
// Only explicit navigation creates a paragraph; opening a file never changes it.
export function paragraphBeside(
  state: EditorState,
  pos: number,
  direction: -1 | 1,
) {
  const $pos = state.doc.resolve(pos);
  const node = $pos.nodeAfter;
  if ($pos.depth !== 1 || !node?.isBlock || node.isTextblock) return null;
  const at = direction < 0 ? pos : pos + node.nodeSize;
  const $at = state.doc.resolve(at);
  const neighbor = direction < 0 ? $at.nodeBefore : $at.nodeAfter;
  const tr = state.tr;
  if (neighbor?.isTextblock) {
    return tr
      .setSelection(
        TextSelection.create(tr.doc, direction < 0 ? at - 1 : at + 1),
      )
      .scrollIntoView();
  }
  tr.insert(
    at,
    state.schema.nodes.paragraph.create({ path: $pos.parent.attrs.path }),
  );
  return tr.setSelection(TextSelection.create(tr.doc, at + 1)).scrollIntoView();
}

export function exitBlock(state: EditorState, direction: -1 | 1) {
  const { selection } = state;
  const pos = blockAt(state.doc, selection.from);
  if (pos === null) return null;
  if (!(selection instanceof NodeSelection)) {
    if (!selection.empty) return null;
    const { $from } = selection;
    let depth = $from.depth;
    while (depth > 1 && $from.node(depth).type.name !== "table") depth--;
    if ($from.node(depth).type.name !== "table") return null;
    const row = $from.index(depth);
    if (row !== (direction < 0 ? 0 : $from.node(depth).childCount - 1))
      return null;
    const cell = $from.node(depth + 2);
    if ($from.index(depth + 2) !== (direction < 0 ? 0 : cell.childCount - 1))
      return null;
  }
  return paragraphBeside(state, pos, direction);
}

export function blockArrow(view: EditorView, event: KeyboardEvent) {
  if (
    !view.editable ||
    view.composing ||
    event.isComposing ||
    event.shiftKey ||
    event.altKey ||
    event.metaKey ||
    event.ctrlKey
  )
    return false;
  const nodeSelected = view.state.selection instanceof NodeSelection;
  let direction: -1 | 1;
  if (event.key === "ArrowUp" || (nodeSelected && event.key === "ArrowLeft"))
    direction = -1;
  else if (
    event.key === "ArrowDown" ||
    (nodeSelected && ["ArrowRight", "Enter"].includes(event.key))
  )
    direction = 1;
  else return false;
  // Let the browser move within wrapped cell text before exiting its last line.
  if (!nodeSelected && !view.endOfTextblock(direction < 0 ? "up" : "down"))
    return false;
  const tr = exitBlock(view.state, direction);
  if (!tr) return false;
  view.dispatch(tr);
  view.focus();
  return true;
}

export function clickBesideBlock(view: EditorView, event: MouseEvent) {
  if (
    !view.editable ||
    view.composing ||
    event.button !== 0 ||
    event.shiftKey ||
    event.altKey ||
    event.ctrlKey ||
    event.metaKey
  )
    return false;
  const target = event.target;
  if (
    !(target instanceof Element) ||
    target.closest(
      "button, input, textarea, a, .block-controls, .table-controls",
    )
  )
    return false;
  const column = view.dom.getBoundingClientRect();
  if (event.clientX < column.left || event.clientX > column.right) return false;
  const hit = view.posAtCoords({ left: event.clientX, top: event.clientY });
  let pos = hit ? blockAt(view.state.doc, hit.pos) : null;
  if (pos === null) {
    // The space above/below the editor is outside its normal hit testing.
    const doc = view.state.doc;
    const first = 1;
    const last = doc.content.size - 1 - doc.lastChild!.lastChild!.nodeSize;
    const firstDOM = view.nodeDOM(first),
      lastDOM = view.nodeDOM(last);
    if (
      firstDOM instanceof HTMLElement &&
      event.clientY < firstDOM.getBoundingClientRect().top
    )
      pos = first;
    else if (
      lastDOM instanceof HTMLElement &&
      event.clientY > lastDOM.getBoundingClientRect().bottom
    )
      pos = last;
    else return false;
  }
  const dom = view.nodeDOM(pos);
  if (!(dom instanceof HTMLElement)) return false;
  const box = dom.getBoundingClientRect();
  if (event.clientY >= box.top && event.clientY <= box.bottom) return false;
  const direction = event.clientY < box.top ? -1 : 1;
  const tr = paragraphBeside(view.state, pos, direction);
  if (!tr) return false;
  event.preventDefault();
  view.dispatch(tr);
  view.focus();
  return true;
}
