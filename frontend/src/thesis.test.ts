import { it, expect } from "vitest";
import { execFileSync } from "node:child_process";
import { readFileSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { Transform } from "prosemirror-transform";
import {
  projectDocument,
  documentEdits,
  reanchorDocument,
  writerSchema as S,
} from "./projection";
import { byteSlice } from "./types";
import type { Project, Parsed } from "./types";
it("edits a deterministic 150,000-word, 20-chapter manuscript without joining files", () => {
  const root = mkdtempSync(join(tmpdir(), "still-thesis-"));
  execFileSync("python3", [resolve("../scripts/thesis-fixture.py"), root]);
  const files = [
    "main.typ",
    ...readdirSync(join(root, "chapters")).map((p) => "chapters/" + p),
  ];
  const p: Project = {
    id: "thesis",
    root,
    entry: "main.typ",
    revision: 1,
    agentEnabled: false,
    lastOrigin: "open",
    files: {},
  };
  const requests =
    files
      .map((path, i) => {
        const text = readFileSync(join(root, path), "utf8");
        p.files[path] = { path, text, revision: 1, dirty: false };
        return JSON.stringify({
          id: i,
          method: "parse",
          params: { path, text, revision: 1 },
        });
      })
      .join("\n") + "\n";
  const responses = execFileSync(
    resolve("../helper/target/release/writer-helper"),
    { input: requests, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 },
  )
    .trim()
    .split("\n")
    .map((s) => JSON.parse(s));
  const parsed: Record<string, Parsed> = {};
  responses.forEach((r) => (parsed[files[r.id]] = r.result));
  let doc = projectDocument(p, parsed, "main.typ", true);
  expect(doc.childCount).toBe(22);
  expect(documentEdits(doc, doc, p)).toEqual([]);
  const timings: number[] = [];
  for (let i = 0; i < 60; i++) {
    let at = 0;
    doc.descendants((n, pos) => {
      if (!at && n.isText && n.text?.startsWith("Careful")) at = pos;
    });
    const t = performance.now();
    const next = new Transform(doc).insert(at + 10, S.text("x")).doc;
    const edits = documentEdits(doc, next, p);
    expect(edits).toHaveLength(1);
    expect(edits[0].path).toBe("chapters/01.typ");
    const mapped = reanchorDocument(doc, next, p, edits);
    const e = edits[0],
      f = p.files[e.path];
    f.text = byteSlice(f.text, 0, e.start) + e.text + byteSlice(f.text, e.end);
    doc = mapped;
    timings.push(performance.now() - t);
  }
  expect(p.files["main.typ"].text).toBe(
    readFileSync(join(root, "main.typ"), "utf8"),
  );
  expect(p.files["chapters/20.typ"].text).toBe(
    readFileSync(join(root, "chapters/20.typ"), "utf8"),
  );
  timings.sort((a, b) => a - b);
  writeFileSync(
    resolve("../.tools/model-benchmark.json"),
    JSON.stringify(
      {
        fixtureWords: 150000,
        richModelEditP95Ms: timings[Math.floor(timings.length * 0.95)],
        samples: timings.length,
        note: "model transaction only; excludes native input, DOM layout and paint",
      },
      null,
      2,
    ),
  );
}, 30000);
