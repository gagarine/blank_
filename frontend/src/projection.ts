import { Schema, Node as PMNode, Mark, Fragment } from "prosemirror-model";
import { tableNodes } from "prosemirror-tables";
import type { Project, Parsed, Syntax, Edit } from "./types";
import { byteSlice, byteLength, minimalEdit } from "./types";

const attrs = {
  id: { default: "" },
  path: { default: "" },
  start: { default: 0 },
  end: { default: 0 },
  raw: { default: "" },
  prefix: { default: "" },
  suffix: { default: "" },
};
export const schema = new Schema({
  nodes: {
    doc: { content: "section+" },
    section: {
      content: "block+",
      isolating: true,
      defining: true,
      attrs: { ...attrs },
      toDOM: (n) => [
        "section",
        { "data-file": n.attrs.path, "data-section": n.attrs.id },
        0,
      ],
    },
    paragraph: {
      content: "inline*",
      group: "block",
      attrs,
      parseDOM: [{ tag: "p" }],
      toDOM: () => ["p", 0],
    },
    heading: {
      content: "inline*",
      group: "block",
      defining: true,
      parseDOM: [1, 2, 3, 4, 5, 6].map((level) => ({
        tag: "h" + level,
        attrs: { level },
      })),
      attrs: { ...attrs, level: { default: 1 } },
      toDOM: (n) => ["h" + Math.min(6, n.attrs.level), 0],
    },
    list_item: {
      content: "inline*",
      group: "block",
      parseDOM: [{ tag: "li" }, { tag: ".list-item" }],
      attrs: { ...attrs, ordered: { default: false } },
      toDOM: (n) => [
        "div",
        { class: "list-item", "data-marker": n.attrs.ordered ? "1." : "•" },
        0,
      ],
    },
    blockquote: {
      content: "inline*",
      group: "block",
      attrs,
      parseDOM: [{ tag: "blockquote" }],
      toDOM: () => ["blockquote", 0],
    },
    raw_block: {
      group: "block",
      atom: true,
      selectable: true,
      attrs: { ...attrs, kind: { default: "Typst" }, label: { default: "" } },
      toDOM: (n) => [
        "div",
        { class: "raw-block", "data-kind": n.attrs.kind },
        ["span", { class: "raw-label" }, n.attrs.label || n.attrs.kind],
        ["pre", {}, n.attrs.raw],
      ],
    },
    equation: {
      group: "block",
      atom: true,
      attrs: { ...attrs },
      toDOM: (n) => [
        "div",
        { class: "equation-block" },
        ["span", {}, "Equation"],
        ["code", {}, n.attrs.raw],
      ],
    },
    inline_atom: {
      inline: true,
      group: "inline",
      atom: true,
      attrs: { ...attrs, kind: { default: "source" }, label: { default: "" } },
      toDOM: (n) => [
        "span",
        {
          class: "inline-atom " + n.attrs.kind,
          title: "Click to edit " + n.attrs.kind,
        },
        n.attrs.label || n.attrs.raw,
      ],
    },
    ...tableNodes({
      tableGroup: "block",
      cellContent: "paragraph+",
      cellAttributes: {},
    }),
    text: { group: "inline" },
  },
  marks: {
    strong: {
      parseDOM: [{ tag: "strong" }, { tag: "b" }],
      toDOM: () => ["strong", 0],
    },
    em: { parseDOM: [{ tag: "em" }, { tag: "i" }], toDOM: () => ["em", 0] },
    code: { parseDOM: [{ tag: "code" }], toDOM: () => ["code", 0] },
    link: {
      attrs: { href: {} },
      inclusive: false,
      parseDOM: [
        {
          tag: "a[href]",
          getAttrs: (el) => ({
            href: (el as HTMLElement).getAttribute("href"),
          }),
        },
      ],
      toDOM: (m) => ["a", { href: m.attrs.href }, 0],
    },
  },
});
// Extend table's source metadata without introducing another document format.
const tableSpec = schema.spec.nodes.get("table")!;
export const writerSchema = new Schema({
  nodes: schema.spec.nodes.update("table", {
    ...tableSpec,
    attrs: { ...attrs, columns: { default: 2 }, gaps: { default: [] } },
  }),
  marks: schema.spec.marks,
});
const S = writerSchema;
export const escapeText = (s: string) =>
  s
    .replace(/[\\#@*_\$\[\]<>`]/g, "\\$&")
    .replace(/^(=|\+|-|\/)(?=\s)/gm, "\\$1");
function nodeAttrs(path: string, text: string, n: Syntax) {
  return {
    id: path + ":" + n.start,
    path,
    start: n.start,
    end: n.end,
    raw: byteSlice(text, n.start, n.end),
  };
}
function directMarkup(n: Syntax): Syntax | undefined {
  return n.children.find((c) => c.kind === "Markup");
}
function descendants(n: Syntax, kind: string): Syntax[] {
  if (n.kind === kind) return [n];
  return n.children.flatMap((c) => descendants(c, kind));
}
function inline(
  nodes: Syntax[],
  path: string,
  text: string,
  marks: readonly Mark[] = [],
): PMNode[] {
  const out: PMNode[] = [];
  for (let i = 0; i < nodes.length; i++) {
    let n = nodes[i];
    const raw = byteSlice(text, n.start, n.end);
    const a = nodeAttrs(path, text, n);
    if (n.kind === "Text" || n.kind === "Space" || n.kind === "SmartQuote") {
      if (raw) out.push(S.text(raw, marks));
      continue;
    }
    if (n.kind === "Strong" || n.kind === "Emph") {
      const body = directMarkup(n);
      if (body) {
        out.push(
          ...inline(body.children, path, text, [
            ...marks,
            S.marks[n.kind === "Strong" ? "strong" : "em"].create(),
          ]),
        );
        continue;
      }
    }
    if (n.kind === "Hash" && nodes[i + 1]) {
      const next = nodes[++i];
      n = { ...next, start: n.start };
      const source = byteSlice(text, n.start, n.end);
      let kind = "source",
        label = source;
      if (/^#cite\(/.test(source)) {
        kind = "citation";
        label = source.match(/<([^>]+)>/)?.[1] || "Citation";
      }
      if (/^#footnote\[/.test(source)) {
        kind = "footnote";
        label = "⁎ " + source.slice(10, -1);
      }
      if (/^#link\("/.test(source)) {
        const m = source.match(/^#link\("([^"\n]+)"\)\[([^\[\]]*)\]$/);
        if (m) {
          out.push(
            S.text(m[2], [...marks, S.marks.link.create({ href: m[1] })]),
          );
          continue;
        }
      }
      out.push(
        S.nodes.inline_atom.create(
          { ...nodeAttrs(path, text, n), kind, label },
          null,
          marks,
        ),
      );
      continue;
    }
    if (n.kind === "Ref") {
      out.push(
        S.nodes.inline_atom.create(
          { ...a, kind: "citation", label: raw.slice(1) },
          null,
          marks,
        ),
      );
      continue;
    }
    if (n.kind === "Label") {
      out.push(
        S.nodes.inline_atom.create(
          { ...a, kind: "label", label: raw },
          null,
          marks,
        ),
      );
      continue;
    }
    if (n.kind === "Raw" && raw.startsWith("`") && !raw.startsWith("```")) {
      out.push(
        S.nodes.inline_atom.create(
          { ...a, kind: "code", label: raw.slice(1, -1) },
          null,
          marks,
        ),
      );
      continue;
    }
    if (n.kind === "Equation") {
      out.push(
        S.nodes.inline_atom.create(
          { ...a, kind: "math", label: raw },
          null,
          marks,
        ),
      );
      continue;
    }
    out.push(
      S.nodes.inline_atom.create(
        {
          ...a,
          kind:
            n.kind === "LineComment" || n.kind === "BlockComment"
              ? "comment"
              : "source",
          label: raw,
        },
        null,
        marks,
      ),
    );
  }
  return out;
}
function table(n: Syntax, path: string, text: string): PMNode | null {
  const raw = byteSlice(text, n.start, n.end);
  const cols = raw.match(/^#table\(\s*columns:\s*(\d+)\s*,/);
  if (!cols) return null;
  const columns = Number(cols[1]);
  if (columns < 1 || columns > 20) return null;
  const cells = descendants(n, "ContentBlock");
  if (
    !cells.length ||
    cells.length % columns ||
    cells.some((c) => descendants(c, "ContentBlock").length > 1)
  )
    return null;
  const gaps: string[] = [];
  let cursor = n.start;
  const rows: PMNode[] = [];
  for (let i = 0; i < cells.length; i += columns) {
    const row = [];
    for (const cell of cells.slice(i, i + columns)) {
      gaps.push(byteSlice(text, cursor, cell.start));
      cursor = cell.end;
      const body = directMarkup(cell);
      const p = S.nodes.paragraph.create(
        { ...nodeAttrs(path, text, cell), prefix: "[", suffix: "]" },
        inline(body?.children || [], path, text),
      );
      row.push(S.nodes.table_cell.create(null, p));
    }
    rows.push(S.nodes.table_row.create(null, row));
  }
  gaps.push(byteSlice(text, cursor, n.end));
  return S.nodes.table.create(
    { ...nodeAttrs(path, text, n), columns, gaps },
    rows,
  );
}
export function projectDocument(
  project: Project,
  parsed: Record<string, Parsed>,
  active: string,
  continuous: boolean,
): PMNode {
  const sections: PMNode[] = [];
  const visit = (path: string, stack: string[], occurrence: string) => {
    const file = project.files[path],
      tree = parsed[path]?.tree;
    if (!file || !tree) return;
    if (stack.includes(path)) {
      return;
    }
    const text = file.text;
    let blocks: PMNode[] = [];
    let pending: Syntax[] = [];
    let start = 0;
    let chunk = 0;
    const flush = () => {
      // Whitespace between blocks belongs to source gaps, not editable DOM text.
      while (pending.length && pending[0].kind === "Text") {
        const n = pending[0],
          raw = byteSlice(text, n.start, n.end),
          leading = raw.match(/^\s+/)?.[0] || "";
        if (!leading) break;
        if (leading === raw) {
          pending.shift();
          continue;
        }
        pending[0] = { ...n, start: n.start + byteLength(leading) };
        break;
      }
      while (pending.length && pending.at(-1)!.kind === "Text") {
        const n = pending.at(-1)!,
          raw = byteSlice(text, n.start, n.end),
          trailing = raw.match(/\s+$/)?.[0] || "";
        if (!trailing) break;
        if (trailing === raw) {
          pending.pop();
          continue;
        }
        pending[pending.length - 1] = {
          ...n,
          end: n.end - byteLength(trailing),
        };
        break;
      }
      if (!pending.length) return;
      const first = pending[0],
        last = pending.at(-1)!;
      const n = { ...first, end: last.end };
      blocks.push(
        S.nodes.paragraph.create(
          nodeAttrs(path, text, n),
          inline(pending, path, text),
        ),
      );
      pending = [];
    };
    const section = (end: number) => {
      flush();
      if (blocks.length) {
        const compact: PMNode[] = [];
        for (const block of blocks) {
          const setup =
            block.type.name === "raw_block" &&
            /^#(?:set|show|let|import)\b/.test(block.attrs.raw);
          const previous = compact.at(-1);
          if (
            setup &&
            previous?.type.name === "raw_block" &&
            previous.attrs.label === "Document setup" &&
            !byteSlice(text, previous.attrs.end, block.attrs.start).trim()
          ) {
            compact[compact.length - 1] = previous.type.create({
              ...previous.attrs,
              end: block.attrs.end,
              raw: byteSlice(text, previous.attrs.start, block.attrs.end),
            });
          } else
            compact.push(
              setup
                ? block.type.create({ ...block.attrs, label: "Document setup" })
                : block,
            );
        }
        sections.push(
          S.nodes.section.create(
            {
              id: occurrence + ":" + chunk++,
              path,
              start,
              end,
              raw: byteSlice(text, start, end),
            },
            compact,
          ),
        );
        blocks = [];
      }
      start = end;
    };
    const nodes = tree.children;
    for (let i = 0; i < nodes.length; i++) {
      let n = nodes[i];
      let raw = byteSlice(text, n.start, n.end);
      if (n.kind === "Parbreak") {
        flush();
        continue;
      }
      if (n.kind === "Hash" && nodes[i + 1]) {
        const next = nodes[i + 1];
        const source = byteSlice(text, n.start, next.end);
        if (continuous && next.kind === "ModuleInclude") {
          const literal = source.match(/^#include\s+"([^"\n]+)"\s*$/);
          if (literal) {
            const base = path.split("/").slice(0, -1);
            const parts = literal[1].startsWith("/") ? [] : base;
            for (const piece of literal[1].split("/")) {
              if (piece === "..") parts.pop();
              else if (piece !== "." && piece) parts.push(piece);
            }
            const target = parts.join("/");
            if (
              project.files[target] &&
              !stack.includes(target) &&
              target !== path
            ) {
              section(n.start);
              visit(target, [...stack, path], occurrence + "/" + target);
              start = next.end;
              i++;
              continue;
            }
          }
        }
        // A stand-alone function or directive becomes a block; inline calls stay inline.
        const before = byteSlice(text, 0, n.start).split("\n").at(-1) || "";
        const after = byteSlice(text, next.end).split("\n")[0];
        if (!before.trim() && !after.trim()) {
          flush();
          n = { ...next, start: n.start };
          raw = source;
          i++;
          const grid = source.startsWith("#table(")
            ? table(n, path, text)
            : null;
          if (grid) {
            blocks.push(grid);
            continue;
          }
          const quote = source.match(/^#quote\(block:\s*true\)\[([\s\S]*)\]$/);
          if (quote) {
            const content = descendants(n, "ContentBlock")[0];
            const body = content && directMarkup(content);
            blocks.push(
              S.nodes.blockquote.create(
                {
                  ...nodeAttrs(path, text, n),
                  prefix: "#quote(block: true)[",
                  suffix: "]",
                },
                inline(body?.children || [], path, text),
              ),
            );
            continue;
          }
          blocks.push(
            S.nodes.raw_block.create({
              ...nodeAttrs(path, text, n),
              kind:
                next.kind === "ModuleInclude"
                  ? "Include"
                  : source.startsWith("#figure")
                    ? "Figure"
                    : source.startsWith("#image")
                      ? "Image"
                      : source.startsWith("#bibliography")
                        ? "Bibliography"
                        : "Typst",
              label: source.split("\n")[0].slice(0, 90),
            }),
          );
          continue;
        }
        pending.push(n, next);
        i++;
        continue;
      }
      if (
        n.kind === "Heading" ||
        n.kind === "ListItem" ||
        n.kind === "EnumItem"
      ) {
        flush();
        const body = directMarkup(n);
        if (body) {
          const a = {
            ...nodeAttrs(path, text, n),
            prefix: byteSlice(text, n.start, body.start),
            suffix: byteSlice(text, body.end, n.end),
          };
          const level = raw.match(/^=+/)?.[0].length || 1;
          blocks.push(
            S.nodes[n.kind === "Heading" ? "heading" : "list_item"].create(
              { ...a, level, ordered: n.kind === "EnumItem" },
              inline(body.children, path, text),
            ),
          );
          continue;
        }
      }
      if (n.kind === "Equation" && /^\$\s/.test(raw)) {
        flush();
        blocks.push(S.nodes.equation.create(nodeAttrs(path, text, n)));
        continue;
      }
      if (n.kind === "LineComment" || n.kind === "BlockComment") {
        flush();
        blocks.push(
          S.nodes.raw_block.create({
            ...nodeAttrs(path, text, n),
            kind: "Comment",
            label: raw,
          }),
        );
        continue;
      }
      pending.push(n);
    }
    section(byteLength(text));
    if (!sections.some((s) => s.attrs.path === path) && !continuous)
      sections.push(
        S.nodes.section.create(
          {
            id: occurrence + ":0",
            path,
            start: 0,
            end: byteLength(text),
            raw: text,
          },
          S.nodes.paragraph.create({
            ...attrsDefault(path),
            start: 0,
            end: byteLength(text),
            raw: text,
          }),
        ),
      );
  };
  visit(continuous ? project.entry : active, [], "root");
  if (!sections.length) {
    const f = project.files[active] || project.files[project.entry];
    sections.push(
      S.nodes.section.create(
        {
          id: "empty",
          path: f.path,
          start: 0,
          end: byteLength(f.text),
          raw: f.text,
        },
        S.nodes.paragraph.create(attrsDefault(f.path)),
      ),
    );
  }
  return S.nodes.doc.create(null, sections);
}
function attrsDefault(path: string) {
  return { id: "new", path, start: 0, end: 0, raw: "" };
}

function inlineString(n: PMNode) {
  let out = "",
    open: readonly Mark[] = [];
  const end = (m: Mark) =>
    m.type.name === "strong"
      ? "*"
      : m.type.name === "em"
        ? "_"
        : m.type.name === "code"
          ? "`"
          : "]";
  const begin = (m: Mark) =>
    m.type.name === "link"
      ? "#link(" + JSON.stringify(m.attrs.href) + ")["
      : end(m);
  n.forEach((child) => {
    let shared = 0;
    while (
      shared < open.length &&
      shared < child.marks.length &&
      open[shared].eq(child.marks[shared])
    )
      shared++;
    for (let i = open.length - 1; i >= shared; i--) out += end(open[i]);
    for (let i = shared; i < child.marks.length; i++)
      out += begin(child.marks[i]);
    open = child.marks;
    out += child.isText ? escapeText(child.text || "") : child.attrs.raw || "";
  });
  for (let i = open.length - 1; i >= 0; i--) out += end(open[i]);
  return out;
}
function serialize(n: PMNode, old?: PMNode): string {
  if (old && n.eq(old)) return old.attrs.raw;
  if (n.type.name === "raw_block" || n.type.name === "equation")
    return n.attrs.raw;
  if (n.type.name === "table") {
    const cells: PMNode[] = [];
    n.forEach((r) => r.forEach((c) => cells.push(c.firstChild!)));
    const gaps = n.attrs.gaps as string[];
    if (gaps.length === cells.length + 1) {
      let out = gaps[0];
      cells.forEach((c, i) => {
        out += "[" + inlineString(c) + "]" + gaps[i + 1];
      });
      return out;
    }
    return (
      "#table(columns: " +
      n.firstChild!.childCount +
      ",\n" +
      cells.map((c) => "  [" + inlineString(c) + "],").join("\n") +
      "\n)"
    );
  }
  const inner = inlineString(n);
  if (n.type.name === "heading")
    return "=".repeat(n.attrs.level) + " " + inner + (n.attrs.suffix || "");
  if (n.type.name === "list_item")
    return (
      (n.attrs.prefix || (n.attrs.ordered ? "+ " : "- ")) +
      inner +
      (n.attrs.suffix || "")
    );
  if (n.type.name === "blockquote") return "#quote(block: true)[" + inner + "]";
  return inner;
}

type RenderedSection = {
  text: string;
  blocks: { node: PMNode; raw: string; offset: number }[];
};
function renderSection(
  a: PMNode,
  b: PMNode,
  project: Project,
): RenderedSection {
  const oldNodes: PMNode[] = [];
  a.forEach((n) => oldNodes.push(n));
  let out = "";
  let previousIndex = -1;
  const blocks: RenderedSection["blocks"] = [];
  b.forEach((n, _offset, index) => {
    const orig = oldNodes.findIndex((o) => o.attrs.id === n.attrs.id);
    const matched = orig >= 0 ? oldNodes[orig] : undefined;
    if (index === 0)
      out += byteSlice(
        project.files[a.attrs.path].text,
        a.attrs.start,
        oldNodes[0]?.attrs.start ?? a.attrs.start,
      );
    else if (orig === previousIndex + 1 && orig > 0)
      out += byteSlice(
        project.files[a.attrs.path].text,
        oldNodes[orig - 1].attrs.end,
        oldNodes[orig].attrs.start,
      );
    else out += "\n\n";
    const raw = serialize(n, matched);
    blocks.push({ node: n, raw, offset: byteLength(out) });
    out += raw;
    previousIndex = orig;
  });
  out += byteSlice(
    project.files[a.attrs.path].text,
    oldNodes.at(-1)?.attrs.end ?? a.attrs.end,
    a.attrs.end,
  );
  return { text: out, blocks };
}
export function documentEdits(
  old: PMNode,
  next: PMNode,
  project: Project,
): Edit[] {
  if (old.childCount !== next.childCount)
    throw Error(
      "Chapter boundaries are preserved. Edit project structure in Source.",
    );
  const edits: Edit[] = [];
  for (let i = 0; i < old.childCount; i++) {
    const a = old.child(i),
      b = next.child(i);
    if (a.eq(b)) continue;
    if (a.attrs.id !== b.attrs.id)
      throw Error("Chapter boundaries cannot be moved by text editing.");
    const sameStructure =
      a.childCount === b.childCount &&
      Array.from(
        { length: a.childCount },
        (_, j) => a.child(j).attrs.id === b.child(j).attrs.id,
      ).every(Boolean);
    if (sameStructure) {
      for (let j = 0; j < a.childCount; j++) {
        const before = a.child(j),
          after = b.child(j);
        if (before.eq(after)) continue;
        const edit = minimalEdit(
          a.attrs.path,
          before.attrs.raw,
          serialize(after, before),
          before.attrs.start,
        );
        if (edit) edits.push(edit);
      }
      continue;
    }
    const edit = minimalEdit(
      a.attrs.path,
      a.attrs.raw,
      renderSection(a, b, project).text,
      a.attrs.start,
    );
    if (edit) edits.push(edit);
  }
  const unique = new Map<string, Edit>();
  for (const e of edits) {
    const key = e.path + ":" + e.start + ":" + e.end;
    if (unique.has(key) && unique.get(key)!.text !== e.text)
      throw Error("The same included passage was edited twice differently.");
    unique.set(key, e);
  }
  return [...unique.values()];
}
function moveOffset(offset: number, edits: Edit[]) {
  let delta = 0;
  for (const e of edits) {
    if (e.end <= offset && e.start < offset)
      delta += byteLength(e.text) - (e.end - e.start);
  }
  return offset + delta;
}
// Assign fresh source ranges after structural transactions (split/join/paste). A split
// duplicates ProseMirror attributes; retaining those ranges would edit the wrong paragraph.
export function reanchorDocument(
  old: PMNode,
  next: PMNode,
  project: Project,
  edits: Edit[],
): PMNode {
  const anchor = (
    node: PMNode,
    path: string,
    start: number,
    raw: string,
  ): PMNode => {
    let prefix = "",
      suffix = "";
    if (node.type.name === "heading") prefix = raw.match(/^=+\s+/)?.[0] || "";
    if (node.type.name === "list_item")
      prefix = raw.match(/^(?:-|\+|\d+\.)\s+/)?.[0] || "";
    if (node.type.name === "blockquote") {
      prefix = "#quote(block: true)[";
      suffix = "]";
    }
    const attrs = {
      ...node.attrs,
      id: path + ":" + start,
      path,
      start,
      end: start + byteLength(raw),
      raw,
      prefix,
      suffix,
    };
    if (node.type.name === "table") {
      let cursor = start;
      const gaps = node.attrs.gaps as string[];
      let cellIndex = 0;
      const rows: PMNode[] = [];
      node.forEach((row) => {
        const cells: PMNode[] = [];
        row.forEach((cell) => {
          const p = cell.firstChild!;
          const gap =
            gaps.length === node.childCount * row.childCount + 1
              ? gaps[cellIndex]
              : cellIndex === 0
                ? "#table(columns: " + row.childCount + ",\n  "
                : "\n  ";
          cursor += byteLength(gap);
          const body = inlineString(p);
          const child = anchor(p, path, cursor + 1, body);
          cells.push(cell.type.create(cell.attrs, child));
          cursor +=
            byteLength("[" + body + "]") +
            (gaps.length === node.childCount * row.childCount + 1 ? 0 : 1);
          cellIndex++;
        });
        rows.push(row.type.create(row.attrs, cells));
      });
      return node.type.create(attrs, rows, node.marks);
    }
    if (!node.inlineContent)
      return node.type.create(attrs, node.content, node.marks);
    const children: PMNode[] = [];
    let cursor = start + byteLength(prefix);
    let open: readonly Mark[] = [];
    const close = (m: Mark) =>
      m.type.name === "strong"
        ? "*"
        : m.type.name === "em"
          ? "_"
          : m.type.name === "code"
            ? "`"
            : "]";
    node.forEach((child) => {
      let shared = 0;
      while (
        shared < open.length &&
        shared < child.marks.length &&
        open[shared].eq(child.marks[shared])
      )
        shared++;
      for (let i = open.length - 1; i >= shared; i--)
        cursor += byteLength(close(open[i]));
      for (let i = shared; i < child.marks.length; i++) {
        const m = child.marks[i];
        cursor += byteLength(
          m.type.name === "link"
            ? "#link(" + JSON.stringify(m.attrs.href) + ")["
            : close(m),
        );
      }
      open = child.marks;
      if (child.isText) {
        children.push(child);
        cursor += byteLength(escapeText(child.text || ""));
      } else {
        const source = child.attrs.raw || "";
        children.push(
          child.type.create(
            {
              ...child.attrs,
              id: path + ":" + cursor,
              path,
              start: cursor,
              end: cursor + byteLength(source),
            },
            child.content,
            child.marks,
          ),
        );
        cursor += byteLength(source);
      }
    });
    return node.type.create(attrs, children, node.marks);
  };
  const sections: PMNode[] = [];
  next.forEach((section, _pos, i) => {
    const before = old.child(i),
      path = before.attrs.path;
    const pathEdits = edits.filter((e) => e.path === path);
    if (!pathEdits.length && before.eq(section)) {
      sections.push(section);
      return;
    }
    const start = moveOffset(before.attrs.start, pathEdits);
    const rendered = renderSection(before, section, project);
    const blocks = rendered.blocks.map((b) =>
      anchor(b.node, path, start + b.offset, b.raw),
    );
    sections.push(
      section.type.create(
        {
          ...section.attrs,
          start,
          end: start + byteLength(rendered.text),
          raw: rendered.text,
        },
        blocks,
      ),
    );
  });
  return next.type.create(next.attrs, sections);
}

export function sourceLocation(
  doc: PMNode,
  pos: number,
): { path: string; offset: number } | null {
  const resolved = doc.resolve(Math.min(pos, doc.content.size));
  let block: PMNode | undefined;
  for (let d = resolved.depth; d >= 1; d--) {
    if (
      resolved.node(d).attrs.path &&
      resolved.node(d).type.name !== "section"
    ) {
      block = resolved.node(d);
      break;
    }
  }
  if (!block) {
    // Block/gap selections live in the section rather than inside inline text.
    // Keep their source context usable for insertions and switching views.
    if (resolved.parent.type.name === "section") {
      const next = resolved.nodeAfter,
        previous = resolved.nodeBefore;
      return {
        path: resolved.parent.attrs.path,
        offset:
          next?.attrs.start ??
          previous?.attrs.end ??
          resolved.parent.attrs.start,
      };
    }
    return null;
  }
  let offset = block.attrs.start + byteLength(block.attrs.prefix || "");
  // Find a close insertion point inside the block, accounting for formatting delimiters.
  const parent = resolved.parent;
  if (parent.inlineContent) {
    const before = parent.cut(0, resolved.parentOffset);
    offset += byteLength(inlineString(before));
    const active = resolved.marks();
    for (const mark of active) {
      if (mark.type.name === "strong" || mark.type.name === "em") offset--;
    }
  }
  return { path: block.attrs.path, offset: Math.min(block.attrs.end, offset) };
}

export function editorPosition(
  doc: PMNode,
  path: string,
  offset: number,
): number {
  let found = 2;
  let distance = Infinity;
  doc.descendants((node, pos) => {
    if (!node.inlineContent || node.attrs.path !== path) return;
    const gap =
      offset < node.attrs.start
        ? node.attrs.start - offset
        : offset > node.attrs.end
          ? offset - node.attrs.end
          : 0;
    if (gap >= distance) return;
    distance = gap;
    let lo = 0,
      hi = node.content.size;
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2);
      const loc = sourceLocation(doc, pos + 1 + mid);
      if (loc && loc.offset < offset) lo = mid + 1;
      else hi = mid;
    }
    found = pos + 1 + lo;
  });
  return Math.min(found, doc.content.size);
}
