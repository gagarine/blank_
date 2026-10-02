import { memo, useEffect, useRef, useState } from "react";
import { getDocument, GlobalWorkerOptions, PDFDocumentProxy } from "pdfjs-dist";
import worker from "pdfjs-dist/build/pdf.worker.min.mjs?url";
import type { Preview, Project, Selection, PositionReader } from "./types";
import { previewAnchor, sourceAnchor } from "./readingPosition";
import { renderPreviewPage } from "./pdfPage";
GlobalWorkerOptions.workerSrc = worker;
const Page = memo(function Page({
  pdf,
  index,
  scale,
  pageRatio,
}: {
  pdf: PDFDocumentProxy;
  index: number;
  scale: number;
  pageRatio?: number;
}) {
  const host = useRef<HTMLDivElement>(null),
    canvas = useRef<HTMLCanvasElement>(null);
  const [visible, setVisible] = useState(false);
  const [ratio, setRatio] = useState(1.414);
  useEffect(() => {
    const observer = new IntersectionObserver(
      (entries) => setVisible(entries[0].isIntersecting),
      { root: host.current?.closest(".preview-scroll"), rootMargin: "800px" },
    );
    if (host.current) observer.observe(host.current);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    if (!visible || !canvas.current) return;
    return renderPreviewPage(
      pdf,
      canvas.current,
      index,
      scale * devicePixelRatio,
      setRatio,
    );
  }, [visible, pdf, index, scale]);
  return (
    <div
      className="pdf-page"
      data-page={index}
      aria-label={`Page ${index}`}
      ref={host}
      style={{ width: 595 * scale, aspectRatio: 1 / (pageRatio || ratio) }}
    >
      <canvas ref={canvas} width={0} height={0} />
      <span className="page-number">{index}</span>
    </div>
  );
});
export function PdfPreview({
  preview,
  busy,
  selection,
  project,
  positionReader,
}: {
  preview: Preview | null;
  busy: boolean;
  selection: Selection | null;
  project: Project;
  positionReader: PositionReader;
}) {
  const [pdf, setPDF] = useState<PDFDocumentProxy | null>(null),
    [scale, setScale] = useState(1),
    [currentPage, setCurrentPage] = useState(1),
    [pageInput, setPageInput] = useState("1"),
    [editingPage, setEditingPage] = useState(false),
    [loadError, setLoadError] = useState("");
  const scroller = useRef<HTMLDivElement>(null);
  const cancelPageEdit = useRef(false);
  const initialPosition = useRef(selection);
  const restored = useRef(false);
  positionReader.current = () => {
    const root = scroller.current;
    if (!root) return null;
    const line = root.getBoundingClientRect().top + root.clientHeight * 0.35;
    const original = previewAnchor(
      preview?.sourceMap || [],
      initialPosition.current,
    );
    if (original) {
      const page = root.querySelector<HTMLElement>(
        `[data-page="${original.page}"]`,
      );
      const box = page?.getBoundingClientRect();
      const viewport = root.getBoundingClientRect();
      if (
        box &&
        box.top + box.height * original.y >= viewport.top &&
        box.top + box.height * original.y <= viewport.bottom
      )
        return initialPosition.current;
    }
    let closest: HTMLElement | null = null;
    let distance = Infinity;
    for (const page of root.querySelectorAll<HTMLElement>(".pdf-page")) {
      const box = page.getBoundingClientRect();
      const gap = Math.max(box.top - line, line - box.bottom, 0);
      if (gap < distance) {
        closest = page;
        distance = gap;
      }
    }
    if (!closest) return null;
    const box = closest.getBoundingClientRect();
    const anchor = sourceAnchor(
      preview?.sourceMap || [],
      Number(closest.dataset.page),
      (line - box.top) / box.height,
    );
    if (!anchor || !project.files[anchor.path]) return null;
    return {
      path: anchor.path,
      start: anchor.start,
      end: anchor.start,
      revision: project.files[anchor.path].revision,
    };
  };
  const encoded = preview?.pdf || preview?.previousPdf;
  useEffect(() => {
    if (!encoded) {
      setPDF(null);
      return;
    }
    let cancelled = false;
    setLoadError("");
    const bytes = Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0));
    const task = getDocument({ data: bytes });
    task.promise
      .then((doc) => {
        if (!cancelled) {
          setPDF(doc);
          setCurrentPage((page) => Math.min(page, doc.numPages));
        }
      })
      .catch((error) => {
        if (!cancelled) setLoadError(String(error));
      });
    return () => {
      cancelled = true;
      void task.destroy();
    };
  }, [encoded]);
  useEffect(() => {
    if (!pdf || restored.current) return;
    const anchor = previewAnchor(
      preview?.sourceMap || [],
      initialPosition.current,
    );
    if (!anchor) return;
    const root = scroller.current;
    const target = root?.querySelector<HTMLElement>(
      `[data-page="${anchor.page}"]`,
    );
    if (!root || !target) return;
    const frame = requestAnimationFrame(() => {
      const box = target.getBoundingClientRect();
      root.scrollTop +=
        box.top +
        box.height * anchor.y -
        root.getBoundingClientRect().top -
        root.clientHeight * 0.35;
      setCurrentPage(anchor.page);
      restored.current = true;
    });
    return () => cancelAnimationFrame(frame);
  }, [pdf, preview?.sourceMap]);
  useEffect(() => {
    if (!editingPage) setPageInput(String(currentPage));
  }, [currentPage, editingPage]);
  useEffect(() => {
    const root = scroller.current;
    if (!root || !pdf) return;
    const visible = new Set<Element>();
    let frame = 0;
    const update = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const bounds = root.getBoundingClientRect();
        const readingLine = bounds.top + root.clientHeight * 0.35;
        let best: Element | undefined,
          distance = Infinity;
        for (const page of visible) {
          const box = page.getBoundingClientRect();
          const gap = Math.max(
            box.top - readingLine,
            readingLine - box.bottom,
            0,
          );
          if (gap < distance) {
            best = page;
            distance = gap;
          }
        }
        if (best) setCurrentPage(Number(best.getAttribute("data-page")));
      });
    };
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) visible.add(entry.target);
          else visible.delete(entry.target);
        }
        update();
      },
      { root, threshold: [0, 0.25, 0.5, 0.75, 1] },
    );
    root
      .querySelectorAll(".pdf-page")
      .forEach((page) => observer.observe(page));
    root.addEventListener("scroll", update, { passive: true });
    return () => {
      observer.disconnect();
      root.removeEventListener("scroll", update);
      cancelAnimationFrame(frame);
    };
  }, [pdf, scale]);
  const jump = () => {
    if (!pdf || !scroller.current) return;
    const number = Number(pageInput.trim());
    if (!Number.isInteger(number) || !pageInput.trim()) {
      setPageInput(String(currentPage));
      return;
    }
    const page = Math.max(1, Math.min(pdf.numPages, number));
    const target = scroller.current.querySelector<HTMLElement>(
      `[data-page="${page}"]`,
    );
    if (target) {
      scroller.current.scrollBy({
        top:
          target.getBoundingClientRect().top -
          scroller.current.getBoundingClientRect().top -
          24,
        behavior: "instant",
      });
      setCurrentPage(page);
      setPageInput(String(page));
    }
  };
  return (
    <div className="preview-pane">
      <div className="preview-scroll" ref={scroller}>
        {pdf ? (
          Array.from({ length: pdf.numPages }, (_, i) => (
            <Page
              key={i}
              pdf={pdf}
              index={i + 1}
              scale={scale}
              pageRatio={preview?.pageRatios?.[i]}
            />
          ))
        ) : (
          <div className="empty-preview">
            {loadError ||
              (busy
                ? "Typesetting your document…"
                : "Your typeset document will appear here.")}
          </div>
        )}
      </div>
      {pdf && (
        <div
          className="preview-controls"
          role="group"
          aria-label="Preview navigation"
        >
          <form
            autoComplete="off"
            onSubmit={(event) => {
              event.preventDefault();
              jump();
              (
                event.currentTarget.elements.namedItem(
                  "page",
                ) as HTMLInputElement
              ).blur();
            }}
          >
            <input
              autoComplete="off"
              name="page"
              type="text"
              inputMode="numeric"
              aria-label="Current page"
              title="Type a page number and press Return"
              value={pageInput}
              onChange={(event) => setPageInput(event.target.value)}
              onFocus={(event) => {
                cancelPageEdit.current = false;
                setEditingPage(true);
                event.target.select();
              }}
              onBlur={() => {
                if (
                  !cancelPageEdit.current &&
                  pageInput !== String(currentPage)
                )
                  jump();
                setEditingPage(false);
              }}
              onKeyDown={(event) => {
                if (event.key === "Escape") {
                  event.preventDefault();
                  event.stopPropagation();
                  cancelPageEdit.current = true;
                  setPageInput(String(currentPage));
                  setEditingPage(false);
                  event.currentTarget.blur();
                }
              }}
            />
            <span aria-label={`${pdf.numPages} pages`}>/ {pdf.numPages}</span>
          </form>
          <span className="preview-control-divider" aria-hidden="true" />
          <button
            aria-label="Zoom out"
            disabled={scale <= 0.5}
            onClick={() =>
              setScale((value) => Math.max(0.5, +(value - 0.1).toFixed(1)))
            }
          >
            −
          </button>
          <span className="preview-zoom">{Math.round(scale * 100)}%</span>
          <button
            aria-label="Zoom in"
            disabled={scale >= 1.8}
            onClick={() =>
              setScale((value) => Math.min(1.8, +(value + 0.1).toFixed(1)))
            }
          >
            +
          </button>
          {!preview?.pdf && (
            <span className="preview-stale">Last successful preview</span>
          )}
        </div>
      )}
      {pdf && loadError && (
        <div className="preview-error" role="alert">
          {loadError}
        </div>
      )}
    </div>
  );
}

export async function renderPdfFigure(
  data: string,
  canvas: HTMLCanvasElement,
  pageNumber: number,
) {
  const task = getDocument({
    data: Uint8Array.from(atob(data), (c) => c.charCodeAt(0)),
  });
  try {
    const doc = await task.promise;
    const page = await doc.getPage(
      Math.min(Math.max(1, pageNumber), doc.numPages),
    );
    const viewport = page.getViewport({ scale: 1.4 });
    canvas.width = viewport.width;
    canvas.height = viewport.height;
    await page.render({
      canvas,
      canvasContext: canvas.getContext("2d")!,
      viewport,
    }).promise;
  } finally {
    await task.destroy();
  }
}
