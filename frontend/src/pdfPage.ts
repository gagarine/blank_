import type { PDFDocumentProxy, PDFPageProxy, RenderTask } from "pdfjs-dist";

// Serialize work on a canvas so zooming cannot start a new render before the
// cancelled PDF.js task has released it. Offscreen pages keep only their size.
const canvasWork = new WeakMap<HTMLCanvasElement, Promise<void>>();

export function renderPreviewPage(
  pdf: PDFDocumentProxy,
  canvas: HTMLCanvasElement,
  index: number,
  scale: number,
  onRatio: (ratio: number) => void,
  onError: (error: unknown) => void = console.error,
) {
  let disposed = false;
  let page: PDFPageProxy | undefined;
  let task: RenderTask | undefined;
  const previous = canvasWork.get(canvas) || Promise.resolve();
  const work = previous
    .then(async () => {
      if (disposed) return;
      page = await pdf.getPage(index);
      if (disposed) return;
      const viewport = page.getViewport({ scale });
      onRatio(viewport.height / viewport.width);
      canvas.width = viewport.width;
      canvas.height = viewport.height;
      task = page.render({
        canvas,
        canvasContext: canvas.getContext("2d")!,
        viewport,
      });
      await task.promise;
    })
    .catch((error) => {
      if (!disposed && error?.name !== "RenderingCancelledException")
        onError(error);
    })
    .finally(() => {
      if (canvasWork.get(canvas) === work) canvasWork.delete(canvas);
    });
  canvasWork.set(canvas, work);
  return () => {
    disposed = true;
    task?.cancel();
    canvas.width = 0;
    canvas.height = 0;
    // PDF.js can only discard page resources once rendering has stopped.
    void work.then(() => page?.cleanup());
  };
}
