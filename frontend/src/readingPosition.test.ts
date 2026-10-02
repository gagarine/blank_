import { expect, it } from "vitest";
import { previewAnchor, sourceAnchor } from "./readingPosition";
import type { PreviewAnchor, Selection } from "./types";

const anchors: PreviewAnchor[] = [
  { path: "one.typ", start: 8, end: 40, page: 1, y: 0.2 },
  { path: "one.typ", start: 40, end: 80, page: 2, y: 0.4 },
  { path: "two.typ", start: 8, end: 50, page: 3, y: 0.2 },
  { path: "two.typ", start: 50, end: 90, page: 3, y: 0.7 },
];
const at = (path: string, start: number): Selection => ({
  path,
  start,
  end: start,
  revision: 1,
});

it("maps source byte offsets and chapter identity to the right page", () => {
  expect(previewAnchor(anchors, at("one.typ", 40))).toBe(anchors[1]);
  expect(previewAnchor(anchors, at("two.typ", 40))).toBe(anchors[2]);
  expect(previewAnchor(anchors, at("unknown.typ", 40))).toBeNull();
});
it("uses the closest mapped passage for comments or unsupported source", () => {
  expect(previewAnchor(anchors, at("one.typ", 0))).toBe(anchors[0]);
  expect(previewAnchor(anchors, at("one.typ", 100))).toBe(anchors[1]);
  expect(previewAnchor([], at("one.typ", 0))).toBeNull();
});
it("maps the PDF reading line back to the correct chapter and passage", () => {
  expect(sourceAnchor(anchors, 3, 0.6)).toBe(anchors[3]);
  expect(sourceAnchor(anchors, 2, 0.2)).toBe(anchors[1]);
  expect(sourceAnchor(anchors, 4, 0.7)).toBe(anchors[3]);
  expect(sourceAnchor([], 1, 0.5)).toBeNull();
});
