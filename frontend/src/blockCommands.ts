import { EditorState, Selection } from "prosemirror-state";
import type { Node } from "prosemirror-model";

export type InsertKind =
  | "citation"
  | "footnote"
  | "equation"
  | "image"
  | "table"
  | "link"
  | "label"
  | "reference";
export const slashCommands = [
  {
    id: "paragraph",
    label: "Paragraph",
    hint: "Plain text",
    keywords: "text",
    symbol: "¶",
  },
  {
    id: "heading1",
    label: "Heading 1",
    hint: "Chapter title",
    keywords: "title h1",
    symbol: "H₁",
  },
  {
    id: "heading2",
    label: "Heading 2",
    hint: "Section",
    keywords: "subtitle h2",
    symbol: "H₂",
  },
  {
    id: "heading3",
    label: "Heading 3",
    hint: "Subsection",
    keywords: "subtitle h3",
    symbol: "H₃",
  },
  {
    id: "bullet",
    label: "Bulleted list",
    hint: "Unordered items",
    keywords: "list",
    symbol: "•",
  },
  {
    id: "number",
    label: "Numbered list",
    hint: "Ordered items",
    keywords: "list",
    symbol: "1.",
  },
  {
    id: "quote",
    label: "Quotation",
    hint: "Block quotation",
    keywords: "quote",
    symbol: "❝",
  },
  {
    id: "image",
    label: "Image and caption",
    hint: "Insert a figure",
    keywords: "picture photo media pdf svg",
    symbol: "▧",
  },
  {
    id: "table",
    label: "Table",
    hint: "Rows and columns",
    keywords: "grid",
    symbol: "▦",
  },
  {
    id: "citation",
    label: "Citation",
    hint: "Search Zotero",
    keywords: "reference bibliography",
    symbol: "@",
  },
  {
    id: "footnote",
    label: "Footnote",
    hint: "An explanatory note",
    keywords: "note",
    symbol: "¹",
  },
  {
    id: "equation",
    label: "Equation",
    hint: "Typst mathematics",
    keywords: "math formula",
    symbol: "∑",
  },
  {
    id: "link",
    label: "Link",
    hint: "Link to a web page",
    keywords: "url",
    symbol: "↗",
  },
  {
    id: "label",
    label: "Label",
    hint: "Name this position",
    keywords: "anchor",
    symbol: "<>",
  },
  {
    id: "reference",
    label: "Cross-reference",
    hint: "Refer to a label",
    keywords: "xref",
    symbol: "↪",
  },
] as const;
export function matchingCommands(query: string) {
  const words = query.toLowerCase().trim().split(/\s+/);
  return slashCommands.filter((c) =>
    words.every((w) =>
      `${c.label} ${c.hint} ${c.keywords}`.toLowerCase().includes(w),
    ),
  );
}

// Positions here are ProseMirror UTF-16 positions, never source byte offsets.
export function blockAt(doc: Node, pos: number): number | null {
  const $pos = doc.resolve(pos);
  if ($pos.depth >= 2) return $pos.before(2);
  if ($pos.depth === 1 && $pos.nodeAfter?.isBlock) return pos;
  return null;
}
export function moveBlock(state: EditorState, from: number, to: number) {
  const $from = state.doc.resolve(from),
    $to = state.doc.resolve(to);
  const node = $from.nodeAfter;
  if ($from.depth !== 1 || $to.depth !== 1 || !node?.isBlock)
    throw new Error("Choose a position between blocks.");
  if ($from.start(1) !== $to.start(1))
    throw new Error(
      "Drag blocks within their chapter. Chapter boundaries stay in place.",
    );
  if (to >= from && to <= from + node.nodeSize) return null;
  const tr = state.tr.delete(from, from + node.nodeSize);
  const at = tr.mapping.map(to);
  tr.insert(at, node);
  tr.setSelection(Selection.near(tr.doc.resolve(at + 1)));
  return tr.scrollIntoView();
}
export function moveBlockBy(
  state: EditorState,
  from: number,
  direction: -1 | 1,
) {
  const $pos = state.doc.resolve(from),
    node = $pos.nodeAfter;
  if ($pos.depth !== 1 || !node) return null;
  if (direction === -1) {
    const previous = $pos.nodeBefore;
    return previous ? moveBlock(state, from, from - previous.nodeSize) : null;
  }
  const after = from + node.nodeSize;
  const next = state.doc.resolve(after).nodeAfter;
  return next ? moveBlock(state, from, after + next.nodeSize) : null;
}

export function slashTransaction(
  state: EditorState,
  from: number,
  to: number,
  id: string,
) {
  const tr = state.tr.delete(from, to);
  const $pos = tr.doc.resolve(from);
  if ($pos.depth !== 2 || !$pos.parent.isTextblock)
    throw new Error("Place the cursor in a text block to insert a block.");
  const attrs: Record<string, unknown> = {
    ...$pos.parent.attrs,
    prefix: "",
    suffix: "",
  };
  let type = id;
  if (id.startsWith("heading")) {
    type = "heading";
    attrs.level = Number(id.slice(-1));
  }
  if (id === "bullet" || id === "number") {
    type = "list_item";
    attrs.ordered = id === "number";
  }
  if (id === "quote") type = "blockquote";
  if (["paragraph", "heading", "list_item", "blockquote"].includes(type))
    tr.setNodeMarkup($pos.before(2), state.schema.nodes[type], attrs);
  return tr.setSelection(Selection.near(tr.doc.resolve(from))).scrollIntoView();
}

export function blockAction(state: EditorState, pos: number, action: string) {
  const $pos = state.doc.resolve(pos),
    node = $pos.nodeAfter;
  if ($pos.depth !== 1 || !node) return null;
  if (action === "delete") {
    const tr = state.tr.delete(pos, pos + node.nodeSize);
    return tr
      .setSelection(
        Selection.near(tr.doc.resolve(Math.min(pos, tr.doc.content.size))),
      )
      .scrollIntoView();
  }
  if (action === "duplicate") {
    // Retain the original source span for an exact first copy; reanchoring
    // assigns independent identities to both blocks before subsequent edits.
    const tr = state.tr.insert(pos + node.nodeSize, node);
    return tr
      .setSelection(Selection.near(tr.doc.resolve(pos + node.nodeSize + 1)))
      .scrollIntoView();
  }
  if (!node.isTextblock) return null;
  return slashTransaction(state, pos + 1, pos + 1, action);
}
