import { describe, expect, it, vi } from "vitest";
import { createParseCache } from "./parseCache";
import { renderPreviewPage } from "./pdfPage";
import {
  byteLength,
  byteSlice,
  minimalEdit,
  type Parsed,
  type Project,
} from "./types";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
const parsed = (revision: number): Parsed => ({
  revision,
  tree: { kind: "Markup", start: 0, end: 1, children: [] },
});
function project(id = "one", revision = 1, text = "a"): Project {
  return {
    id,
    root: "/tmp",
    entry: "main.typ",
    revision,
    agentEnabled: false,
    lastOrigin: "user",
    files: {
      "main.typ": { path: "main.typ", text, revision, dirty: false },
    },
  };
}

describe("shared parse cache", () => {
  it("shares in-flight parses but isolates file changes and projects", async () => {
    const request = deferred<Parsed>();
    const parse = vi.fn().mockReturnValue(request.promise);
    const cached = createParseCache(parse);
    const first = cached(project(), "main.typ");
    expect(cached(project(), "main.typ")).toBe(first);
    expect(parse).toHaveBeenCalledTimes(1);
    request.resolve(parsed(1));
    await first;
    await cached(project("one", 1, "changed"), "main.typ");
    await cached(project("two"), "main.typ");
    await cached(project("two", 2), "main.typ");
    expect(parse).toHaveBeenCalledTimes(4);
  });
  it("retries rejected and obsolete responses without evicting newer work", async () => {
    const older = deferred<Parsed>();
    const current = deferred<Parsed>();
    const parse = vi
      .fn()
      .mockReturnValueOnce(older.promise)
      .mockReturnValueOnce(current.promise)
      .mockResolvedValueOnce(parsed(9))
      .mockResolvedValueOnce(parsed(3));
    const cached = createParseCache(parse);
    const first = cached(project(), "main.typ");
    const second = cached(project("one", 2), "main.typ");
    older.reject(new Error("helper restarted"));
    await expect(first).rejects.toThrow("helper restarted");
    expect(cached(project("one", 2), "main.typ")).toBe(second);
    current.resolve(parsed(2));
    await second;
    await cached(project("one", 3), "main.typ");
    expect(await cached(project("one", 3), "main.typ")).toEqual(parsed(3));
    expect(parse).toHaveBeenCalledTimes(4);
  });
});

it("keeps source patches on Unicode boundaries through insertion, deletion and replacement", () => {
  const pieces = [
    "",
    "a",
    "é",
    "e\u0301",
    "😀",
    "😁",
    "\u{1F600}",
    "\u{1FA00}",
    "👩🏽‍🔬",
    "中文",
    "\r\n",
    "#*_",
  ];
  for (const prefix of ["", "Café 😀 "])
    for (const before of pieces)
      for (const after of pieces) {
        const old = prefix + before + " 😀 suffix";
        const next = prefix + after + " 😀 suffix";
        const surrounding = "// preserved 😀\n";
        const edit = minimalEdit(
          "main.typ",
          old,
          next,
          byteLength(surrounding),
        );
        if (!edit) {
          expect(old).toBe(next);
          continue;
        }
        const full = surrounding + old;
        expect(
          byteSlice(full, 0, edit.start) +
            edit.text +
            byteSlice(full, edit.end),
        ).toBe(surrounding + next);
        expect(byteSlice(full, 0, edit.start)).not.toContain("�");
        expect(byteSlice(full, edit.end)).not.toContain("�");
      }
});

function pdfFixture() {
  const render = deferred<void>();
  const task = {
    promise: render.promise,
    cancel: vi.fn(() => render.reject({ name: "RenderingCancelledException" })),
  };
  const page = {
    getViewport: ({ scale }: { scale: number }) => ({
      width: 600 * scale,
      height: 800 * scale,
    }),
    render: vi.fn(() => task),
    cleanup: vi.fn(),
  };
  const pdf = { getPage: vi.fn().mockResolvedValue(page) };
  const canvas = {
    width: 0,
    height: 0,
    getContext: () => ({}),
  } as unknown as HTMLCanvasElement;
  return { pdf, page, canvas, task, render };
}
it("does not repeatedly encode a source larger than the byte cache budget", () => {
  const source = "a".repeat(5 * 1024 * 1024) + "é😀";
  const encode = vi.spyOn(TextEncoder.prototype, "encode");
  try {
    expect(byteSlice(source, source.length - 3)).toBe("é😀");
    expect(byteSlice(source, 0, 5)).toBe("aaaaa");
    expect(encode).toHaveBeenCalledOnce();
  } finally {
    encode.mockRestore();
  }
});
describe("preview canvas lifetime", () => {
  it("releases backing memory and page resources after scrolling offscreen", async () => {
    const { pdf, canvas, page, task } = pdfFixture();
    const errors = vi.fn();
    const stop = renderPreviewPage(pdf as any, canvas, 1, 2, () => {}, errors);
    await vi.waitFor(() => expect(page.render).toHaveBeenCalledOnce());
    expect(canvas.width * canvas.height * 4).toBe(7_680_000);
    stop();
    expect(canvas.width * canvas.height).toBe(0);
    await vi.waitFor(() => expect(page.cleanup).toHaveBeenCalledOnce());
    expect(task.cancel).toHaveBeenCalledOnce();
    expect(errors).not.toHaveBeenCalled();
  });
  it("does not render or resize a page that arrives after unmount", async () => {
    const { pdf, canvas, page } = pdfFixture();
    const request = deferred<typeof page>();
    pdf.getPage.mockReturnValue(request.promise);
    const stop = renderPreviewPage(pdf as any, canvas, 1, 2, () => {});
    await vi.waitFor(() => expect(pdf.getPage).toHaveBeenCalledOnce());
    stop();
    request.resolve(page);
    await vi.waitFor(() => expect(page.cleanup).toHaveBeenCalledOnce());
    expect(page.render).not.toHaveBeenCalled();
    expect(canvas.width * canvas.height).toBe(0);
  });
  it("waits for a cancelled render before reusing the canvas at another zoom", async () => {
    const { pdf, canvas, page } = pdfFixture();
    const oldRender = deferred<void>();
    page.render.mockReturnValueOnce({
      promise: oldRender.promise,
      cancel: vi.fn(),
    });
    const stop = renderPreviewPage(pdf as any, canvas, 1, 1, () => {});
    await vi.waitFor(() => expect(page.render).toHaveBeenCalledTimes(1));
    stop();
    const stopNext = renderPreviewPage(pdf as any, canvas, 1, 2, () => {});
    await Promise.resolve();
    expect(page.render).toHaveBeenCalledTimes(1);
    oldRender.resolve();
    await vi.waitFor(() => expect(page.render).toHaveBeenCalledTimes(2));
    expect(canvas.width).toBe(1200);
    stopNext();
    await vi.waitFor(() => expect(page.cleanup).toHaveBeenCalledTimes(2));
  });
});
