import { describe, it, expect } from "vitest";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { EditorState, NodeSelection, TextSelection } from "prosemirror-state";
import { exitBlock, paragraphBeside } from "./blockNavigation";
import { replaceAcrossSections } from "./sectionEditing";
import { selectAll } from "prosemirror-commands";
import { GapCursor } from "prosemirror-gapcursor";
import {
  moveBlock,
  moveBlockBy,
  blockAction,
  slashTransaction,
  matchingCommands,
} from "./blockCommands";
import {
  manuscriptOutline,
  reorderOutline,
  canReorderOutline,
} from "./outlineModel";
import { typingShortcut } from "./typingShortcuts";
import { documentStatistics } from "./documentStats";
import { Transform } from "prosemirror-transform";
import {
  addRowAfter,
  addColumnAfter,
  deleteRow,
  goToNextCell,
  selectedRect,
} from "prosemirror-tables";
import { externalFilePaths } from "./fileDrop";
import { nextTableCell } from "./tableCommands";
import {
  writerSchema as S,
  projectDocument,
  documentEdits,
  reanchorDocument,
  sourceLocation,
} from "./projection";
import { byteLength, byteSlice, minimalEdit } from "./types";
import type { Project, Parsed } from "./types";
function fixture(files: Record<string, string>) {
  const p: Project = {
    id: "test",
    root: "/tmp",
    entry: "main.typ",
    revision: 1,
    agentEnabled: false,
    lastOrigin: "open",
    files: {},
  };
  const parsed: Record<string, Parsed> = {};
  for (const [path, text] of Object.entries(files)) {
    p.files[path] = { path, text, revision: 1, dirty: false };
    const response = execFileSync(
      resolve("../helper/target/release/writer-helper"),
      {
        input:
          JSON.stringify({
            id: 1,
            method: "parse",
            params: { path, text, revision: 1 },
          }) + "\n",
        encoding: "utf8",
      },
    );
    parsed[path] = JSON.parse(response).result;
  }
  return { p, parsed, doc: projectDocument(p, parsed, "main.typ", true) };
}
function applyText(p: Project, edits: ReturnType<typeof documentEdits>) {
  const out: Record<string, string> = {};
  for (const [path, file] of Object.entries(p.files)) {
    let text = file.text;
    for (const e of edits
      .filter((e) => e.path === path)
      .sort((a, b) => b.start - a.start))
      text = byteSlice(text, 0, e.start) + e.text + byteSlice(text, e.end);
    out[path] = text;
  }
  return out;
}
function posOf(doc: any, text: string) {
  let result = -1;
  doc.descendants((n: any, pos: number) => {
    if (result < 0 && n.isText && n.text.includes(text))
      result = pos + n.text.indexOf(text);
  });
  if (result < 0) throw Error("missing " + text);
  return result;
}
describe("source-backed rich projection", () => {
  it("deletes Select All after typing into a blank draft and lets writing continue", () => {
    const { p, doc } = fixture({ "main.typ": "\n" });
    let state = EditorState.create({ doc });
    const commit = (tr: ReturnType<EditorState["tr"]["insertText"]>) => {
      const edits = documentEdits(state.doc, tr.doc, p);
      const anchored = reanchorDocument(state.doc, tr.doc, p, edits);
      p.files["main.typ"].text = applyText(p, edits)["main.typ"];
      state = EditorState.create({
        doc: anchored,
        selection: TextSelection.fromJSON(anchored, tr.selection.toJSON()),
      });
    };
    for (const text of ["A line of writing.", "Writing again 😀."]) {
      commit(state.tr.insertText(text));
      expect(p.files["main.typ"].text).toContain(text);
      selectAll(state, (tr) => {
        state = state.apply(tr);
      });
      commit(replaceAcrossSections(state)!);
      expect(p.files["main.typ"].text.trim()).toBe("");
      expect(state.doc.firstChild!.attrs.path).toBe("main.typ");
      expect(state.selection.empty).toBe(true);
      expect(state.selection.$from.parent.type.name).toBe("paragraph");
    }
  });
  it("replaces Select All across chapters without deleting include directives or files", () => {
    for (const text of ["", "Replacement text."]) {
      const { p, doc } = fixture({
        "main.typ": '#include "one.typ"\n#include "two.typ"\n',
        "one.typ": "= One\n\nFirst chapter.\n",
        "two.typ": '#image("figure.svg")\n',
      });
      let state = EditorState.create({ doc });
      selectAll(state, (tr) => {
        state = state.apply(tr);
      });
      const tr = replaceAcrossSections(state, text)!;
      const edits = documentEdits(doc, tr.doc, p);
      const out = applyText(p, edits);
      expect(out["main.typ"]).toBe(p.files["main.typ"].text);
      expect(out["one.typ"].trim()).toBe(text);
      expect(out["two.typ"].trim()).toBe("");
      expect(tr.doc.childCount).toBe(2);
      expect(tr.doc.child(0).attrs.id).toBe(doc.child(0).attrs.id);
      expect(tr.doc.child(1).attrs.id).toBe(doc.child(1).attrs.id);
      expect(tr.selection.$from.node(1).attrs.path).toBe("one.typ");
    }
  });
  it("preserves unselected text when replacing a selection spanning chapters", () => {
    const { p, doc } = fixture({
      "main.typ": '#include "one.typ"\n#include "two.typ"\n',
      "one.typ": "Keep this. Remove this.\n",
      "two.typ": "Remove that. Keep that.\n",
    });
    const state = EditorState.create({
      doc,
      selection: TextSelection.create(
        doc,
        posOf(doc, "Remove this"),
        posOf(doc, "Keep that"),
      ),
    });
    const tr = replaceAcrossSections(state, "New.")!;
    const out = applyText(p, documentEdits(doc, tr.doc, p));
    expect(out["one.typ"]).toBe("Keep this. New.\n");
    expect(out["two.typ"]).toBe("Keep that.\n");
    expect(out["main.typ"]).toBe(p.files["main.typ"].text);
    const within = EditorState.create({
      doc,
      selection: TextSelection.create(
        doc,
        posOf(doc, "Remove this"),
        posOf(doc, "Remove this") + 6,
      ),
    });
    expect(replaceAcrossSections(within)).toBeNull();
  });
  it("preserves every byte when unchanged, including CRLF and unknown code", () => {
    const { p, doc } = fixture({
      "main.typ":
        "// note\r\n#set text(size: 12pt)\r\n\r\n= Hello <id>\r\n\r\n*Bold* and _em_ \\#escape $ x^2 $ #unknown[abc]\r\n",
    });
    expect(documentEdits(doc, doc, p)).toEqual([]);
  });
  it("edits plain prose without rewriting adjacent Typst", () => {
    const input =
      "#let f(x) = [#x]\n\n= Heading\n\nAn ordinary paragraph.\n\n// preserve me\n#f[Advanced]\n";
    const { p, doc } = fixture({ "main.typ": input });
    const pos = posOf(doc, "ordinary");
    const changed = new Transform(doc).replaceWith(
      pos,
      pos + 8,
      S.text("careful"),
    ).doc;
    const edits = documentEdits(doc, changed, p);
    expect(applyText(p, edits)["main.typ"]).toBe(
      input.replace("ordinary", "careful"),
    );
    expect(edits).toHaveLength(1);
  });
  it("formats text while preserving unknown inline code and comments", () => {
    const input = "Before #custom[untouched] after.\n";
    const { p, doc } = fixture({ "main.typ": input });
    const pos = posOf(doc, "after");
    const changed = new Transform(doc).addMark(
      pos,
      pos + 5,
      S.marks.strong.create(),
    ).doc;
    expect(applyText(p, documentEdits(doc, changed, p))["main.typ"]).toBe(
      "Before #custom[untouched] *after*.\n",
    );
  });
  it("maps continuous chapter edits back to their files", () => {
    const { p, doc } = fixture({
      "main.typ": '#include "one.typ"\n#include "two.typ"\n',
      "one.typ": "= One\n\nChapter one.\n",
      "two.typ": "= Two\n\nChapter two.\n",
    });
    expect(doc.childCount).toBe(2);
    const pos = posOf(doc, "two.");
    const changed = new Transform(doc).replaceWith(
      pos,
      pos + 3,
      S.text("TWO"),
    ).doc;
    const out = applyText(p, documentEdits(doc, changed, p));
    expect(out["two.typ"]).toBe("= Two\n\nChapter TWO.\n");
    expect(out["main.typ"]).toBe(p.files["main.typ"].text);
    expect(out["one.typ"]).toBe(p.files["one.typ"].text);
  });
  it("preserves malformed and dynamic Typst without flattening it", () => {
    const { p, doc } = fixture({
      "main.typ": '#include ("chapter" + ".typ")\n\nHello #unknown(\n',
    });
    expect(documentEdits(doc, doc, p)).toEqual([]);
    expect(doc.toJSON()).toBeTruthy();
  });
  it("edits simple tables", () => {
    const input = "#table(columns: 2, [Left], [Right])\n";
    const { p, doc } = fixture({ "main.typ": input });
    expect(doc.firstChild!.firstChild!.type.name).toBe("table");
    const pos = posOf(doc, "Left");
    const changed = new Transform(doc).replaceWith(
      pos,
      pos + 4,
      S.text("New"),
    ).doc;
    expect(applyText(p, documentEdits(doc, changed, p))["main.typ"]).toBe(
      input.replace("Left", "New"),
    );
  });
  it("computes valid byte edits for combining accents and emoji", () => {
    const edit = minimalEdit("a.typ", "aé😀z", "aé🌱z")!;
    expect(edit).toEqual({ path: "a.typ", start: 3, end: 7, text: "🌱" });
    expect(byteLength("é")).toBe(2);
  });
  it("anchors split paragraphs so subsequent typing stays in its own source span", () => {
    const input = "First sentence. Second sentence.\n\nKeep this.\n";
    let { p, doc } = fixture({ "main.typ": input });
    const pos = posOf(doc, "Second");
    let changed = new Transform(doc).split(pos).doc;
    let edits = documentEdits(doc, changed, p);
    let anchored = reanchorDocument(doc, changed, p, edits);
    const text = applyText(p, edits)["main.typ"];
    expect(text).toBe("First sentence. \n\nSecond sentence.\n\nKeep this.\n");
    p.files["main.typ"].text = text;
    const target = posOf(anchored, "Second");
    changed = new Transform(anchored).insert(target, S.text("New ")).doc;
    expect(applyText(p, documentEdits(anchored, changed, p))["main.typ"]).toBe(
      text.replace("Second", "New Second"),
    );
  });
  it("anchors subsequent edits after changing block type", () => {
    let { p, doc } = fixture({ "main.typ": "Hello world.\n\nKeep this.\n" });
    const at = posOf(doc, "Hello") - 1;
    const changed = new Transform(doc).setNodeMarkup(at, S.nodes.heading, {
      ...doc.firstChild!.firstChild!.attrs,
      level: 2,
    }).doc;
    const edits = documentEdits(doc, changed, p);
    const anchored = reanchorDocument(doc, changed, p, edits);
    p.files["main.typ"].text = applyText(p, edits)["main.typ"];
    const target = posOf(anchored, "world");
    const more = new Transform(anchored).insert(
      target,
      S.text("beautiful "),
    ).doc;
    expect(applyText(p, documentEdits(anchored, more, p))["main.typ"]).toBe(
      "== Hello beautiful world.\n\nKeep this.\n",
    );
  });
});

describe("outline, slash commands and block movement", () => {
  it("starts at the document sections without exposing unrelated files", () => {
    const { p, parsed } = fixture({
      "main.typ":
        "= Document title\n\n== First section\n\nText.\n\n== Second section\n\nMore.\n",
      "unrelated.typ": "= Another document\n",
    });
    const tree = manuscriptOutline(p, parsed);
    expect(tree.map((item) => item.title)).toEqual([
      "First section",
      "Second section",
    ]);
    expect(
      tree.every((item) => item.kind === "heading" && item.path === "main.typ"),
    ).toBe(true);
    const edits = reorderOutline(p, tree[1], tree[0], false);
    const moved = applyText(p, edits);
    expect(moved["main.typ"]).toBe(
      "= Document title\n\n== Second section\n\nMore.\n== First section\n\nText.\n\n",
    );
    expect(moved["unrelated.typ"]).toBe(p.files["unrelated.typ"].text);
  });
  it("keeps a standalone title and real top-level sections visible", () => {
    const single = fixture({ "main.typ": "= Only heading\n\nProse.\n" });
    expect(
      manuscriptOutline(single.p, single.parsed).map((item) => item.title),
    ).toEqual(["Only heading"]);
    const sections = fixture({
      "main.typ": "= First\n\n== Child\n\n= Second\n",
    });
    expect(
      manuscriptOutline(sections.p, sections.parsed).map((item) => item.title),
    ).toEqual(["First", "Second"]);
  });

  it("builds a nested outline in include order and ignores headings in code/comments", () => {
    const { p, parsed } = fixture({
      "main.typ": '#include "b.typ"\n#include "a.typ"\n',
      "a.typ": "= Same\n\n== Section\n\n=== Detail 😀\n",
      "b.typ":
        "/*\n= Hidden\n*/\n```typ\n= Also hidden\n```\n= First\n\n== Nested\n",
    });
    const tree = manuscriptOutline(p, parsed);
    expect(tree).toHaveLength(2);
    expect(tree.map((n) => n.path)).toEqual(["b.typ", "a.typ"]);
    expect(tree.map((n) => n.title)).toEqual(["First", "Same"]);
    const last = tree[1].children[0].children[0];
    expect(last.title).toBe("Detail 😀");
    expect(byteSlice(p.files[last.path].text, last.start)).toMatch(
      /^=== Detail/,
    );
  });
  it("distinguishes repeated headings and handles include cycles", () => {
    const { p, parsed } = fixture({
      "main.typ": '= Same\n\n== Child\n\n= Same\n#include "other.typ"\n',
      "other.typ": '#include "main.typ"\n= Other\n',
    });
    const tree = manuscriptOutline(p, parsed);
    const headings = tree;
    expect(headings[0].title).toBe(headings[1].title);
    expect(headings[0].start).not.toBe(headings[1].start);
    expect(headings[1].children[0].title).toBe("Other");
  });
  it("turns a slash query into a heading in one source transaction", () => {
    const { p, doc } = fixture({
      "main.typ": "// untouched\n\n/heading 2\n\nAfter.\n",
    });
    const from = posOf(doc, "/heading");
    const state = EditorState.create({
      doc,
      selection: TextSelection.create(doc, from + 10),
    });
    const next = state.apply(
      slashTransaction(state, from, from + 10, "heading2"),
    );
    expect(applyText(p, documentEdits(doc, next.doc, p))["main.typ"]).toBe(
      "// untouched\n\n== \n\nAfter.\n",
    );
    expect(matchingCommands("image")[0].id).toBe("image");
    expect(matchingCommands("h2")[0].id).toBe("heading2");
  });
  it("moves blocks exactly, including unsupported Typst and Unicode, then types at the new location", () => {
    const input = "Alpha é.\n\n#custom(  [keep *this*] )\n\nLast 😀.\n";
    let { p, doc } = fixture({ "main.typ": input });
    const from = 1;
    const to = doc.firstChild!.nodeSize - 1;
    const tr = moveBlock(EditorState.create({ doc }), from, to)!;
    const edits = documentEdits(doc, tr.doc, p);
    const out = applyText(p, edits)["main.typ"];
    expect(out).toBe("#custom(  [keep *this*] )\n\nLast 😀.\n\nAlpha é.\n");
    const anchored = reanchorDocument(doc, tr.doc, p, edits);
    p = {
      ...p,
      files: {
        ...p.files,
        "main.typ": { ...p.files["main.typ"], text: out, revision: 2 },
      },
    };
    const typed = new Transform(anchored).insert(
      posOf(anchored, "Alpha"),
      S.text("New "),
    ).doc;
    expect(applyText(p, documentEdits(anchored, typed, p))["main.typ"]).toBe(
      out.replace("Alpha", "New Alpha"),
    );
  });
  it("uses the same move transaction for keyboard controls and keeps chapter files intact", () => {
    const { p, doc } = fixture({
      "main.typ": '#include "one.typ"\n#include "two.typ"\n',
      "one.typ": "First.\n\nSecond.\n",
      "two.typ": "Third.\n",
    });
    const state = EditorState.create({ doc });
    const moved = moveBlockBy(state, 1, 1)!;
    expect(applyText(p, documentEdits(doc, moved.doc, p))).toEqual({
      "main.typ": p.files["main.typ"].text,
      "one.typ": "Second.\n\nFirst.\n",
      "two.typ": "Third.\n",
    });
    expect(() => moveBlock(state, 1, doc.firstChild!.nodeSize + 1)).toThrow(
      /chapter/,
    );
    expect(moveBlockBy(state, 1, -1)).toBeNull();
    expect(moveBlock(state, 1, 1)).toBeNull();
  });
  it("preserves table source and reverses a block move without changing bytes", () => {
    const input = "Before.\n\n#table(columns: 2, [A], [B])\n\nAfter.\n";
    const { p, doc } = fixture({ "main.typ": input });
    const tableAt = 1 + doc.firstChild!.firstChild!.nodeSize;
    const moved = moveBlockBy(EditorState.create({ doc }), tableAt, -1)!;
    const edits = documentEdits(doc, moved.doc, p);
    const out = applyText(p, edits)["main.typ"];
    expect(out.startsWith("#table(columns: 2, [A], [B])\n\nBefore.")).toBe(
      true,
    );
    const anchored = reanchorDocument(doc, moved.doc, p, edits);
    const updated = {
      ...p,
      files: { ...p.files, "main.typ": { ...p.files["main.typ"], text: out } },
    };
    const restored = moveBlockBy(EditorState.create({ doc: anchored }), 1, 1)!;
    expect(
      applyText(updated, documentEdits(anchored, restored.doc, updated))[
        "main.typ"
      ],
    ).toBe(input);
  });
});

describe("Typst typing, section reordering and statistics", () => {
  function typeInto(input: string, typed: string) {
    let { p, doc } = fixture({ "main.typ": input });
    let state = EditorState.create({
      doc,
      selection: TextSelection.create(doc, posOf(doc, "Target")),
    });
    for (const char of typed) {
      const tr =
        typingShortcut(state, state.selection.from, state.selection.to, char) ||
        state.tr.insertText(char);
      const next = state.apply(tr),
        edits = documentEdits(state.doc, next.doc, p);
      const anchored = reanchorDocument(state.doc, next.doc, p, edits);
      const text = applyText(p, edits)["main.typ"];
      p = {
        ...p,
        files: {
          ...p.files,
          "main.typ": {
            ...p.files["main.typ"],
            text,
            revision: p.files["main.typ"].revision + 1,
          },
        },
      };
      state = EditorState.create({
        doc: anchored,
        selection: TextSelection.create(anchored, next.selection.from),
        storedMarks: next.storedMarks,
      });
    }
    return { text: p.files["main.typ"].text, state };
  }
  it("converts equals-space into a heading and stores ordinary Typst", () => {
    const out = typeInto("// preserved\n\nTarget\n", "=== ");
    expect(out.text).toBe("// preserved\n\n=== Target\n");
    expect(out.state.selection.$from.parent.attrs.level).toBe(3);
  });
  it("formats bold, italic and nested emphasis using Typst delimiters", () => {
    expect(typeInto("Target\n", "*bold* ").text).toBe("*bold* Target\n");
    expect(typeInto("Target\n", "_italic_ ").text).toBe("_italic_ Target\n");
    expect(typeInto("Target\n", "*_both_* ").text).toBe("*_both_* Target\n");
    expect(typeInto("Target\n", "*é😀* ").text).toBe("*é😀* Target\n");
    const out = typeInto("Target\n", "*bold* ordinary ");
    expect(out.state.doc.textContent).toBe("bold ordinary Target");
    expect(out.text).toBe("*bold* ordinary Target\n");
  });
  it("leaves embedded underscores and Markdown heading input literal", () => {
    expect(typeInto("Target\n", "snake_case_name ").state.doc.textContent).toBe(
      "snake_case_name Target",
    );
    expect(
      typeInto("Target\n", "# ").state.selection.$from.parent.type.name,
    ).toBe("paragraph");
  });
  it("moves an entire section, including its subsections and unknown content", () => {
    const source =
      "#set text(size: 12pt)\n\n= Title\n\n== One\nText.\n=== Child\n#custom[untouched]\n\n== Two\nEnd.";
    const { p, parsed } = fixture({ "main.typ": source });
    const [one, two] = manuscriptOutline(p, parsed);
    expect(applyText(p, reorderOutline(p, one, two, true))["main.typ"]).toBe(
      "#set text(size: 12pt)\n\n= Title\n\n== Two\nEnd.\n\n== One\nText.\n=== Child\n#custom[untouched]\n\n",
    );
    expect(canReorderOutline(one, one.children[0])).toBe(false);
    p.files["main.typ"].revision++;
    expect(() => reorderOutline(p, one, two, true)).toThrow(/changed during/);
  });
  it("reorders literal chapter includes, preserving chapter files and comments", () => {
    const { p, parsed } = fixture({
      "main.typ":
        '// setup\r\n#include "one.typ" // first\r\n#include "two.typ"\r\n',
      "one.typ": '= One\n\n#image("assets/one.svg")\n',
      "two.typ": "= Two\n\nWords.\n",
    });
    const [one, two] = manuscriptOutline(p, parsed);
    expect(one.title).toBe("One");
    const out = applyText(p, reorderOutline(p, two, one, false));
    expect(out["main.typ"]).toBe(
      '// setup\r\n#include "two.typ"\r\n#include "one.typ" // first\r\n',
    );
    expect(out["one.typ"]).toBe(p.files["one.typ"].text);
    expect(out["two.typ"]).toBe(p.files["two.typ"].text);
  });
  it("counts manuscript prose once per include occurrence and omits source code", () => {
    const { doc } = fixture({
      "main.typ": '#set text(size: 12pt)\n#include "one.typ"\n',
      "one.typ":
        "= My title\n\nHello *careful* world.\n\n#custom[generated content]\n",
      "unused.typ": "Unused extra words.\n",
    });
    expect(documentStatistics(doc).words).toBe(5);
    expect(documentStatistics(doc).headings).toBe(1);
  });
});

describe("table edits and native drops", () => {
  it("supports standard gap cursors around a lone block without modifying source", () => {
    const { p, doc } = fixture({ "main.typ": '#image("figure.svg")' });
    for (const pos of [1, 2]) {
      expect(GapCursor.valid(doc.resolve(pos))).toBe(true);
      const state = EditorState.create({
        doc,
        selection: new GapCursor(doc.resolve(pos)),
      });
      expect(sourceLocation(doc, state.selection.from)).toEqual({
        path: "main.typ",
        offset: pos === 1 ? 0 : p.files["main.typ"].text.length,
      });
      expect(documentEdits(doc, state.doc, p)).toEqual([]);
    }
    expect(GapCursor.valid(doc.resolve(0))).toBe(false);
  });
  it("lets a lone image, equation or source block gain text on either side without changing the block", () => {
    for (const raw of [
      '#image("figure.svg")',
      "$ x^2 $",
      "#custom-function()",
    ]) {
      for (const direction of [-1, 1] as const) {
        const { p, doc } = fixture({ "main.typ": raw });
        const state = EditorState.create({
          doc,
          selection: NodeSelection.create(doc, 1),
        });
        const tr = exitBlock(state, direction)!;
        expect(tr).not.toBeNull();
        expect(tr.selection.$from.parent.type.name).toBe("paragraph");
        expect(tr.selection.$from.parent.textContent).toBe("");
        const typed = state.apply(tr).tr.insertText("New paragraph.");
        const out = applyText(p, documentEdits(doc, typed.doc, p))["main.typ"];
        expect(out).toBe(
          direction < 0
            ? `New paragraph.\n\n${raw}`
            : `${raw}\n\nNew paragraph.`,
        );
        expect(fixture({ "main.typ": out }).doc.firstChild!.childCount).toBe(2);
      }
    }
  });
  it("exits the first or last table row, leaving middle rows and selected cell text alone", () => {
    const { p, doc } = fixture({
      "main.typ": "#table(columns: 2, [A], [B], [C], [D], [E], [F])",
    });
    for (const [text, direction] of [
      ["A", -1],
      ["B", -1],
      ["E", 1],
      ["F", 1],
    ] as const) {
      const state = EditorState.create({
        doc,
        selection: TextSelection.create(doc, posOf(doc, text)),
      });
      const tr = exitBlock(state, direction)!;
      expect(tr.selection.$from.depth).toBe(2);
      const typed = state.apply(tr).tr.insertText("Outside.");
      const out = applyText(p, documentEdits(doc, typed.doc, p))["main.typ"];
      expect(out.includes(p.files["main.typ"].text)).toBe(true);
      expect(out.includes("Outside.")).toBe(true);
    }
    const middle = EditorState.create({
      doc,
      selection: TextSelection.create(doc, posOf(doc, "C")),
    });
    expect(exitBlock(middle, -1)).toBeNull();
    expect(exitBlock(middle, 1)).toBeNull();
    const selected = EditorState.create({
      doc,
      selection: TextSelection.create(
        doc,
        posOf(doc, "F"),
        posOf(doc, "F") + 1,
      ),
    });
    expect(exitBlock(selected, 1)).toBeNull();
  });
  it("reuses neighboring text and keeps new paragraphs inside their source chapter", () => {
    const { p, doc } = fixture({
      "main.typ": '#include "one.typ"\n#include "two.typ"',
      "one.typ": '#image("figure.svg")',
      "two.typ": "Next chapter.",
    });
    const pos = (() => {
      let found = -1;
      doc.descendants((node, at) => {
        if (node.type.name === "raw_block" && node.attrs.path === "one.typ")
          found = at;
      });
      return found;
    })();
    const state = EditorState.create({ doc });
    const tr = paragraphBeside(state, pos, 1)!;
    expect(tr.selection.$from.node(1).attrs.path).toBe("one.typ");
    const typed = state.apply(tr).tr.insertText("In chapter one.");
    const edits = documentEdits(doc, typed.doc, p);
    expect(edits.map((edit) => edit.path)).toEqual(["one.typ"]);
    const again = paragraphBeside(state.apply(tr).apply(typed), pos, 1)!;
    expect(again.docChanged).toBe(false);
    expect(again.selection.$from.parent.textContent).toBe("In chapter one.");
  });
  it("ignores native internal drags while retaining real file paths", () => {
    expect(externalFilePaths([""])).toEqual([]);
    expect(externalFilePaths(["", "12", "application/x-still-block"])).toEqual(
      [],
    );
    expect(
      externalFilePaths([
        "",
        "/Users/me/Figure with spaces.svg",
        "C:\\Research\\figure.png",
      ]),
    ).toEqual(["/Users/me/Figure with spaces.svg", "C:\\Research\\figure.png"]);
  });
  it("adds and removes table structure through source patches without changing surrounding code", () => {
    const source =
      "// keep before\n#let custom(x) = x\n\n#table(columns: 2, [A], [B], [C], [D])\n\n// keep after\nLast paragraph.\n";
    let { p, doc } = fixture({ "main.typ": source });
    let state = EditorState.create({
      doc,
      selection: TextSelection.create(doc, posOf(doc, "D")),
    });
    const dispatch = (tr: any) => {
      const next = state.apply(tr);
      const edits = documentEdits(state.doc, next.doc, p);
      const text = applyText(p, edits)["main.typ"];
      const mapped = reanchorDocument(state.doc, next.doc, p, edits);
      p = { ...p, files: { "main.typ": { ...p.files["main.typ"], text } } };
      state = EditorState.create({
        doc: mapped,
        selection: TextSelection.fromJSON(mapped, next.selection.toJSON()),
      });
      expect(text.startsWith("// keep before\n#let custom(x) = x\n\n")).toBe(
        true,
      );
      expect(text.endsWith("\n\n// keep after\nLast paragraph.\n")).toBe(true);
      const reparsed = fixture({ "main.typ": text }).doc;
      expect(reparsed.textContent).toBe(mapped.textContent);
    };
    expect(nextTableCell(state, dispatch)).toBe(true);
    expect(selectedRect(state).map.height).toBe(3);
    expect(selectedRect(state).top).toBe(2);
    expect(addColumnAfter(state, dispatch)).toBe(true);
    expect(selectedRect(state).map.width).toBe(3);
    expect(addRowAfter(state, dispatch)).toBe(true);
    expect(selectedRect(state).map.height).toBe(4);
    expect(deleteRow(state, dispatch)).toBe(true);
    expect(selectedRect(state).map.height).toBe(3);
  });
});

it("duplicates source-backed blocks independently and deletes without losing their neighbor", () => {
  const input = "= Title\n\n*Bold* and #custom[opaque].\n\nKeep me.\n";
  let { p, doc } = fixture({ "main.typ": input });
  const pos = 1 + doc.firstChild!.firstChild!.nodeSize;
  const duplicated = blockAction(
    EditorState.create({ doc }),
    pos,
    "duplicate",
  )!;
  const edits = documentEdits(doc, duplicated.doc, p);
  const text = applyText(p, edits)["main.typ"];
  expect(text).toBe(
    input.replace(
      "*Bold* and #custom[opaque].",
      "*Bold* and #custom[opaque].\n\n*Bold* and #custom[opaque].",
    ),
  );
  const anchored = reanchorDocument(doc, duplicated.doc, p, edits);
  p.files["main.typ"].text = text;
  expect(anchored.firstChild!.child(1).attrs.id).not.toBe(
    anchored.firstChild!.child(2).attrs.id,
  );
  const deleted = blockAction(
    EditorState.create({ doc: anchored }),
    pos + anchored.firstChild!.child(1).nodeSize,
    "delete",
  )!;
  expect(
    applyText(p, documentEdits(anchored, deleted.doc, p))["main.typ"],
  ).toBe(input);
  const changed = blockAction(EditorState.create({ doc }), pos, "heading2")!;
  p.files["main.typ"].text = input;
  expect(
    applyText(p, documentEdits(doc, changed.doc, p))["main.typ"],
  ).toContain("== *Bold* and #custom[opaque].");
});
