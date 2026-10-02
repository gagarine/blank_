import type { PreviewAnchor, Selection } from "./types";

export function previewAnchor(
  anchors: PreviewAnchor[],
  selection: Selection | null,
) {
  if (!selection) return null;
  let best: PreviewAnchor | null = null;
  let distance = Infinity;
  for (const anchor of anchors) {
    if (anchor.path !== selection.path) continue;
    const gap =
      selection.start < anchor.start
        ? anchor.start - selection.start
        : selection.start >= anchor.end
          ? selection.start - anchor.end + 1
          : 0;
    if (gap < distance) {
      best = anchor;
      distance = gap;
    }
  }
  return best;
}

export function sourceAnchor(
  anchors: PreviewAnchor[],
  page: number,
  y: number,
) {
  let best: PreviewAnchor | null = null;
  let distance = Infinity;
  for (const anchor of anchors) {
    // Prefer a nearby page when a cover or blank page has no source text.
    const gap = Math.abs(anchor.page - page) * 2 + Math.abs(anchor.y - y);
    if (gap < distance) {
      best = anchor;
      distance = gap;
    }
  }
  return best;
}
