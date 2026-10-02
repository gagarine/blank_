import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { typingShortcut } from "./typingShortcuts";
import { GripVertical } from "lucide-react";
import { TableControls } from "./TableControls";
import { nextTableCell } from "./tableCommands";
import { blockArrow, clickBesideBlock } from "./blockNavigation";
import { replaceAcrossSections } from "./sectionEditing";
import {
  blockAt,
  moveBlock,
  moveBlockBy,
  blockAction,
  matchingCommands,
  slashTransaction,
  type InsertKind,
} from "./blockCommands";
import {
  EditorState,
  TextSelection,
  Selection as PMSelection,
} from "prosemirror-state";
import { EditorView, Decoration, DecorationSet } from "prosemirror-view";
import { Node as PMNode } from "prosemirror-model";
import { baseKeymap, toggleMark } from "prosemirror-commands";
import { keymap } from "prosemirror-keymap";
import { gapCursor } from "prosemirror-gapcursor";
import { tableEditing, goToNextCell, TableView } from "prosemirror-tables";
import { call, apply, parseSource } from "./api";
import type { Project, Parsed, Selection, PositionReader } from "./types";
import { byteSlice } from "./types";
import {
  writerSchema as schema,
  projectDocument,
  documentEdits,
  reanchorDocument,
  sourceLocation,
  editorPosition,
} from "./projection";

type Props = {
  positionReader: PositionReader;
  visible: boolean;
  navigation: number;
  selection: Selection | null;
  project: Project;
  active: string;
  continuous: boolean;
  focus: boolean;
  typewriter: boolean;
  onError: (e: unknown) => void;
  onChange: (p: Project) => void;
  onSelection: (s: Selection) => void;
  onAtom: (node: PMNode) => void;
  onView: (view: EditorView | null) => void;
  onCite: () => void;
  onInsert: (kind: InsertKind) => void;
  onMedia: (files: File[]) => void;
};
function crossChapter(v: EditorView, text?: string) {
  const tr = replaceAcrossSections(v.state, text);
  if (!tr) return false;
  v.dispatch(tr);
  return true;
}
// Source metadata changes every keystroke. Keep editable DOM nodes alive so
// WebKit's native selection, spelling and IME composition remain attached.
const contentViews = Object.fromEntries(
  ["section", "paragraph", "heading", "list_item", "blockquote"].map((name) => [
    name,
    (node: PMNode) => {
      const tag =
        name === "section"
          ? "section"
          : name === "paragraph"
            ? "p"
            : name === "heading"
              ? "h" + Math.min(6, node.attrs.level)
              : name === "blockquote"
                ? "blockquote"
                : "div";
      const dom = document.createElement(tag);
      const update = (next: PMNode) => {
        if (
          next.type !== node.type ||
          (name === "heading" && next.attrs.level !== node.attrs.level)
        )
          return false;
        if (name === "section") {
          dom.dataset.file = next.attrs.path;
          dom.dataset.section = next.attrs.id;
        }
        if (name === "list_item") {
          dom.className = "list-item";
          dom.dataset.marker = next.attrs.ordered ? "1." : "•";
        }
        node = next;
        return true;
      };
      update(node);
      return { dom, contentDOM: dom, update };
    },
  ]),
);
export function RichEditor(props: Props) {
  const host = useRef<HTMLDivElement>(null),
    view = useRef<EditorView | null>(null),
    latest = useRef(props),
    shadow = useRef(props.project),
    queue = useRef(Promise.resolve()),
    generation = useRef(0),
    blocked = useRef(false);
  latest.current = props;
  props.positionReader.current = () => {
    const v = view.current;
    const root = host.current?.closest(".writing-scroll");
    if (!v || !root) return null;
    const bounds = root.getBoundingClientRect();
    const caret = v.coordsAtPos(v.state.selection.from);
    const inView = caret.top >= bounds.top && caret.bottom <= bounds.bottom;
    const column = v.dom.getBoundingClientRect();
    const pos = inView
      ? v.state.selection.from
      : v.posAtCoords({
          left: Math.max(bounds.left + 1, column.left + 8),
          top: bounds.top + bounds.height * 0.35,
        })?.pos;
    if (pos === undefined) return null;
    const start = sourceLocation(v.state.doc, pos);
    const end = inView
      ? sourceLocation(v.state.doc, v.state.selection.to)
      : start;
    if (!start || !shadow.current.files[start.path]) return null;
    return {
      path: start.path,
      start: start.offset,
      end: end?.path === start.path ? end.offset : start.offset,
      revision: shadow.current.files[start.path].revision,
    };
  };
  const [loading, setLoading] = useState(true);
  type Slash = {
    from: number;
    to: number;
    query: string;
    index: number;
    left: number;
    top: number;
  };
  const [slash, setSlash] = useState<Slash | null>(null);
  const slashRef = useRef<Slash | null>(null);
  const [handle, setHandle] = useState<{
    pos: number;
    left: number;
    top: number;
  } | null>(null);
  const [dropLine, setDropLine] = useState<{
    left: number;
    top: number;
    width: number;
  } | null>(null);
  const drag = useRef<{ from: number; doc: PMNode } | null>(null);
  const handlePressed = useRef(false);
  const [blockMenu, setBlockMenu] = useState<"actions" | "turn" | null>(null);
  const blockMenuRef = useRef(blockMenu);
  blockMenuRef.current = blockMenu;
  const runBlockAction = (action: string) => {
    const v = view.current;
    if (!v || !handle) return;
    try {
      const tr = blockAction(v.state, handle.pos, action);
      if (tr) v.dispatch(tr);
      v.focus();
    } catch (error) {
      latest.current.onError(error);
    }
    setBlockMenu(null);
    setHandle(null);
  };
  const closeSlash = () => {
    slashRef.current = null;
    setSlash(null);
    view.current?.dom.removeAttribute("aria-controls");
    view.current?.dom.removeAttribute("aria-activedescendant");
  };
  const syncSlash = (v: EditorView) => {
    const previous = slashRef.current;
    if (!previous) return;
    const { from, $from, empty } = v.state.selection;
    if (
      !empty ||
      !$from.parent.isTextblock ||
      previous.from < $from.start() ||
      previous.from >= from
    ) {
      closeSlash();
      return;
    }
    const text = v.state.doc.textBetween(previous.from, from);
    if (!/^\/[^\n/]{0,50}$/.test(text)) {
      closeSlash();
      return;
    }
    const box = v.coordsAtPos(from);
    const next = {
      from: previous.from,
      to: from,
      query: text.slice(1),
      index: text.slice(1) === previous.query ? previous.index : 0,
      left: Math.max(12, Math.min(box.left, window.innerWidth - 292)),
      top:
        box.bottom + 8 + 330 > window.innerHeight
          ? Math.max(12, box.top - 338)
          : box.bottom + 8,
    };
    slashRef.current = next;
    setSlash(next);
    v.dom.setAttribute("aria-controls", "slash-options");
    v.dom.setAttribute("aria-activedescendant", "slash-option-" + next.index);
  };
  const chooseSlash = (id: string) => {
    const v = view.current,
      current = slashRef.current;
    if (!v || !current) return;
    try {
      const tr = slashTransaction(v.state, current.from, current.to, id);
      closeSlash();
      v.dispatch(tr);
      v.focus();
      if (
        [
          "image",
          "table",
          "citation",
          "footnote",
          "equation",
          "link",
          "label",
          "reference",
        ].includes(id)
      )
        latest.current.onInsert(id as InsertKind);
    } catch (error) {
      latest.current.onError(error);
    }
  };
  const move = (pos: number, direction: -1 | 1) => {
    const v = view.current;
    if (!v) return;
    try {
      const tr = moveBlockBy(v.state, pos, direction);
      if (tr) v.dispatch(tr);
      v.focus();
    } catch (e) {
      latest.current.onError(e);
    }
    setHandle(null);
  };
  const dropTarget = (v: EditorView, event: DragEvent) => {
    const scroller = host.current?.closest(".writing-scroll");
    if (!scroller) return null;
    const area = scroller.getBoundingClientRect();
    if (
      event.clientX < area.left ||
      event.clientX > area.right ||
      event.clientY < area.top ||
      event.clientY > area.bottom
    )
      return null;
    // The handle lives in the gutter; dragging straight down that gutter must
    // resolve the same block boundaries as dragging over its text.
    const bounds = v.dom.getBoundingClientRect();
    const coords = v.posAtCoords({
      left: Math.max(
        bounds.left + 1,
        Math.min(event.clientX, bounds.right - 1),
      ),
      top: Math.max(bounds.top + 1, Math.min(event.clientY, bounds.bottom - 1)),
    });
    const pos = coords && blockAt(v.state.doc, coords.pos);
    if (pos == null) return null;
    const dom = v.nodeDOM(pos) as HTMLElement | null,
      node = v.state.doc.nodeAt(pos);
    if (!dom || !node) return null;
    const box = dom.getBoundingClientRect(),
      after = event.clientY > (box.top + box.bottom) / 2;
    const target = after ? pos + node.nodeSize : pos;
    const boundary = v.state.doc.resolve(target);
    const previous = boundary.nodeBefore;
    const next = boundary.nodeAfter;
    const previousDOM = previous
      ? (v.nodeDOM(target - previous.nodeSize) as HTMLElement | null)
      : null;
    const nextDOM = next ? (v.nodeDOM(target) as HTMLElement | null) : null;
    const previousBox = previousDOM?.getBoundingClientRect();
    const nextBox = nextDOM?.getBoundingClientRect();
    // Both sides of the same insertion boundary share one indicator position.
    const top =
      previousBox && nextBox
        ? (previousBox.bottom + nextBox.top) / 2
        : (previousBox?.bottom ?? nextBox?.top ?? box.top);
    return {
      pos: target,
      left: bounds.left,
      top,
      width: bounds.width,
    };
  };
  const showHandle = (v: EditorView, event: MouseEvent) => {
    if (drag.current || handlePressed.current) return false;
    if (!v.state.selection.empty || event.buttons) {
      setHandle(null);
      return false;
    }
    if (v.composing || slashRef.current || blockMenuRef.current) return false;
    const found = v.posAtCoords({ left: event.clientX, top: event.clientY });
    const pos = found && blockAt(v.state.doc, found.pos);
    const dom = pos != null ? (v.nodeDOM(pos) as HTMLElement | null) : null;
    if (dom && pos != null) {
      const box = dom.getBoundingClientRect();
      // Centre the grip on the first line, including headings with larger type
      // and text inside list/quote wrappers. Block tops ignore font/line height.
      const line = dom.matches("p,h1,h2,h3,h4,h5,h6,pre")
        ? dom
        : dom.querySelector<HTMLElement>("p,h1,h2,h3,h4,h5,h6,pre") || dom;
      const style = getComputedStyle(line);
      const lineHeight =
        parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.2;
      const inset =
        (parseFloat(style.borderTopWidth) || 0) +
        (parseFloat(style.paddingTop) || 0);
      const center = line.getBoundingClientRect().top + inset + lineHeight / 2;
      setHandle({ pos, left: box.left - 32, top: center - 27 / 2 });
    }
    return false;
  };
  useEffect(() => {
    let alive = true;
    const gen = ++generation.current;
    setLoading(true);
    closeSlash();
    setHandle(null);
    drag.current = null;
    setDropLine(null);
    blocked.current = false;
    shadow.current = props.project;
    (async () => {
      const relevant = Object.values(props.project.files).filter((f) =>
        f.path.endsWith(".typ"),
      );
      const parsed: Record<string, Parsed> = {};
      for (const f of relevant) {
        parsed[f.path] = await parseSource(props.project, f.path);
      }

      if (!alive || gen !== generation.current) return;
      const doc = projectDocument(
        props.project,
        parsed,
        props.active,
        props.continuous,
      );
      const plugins = [
        keymap({
          "Mod-b": toggleMark(schema.marks.strong),
          "Mod-i": toggleMark(schema.marks.em),
          "Mod-z": () => {
            call<Project>("document.undo")
              .then((p) => latest.current.onChange(p))
              .catch(latest.current.onError);
            return true;
          },
          "Mod-Shift-z": () => {
            call<Project>("document.redo")
              .then((p) => latest.current.onChange(p))
              .catch(latest.current.onError);
            return true;
          },
          "Mod-Shift-c": () => {
            latest.current.onCite();
            return true;
          },
          Tab: nextTableCell,
          "Shift-Tab": goToNextCell(-1),
          ...baseKeymap,
        }),
        gapCursor(),
        tableEditing(),
      ];
      const old = view.current;
      const s = latest.current.selection;
      const pos = s
        ? editorPosition(doc, s.path, s.start)
        : Math.min(old?.state.selection.from || 1, doc.content.size);
      const state = EditorState.create({
        doc,
        plugins,
        selection: PMSelection.near(doc.resolve(pos)),
      });
      if (old) {
        old.updateState(state);
      } else if (host.current) {
        view.current = new EditorView(host.current, {
          state,
          attributes: {
            spellcheck: "true",
            autocomplete: "off",
            "aria-label": "Document editor",
            role: "textbox",
            "aria-multiline": "true",
          },
          editable: () => !blocked.current,
          decorations: (state) => {
            const p = state.selection.$from;
            if (p.depth < 2) return null;
            return DecorationSet.create(state.doc, [
              Decoration.node(p.before(2), p.after(2), { class: "is-active" }),
            ]);
          },
          handleDOMEvents: {
            cut: (v, event) => {
              const tr = replaceAcrossSections(v.state);
              if (!tr || !event.clipboardData) return false;
              const { dom, text } = v.serializeForClipboard(
                v.state.selection.content(),
              );
              event.clipboardData.clearData();
              event.clipboardData.setData("text/html", dom.innerHTML);
              event.clipboardData.setData("text/plain", text);
              event.preventDefault();
              v.dispatch(tr);
              return true;
            },
            mousemove: showHandle,
            mouseover: showHandle,
            mouseup: showHandle,
            keydown: (_v, event) => {
              if (event.key !== "Alt" && !event.altKey) {
                setHandle(null);
              }
              return false;
            },
            blur: (_v, event) => {
              closeSlash();
              const target = event.relatedTarget;
              if (
                !drag.current &&
                !handlePressed.current &&
                !(
                  target instanceof Element && target.closest(".block-controls")
                )
              ) {
                setHandle(null);
              }
              return false;
            },
            compositionend: () => {
              setTimeout(() => {
                call<Project>("project.read")
                  .then((p) => {
                    shadow.current = {
                      ...shadow.current,
                      revision: Math.min(
                        shadow.current.revision,
                        p.revision - 1,
                      ),
                    };
                    latest.current.onChange({ ...p });
                  })
                  .catch(latest.current.onError);
              }, 0);
              return false;
            },
            click: (_v, e) => {
              if ((e.target as HTMLElement).closest("a")) {
                e.preventDefault();
                return true;
              }
              return false;
            },
          },
          nodeViews: {
            ...contentViews,
            table: (node) => new TableView(node, 80),
            raw_block: (node) => {
              const dom = document.createElement("div");
              dom.className = "raw-block";
              dom.dataset.kind = node.attrs.kind;
              dom.contentEditable = "false";
              const label = document.createElement("span");
              label.className = "raw-label";
              label.textContent = ["Figure", "Image"].includes(node.attrs.kind)
                ? "Figure · click to edit"
                : node.attrs.label || node.attrs.kind;
              dom.append(label);
              const raw = node.attrs.raw as string;
              const image = raw.match(/#?(?:figure\(\s*)?image\("([^"\n]+)"/);
              if (image) {
                const isPDF = /\.pdf$/i.test(image[1]);
                const visual = document.createElement(isPDF ? "canvas" : "img");
                visual.className = "figure-image";
                visual.style.width =
                  (raw.match(/width:\s*(\d+)%/)?.[1] || "100") + "%";
                const alt =
                  raw.match(/alt:\s*"([^"\n]*)"/)?.[1] ||
                  raw.match(/caption:\s*\[([^\]]*)\]/)?.[1] ||
                  "Figure";
                visual.setAttribute("aria-label", alt);
                if (visual instanceof HTMLImageElement) {
                  visual.alt = alt;
                  visual.loading = "lazy";
                }
                dom.append(visual);
                const base = node.attrs.path.split("/").slice(0, -1);
                for (const piece of image[1].split("/")) {
                  if (piece === "..") base.pop();
                  else if (piece !== "." && piece) base.push(piece);
                }
                const observer = new IntersectionObserver(
                  (entries) => {
                    if (!entries.some((e) => e.isIntersecting)) return;
                    observer.disconnect();
                    call<{ data: string; mime: string }>("asset.read", {
                      path: base.join("/"),
                    })
                      .then(async (a) => {
                        if (visual instanceof HTMLImageElement)
                          visual.src = "data:" + a.mime + ";base64," + a.data;
                        else
                          await (
                            await import("./PdfPreview")
                          ).renderPdfFigure(
                            a.data,
                            visual as HTMLCanvasElement,
                            Number(raw.match(/page:\s*(\d+)/)?.[1] || 1),
                          );
                      })
                      .catch((e) => {
                        const missing = document.createElement("p");
                        missing.textContent =
                          "Figure unavailable: " + String(e);
                        dom.append(missing);
                      });
                  },
                  { rootMargin: "600px" },
                );
                observer.observe(dom);
                const caption = document.createElement("p");
                caption.className = "figure-caption";
                caption.textContent =
                  raw.match(/caption:\s*\[([^\]]*)\]/)?.[1] || "";
                dom.append(caption);
                return {
                  dom,
                  ignoreMutation: () => true,
                  destroy: () => observer.disconnect(),
                };
              } else {
                const pre = document.createElement("pre");
                pre.textContent = raw;
                dom.append(pre);
              }
              return { dom, ignoreMutation: () => true };
            },
          },
          handleClickOn: (_v, _pos, node) => {
            if (node.isAtom && !node.isText) {
              latest.current.onAtom(node);
              return true;
            }
            return false;
          },
          handleDrop: (_v, event) => {
            const files = Array.from(event.dataTransfer?.files || []);
            if (files.length && !window.go) {
              latest.current.onMedia(files);
              return true;
            }
            return false;
          },
          handlePaste: (v, event) => {
            const files = Array.from(event.clipboardData?.files || []);
            if (files.length) {
              event.preventDefault();
              latest.current.onMedia(files);
              return true;
            }
            if (
              crossChapter(v, event.clipboardData?.getData("text/plain") || "")
            ) {
              event.preventDefault();
              return true;
            }
            return false;
          },
          handleTextInput: (v, from, to, text) => {
            if (!v.composing) {
              const shortcut = typingShortcut(v.state, from, to, text);
              if (shortcut) {
                v.dispatch(shortcut);
                return true;
              }
            }
            if (
              text === "/" &&
              from === to &&
              !v.composing &&
              v.state.selection.$from.depth === 2
            ) {
              const $pos = v.state.doc.resolve(from);
              if (
                $pos.parent.isTextblock &&
                ($pos.parentOffset === 0 ||
                  /\s$/.test($pos.parent.textBetween(0, $pos.parentOffset)))
              )
                slashRef.current = {
                  from,
                  to,
                  query: "",
                  index: 0,
                  left: 0,
                  top: 0,
                };
            }
            return crossChapter(v, text);
          },
          handleKeyDown: (v, event) => {
            if (v.composing || event.isComposing) return false;
            const current = slashRef.current;
            if (current) {
              if (event.key === "Escape") {
                closeSlash();
                return true;
              }
              const choices = matchingCommands(current.query);
              if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                const count = choices.length;
                const next = {
                  ...current,
                  index: count
                    ? (current.index +
                        (event.key === "ArrowDown" ? 1 : count - 1)) %
                      count
                    : 0,
                };
                slashRef.current = next;
                setSlash(next);
                v.dom.setAttribute(
                  "aria-activedescendant",
                  "slash-option-" + next.index,
                );
                return true;
              }
              if (event.key === "Enter" && choices[current.index]) {
                chooseSlash(choices[current.index].id);
                return true;
              }
            }
            if (
              event.altKey &&
              !event.metaKey &&
              !event.ctrlKey &&
              ["ArrowUp", "ArrowDown"].includes(event.key)
            ) {
              const pos = blockAt(v.state.doc, v.state.selection.from);
              if (pos !== null) {
                move(pos, event.key === "ArrowUp" ? -1 : 1);
                return true;
              }
            }
            if (event.key === "Backspace" || event.key === "Delete")
              return crossChapter(v);
            if (blockArrow(v, event)) return true;
            return false;
          },
          dispatchTransaction: (tr) => {
            const v = view.current!;
            const oldState = v.state;
            let next = oldState.apply(tr);
            if (tr.docChanged) {
              try {
                const before = shadow.current;
                const edits = documentEdits(oldState.doc, next.doc, before);
                if (edits.length) {
                  const files = { ...before.files };
                  for (const path of new Set(edits.map((e) => e.path))) {
                    const f = files[path];
                    let text = f.text;
                    for (const e of edits
                      .filter((e) => e.path === path)
                      .sort((a, b) => b.start - a.start))
                      text =
                        byteSlice(text, 0, e.start) +
                        e.text +
                        byteSlice(text, e.end);
                    files[path] = {
                      ...f,
                      text,
                      revision: f.revision + 1,
                      dirty: true,
                    };
                  }
                  const optimistic = {
                    ...before,
                    files,
                    revision: before.revision + 1,
                    lastOrigin: "user",
                  };
                  shadow.current = optimistic;
                  const mapped = reanchorDocument(
                    oldState.doc,
                    next.doc,
                    before,
                    edits,
                  );
                  const select = next.selection;
                  next = EditorState.create({
                    doc: mapped,
                    plugins: next.plugins,
                    storedMarks: next.storedMarks,
                    selection: PMSelection.fromJSON(mapped, select.toJSON()),
                  });
                  latest.current.onChange(optimistic);
                  queue.current = queue.current.then(async () => {
                    if (blocked.current) return;
                    try {
                      const saved = await apply(before, edits);
                      const v = view.current;
                      if (v) {
                        const start = sourceLocation(
                            v.state.doc,
                            v.state.selection.from,
                          ),
                          end = sourceLocation(
                            v.state.doc,
                            v.state.selection.to,
                          );
                        if (
                          start &&
                          saved.files[start.path]?.revision ===
                            shadow.current.files[start.path]?.revision
                        )
                          call("context.selection", {
                            path: start.path,
                            start: start.offset,
                            end:
                              end?.path === start.path
                                ? end.offset
                                : start.offset,
                            revision: saved.files[start.path].revision,
                          }).catch(() => {});
                      }
                    } catch (e) {
                      blocked.current = true;
                      localStorage.setItem(
                        "still-recovery-draft",
                        JSON.stringify(shadow.current),
                      );
                      latest.current.onError(
                        new Error(
                          String(e) +
                            " — your draft is retained in this view and browser recovery storage. Copy it before reloading.",
                        ),
                      );
                    }
                  });
                }
              } catch (e) {
                latest.current.onError(e);
                return;
              }
            }
            v.updateState(next);
            if (!next.selection.empty) {
              setHandle(null);
            }
            syncSlash(v);
            const start = sourceLocation(next.doc, next.selection.from),
              end = sourceLocation(next.doc, next.selection.to);
            if (start) {
              const f = shadow.current.files[start.path];
              latest.current.onSelection({
                path: start.path,
                start: start.offset,
                end: end?.path === start.path ? end.offset : start.offset,
                revision: f.revision,
              });
            }
            if (latest.current.typewriter && tr.docChanged) {
              requestAnimationFrame(() => {
                const box = v.coordsAtPos(v.state.selection.from);
                const scroller = host.current?.closest(".writing-scroll");
                if (scroller) {
                  scroller.scrollBy({
                    top:
                      box.top -
                      scroller.getBoundingClientRect().top -
                      scroller.clientHeight * 0.45,
                    behavior: "smooth",
                  });
                }
              });
            }
          },
        });
        latest.current.onView(view.current);
      }
      setLoading(false);
    })().catch((e) => {
      setLoading(false);
      latest.current.onError(e);
    });
    return () => {
      alive = false;
    };
  }, [props.project.id, props.active, props.continuous]);
  useEffect(() => {
    const incoming = props.project;
    if (incoming.id !== shadow.current.id) return;
    if (incoming.revision <= shadow.current.revision) return;
    if (view.current?.composing) {
      const timer = setTimeout(
        () =>
          call<Project>("project.read").then((p) => latest.current.onChange(p)),
        150,
      );
      return () => clearTimeout(timer);
    }
    shadow.current = incoming;
    const gen = ++generation.current;
    queue.current
      .then(async () => {
        const parsed: Record<string, Parsed> = {};
        for (const f of Object.values(incoming.files).filter((f) =>
          f.path.endsWith(".typ"),
        )) {
          parsed[f.path] = await parseSource(incoming, f.path);
        }
        if (gen !== generation.current || !view.current) return;

        const doc = projectDocument(
          incoming,
          parsed,
          props.active,
          props.continuous,
        );
        const v = view.current,
          loc = sourceLocation(v.state.doc, v.state.selection.from),
          pos = loc
            ? editorPosition(doc, loc.path, loc.offset)
            : Math.min(v.state.selection.from, doc.content.size);
        v.updateState(
          EditorState.create({
            doc,
            plugins: v.state.plugins,
            selection: TextSelection.near(doc.resolve(pos)),
          }),
        );
        closeSlash();
        setHandle(null);
        setBlockMenu(null);
        drag.current = null;
        setDropLine(null);
      })
      .catch(props.onError);
  }, [props.project]);
  useEffect(() => {
    const v = view.current,
      s = props.selection;
    if (!props.visible || !v || loading) return;
    // A fresh document has no saved selection yet. Its initial ProseMirror
    // selection is already a valid insertion point; make it ready for typing.
    if (!s) {
      if (!document.querySelector('[role="dialog"]')) v.focus();
      return;
    }
    const from = editorPosition(v.state.doc, s.path, s.start),
      to = editorPosition(v.state.doc, s.path, s.end);
    try {
      v.dispatch(
        v.state.tr
          .setSelection(TextSelection.create(v.state.doc, from, to))
          .scrollIntoView(),
      );
      v.focus();
      // Offscreen sections use deferred layout. Resolve their real geometry
      // before revealing a distant outline target, rather than its estimate.
      let second = 0;
      const frame = requestAnimationFrame(() => {
        const pos = blockAt(v.state.doc, v.state.selection.from);
        const dom =
          pos !== null ? (v.nodeDOM(pos) as HTMLElement | null) : null;
        const section = dom?.closest("section");
        if (section) section.style.contentVisibility = "visible";
        const center = () => {
          const root = host.current?.closest(".writing-scroll");
          if (root)
            root.scrollTop +=
              v.coordsAtPos(from).top -
              root.getBoundingClientRect().top -
              root.clientHeight * 0.35;
        };
        center();
        second = requestAnimationFrame(() => {
          center();
          if (section) section.style.contentVisibility = "";
        });
      });
      return () => {
        cancelAnimationFrame(frame);
        cancelAnimationFrame(second);
      };
    } catch {}
  }, [props.visible, loading, props.navigation]);
  useEffect(() => {
    const root = host.current?.closest(".writing-scroll");
    if (!root) return;
    const click = (event: Event) => {
      const v = view.current;
      if (!latest.current.visible || !v || blocked.current) return;
      if (clickBesideBlock(v, event as MouseEvent)) event.stopPropagation();
    };
    // Include the blank space outside ProseMirror's own content box.
    root.addEventListener("mousedown", click, true);
    return () => root.removeEventListener("mousedown", click, true);
  }, []);
  useEffect(
    () => () => {
      view.current?.destroy();
      view.current = null;
      latest.current.onView(null);
    },
    [],
  );
  useEffect(() => {
    const closeBlockMenu = (event: MouseEvent) => {
      if (!(event.target as Element).closest(".block-controls"))
        setBlockMenu(null);
    };
    document.addEventListener("mousedown", closeBlockMenu);
    const release = () => {
      handlePressed.current = false;
    };
    const over = (event: DragEvent) => {
      const source = drag.current,
        v = view.current;
      if (!source || !v) return;
      event.preventDefault();
      event.stopPropagation();
      const target = dropTarget(v, event);
      const allowed =
        source.doc === v.state.doc &&
        target &&
        v.state.doc.resolve(target.pos).start(1) ===
          v.state.doc.resolve(source.from).start(1);
      setDropLine(allowed ? target : null);
      if (event.dataTransfer)
        event.dataTransfer.dropEffect = allowed ? "move" : "none";
      const scroller = host.current?.closest(".writing-scroll");
      if (scroller && target) {
        const box = scroller.getBoundingClientRect();
        if (event.clientY < box.top + 50) scroller.scrollTop -= 18;
        if (event.clientY > box.bottom - 50) scroller.scrollTop += 18;
      }
    };
    const drop = (event: DragEvent) => {
      const source = drag.current,
        v = view.current;
      if (!source || !v) return;
      event.preventDefault();
      event.stopPropagation();
      drag.current = null;
      handlePressed.current = false;
      setDropLine(null);
      setHandle(null);
      if (source.doc !== v.state.doc) {
        latest.current.onError(
          "The document changed during the drag. Please try again.",
        );
        return;
      }
      const target = dropTarget(v, event);
      if (target)
        try {
          const tr = moveBlock(v.state, source.from, target.pos);
          if (tr) v.dispatch(tr);
          v.focus();
        } catch (error) {
          latest.current.onError(error);
        }
    };
    document.addEventListener("mouseup", release);
    document.addEventListener("dragover", over, true);
    document.addEventListener("drop", drop, true);
    return () => {
      document.removeEventListener("mouseup", release);
      document.removeEventListener("mousedown", closeBlockMenu);
      document.removeEventListener("dragover", over, true);
      document.removeEventListener("drop", drop, true);
    };
  }, []);
  useEffect(() => {
    const hide = () => {
      if (drag.current) return;
      setBlockMenu(null);
      setHandle(null);
      if (view.current) syncSlash(view.current);
    };
    const leave = (e: MouseEvent) => {
      const target = e.target as Element;
      if (drag.current || blockMenuRef.current) return;
      if (!target.closest(".rich-editor, .block-controls")) {
        setHandle(null);
      }
    };
    document.addEventListener("scroll", hide, true);
    document.addEventListener("mousemove", leave);
    window.addEventListener("resize", hide);
    return () => {
      document.removeEventListener("scroll", hide, true);
      document.removeEventListener("mousemove", leave);
      window.removeEventListener("resize", hide);
    };
  }, []);
  useEffect(() => {
    if (!props.visible) {
      setBlockMenu(null);
      closeSlash();
      setHandle(null);
    }
  }, [props.visible]);
  useEffect(() => {
    document
      .getElementById("slash-option-" + slash?.index)
      ?.scrollIntoView({ block: "nearest" });
  }, [slash?.index, slash?.query]);
  const choices = slash ? matchingCommands(slash.query) : [];
  return (
    <div className={"rich-editor " + (props.focus ? "paragraph-focus" : "")}>
      <div ref={host} />
      <TableControls
        view={view.current}
        visible={props.visible && !loading && !slash}
        selection={props.selection}
        revision={props.project.revision}
      />
      {loading && (
        <div className="editor-loading">Preparing your document…</div>
      )}
      {props.visible &&
        slash &&
        createPortal(
          <div
            className="slash-menu"
            style={{ left: slash.left, top: slash.top }}
            onMouseDown={(e) => e.preventDefault()}
          >
            <div className="slash-heading">
              {slash.query ? "Matching blocks" : "Insert or turn into"}
              <kbd>esc</kbd>
            </div>
            <div
              role="listbox"
              id="slash-options"
              aria-label="Insert a block"
              className="slash-options"
            >
              {choices.map((c, i) => (
                <button
                  type="button"
                  role="option"
                  aria-selected={i === slash.index}
                  id={"slash-option-" + i}
                  key={c.id}
                  className={i === slash.index ? "selected" : ""}
                  onMouseDown={(e) => {
                    e.preventDefault();
                    chooseSlash(c.id);
                  }}
                >
                  <span className="slash-symbol">{c.symbol}</span>
                  <span>
                    <strong>{c.label}</strong>
                    <small>{c.hint}</small>
                  </span>
                </button>
              ))}
              {!choices.length && (
                <p className="slash-empty">No matching blocks</p>
              )}
            </div>
          </div>,
          document.body,
        )}
      {props.visible &&
        handle &&
        !slash &&
        createPortal(
          <div
            className="block-controls"
            style={{ left: handle.left, top: handle.top }}
          >
            <button
              draggable
              onMouseDown={() => {
                handlePressed.current = true;
              }}
              aria-label="Move block"
              title="Drag to move, click for block actions"
              aria-expanded={!!blockMenu}
              onClick={() => setBlockMenu(blockMenu ? null : "actions")}
              onKeyDown={(e) => {
                if (e.key === "ArrowUp" || e.key === "ArrowDown") {
                  e.preventDefault();
                  move(handle.pos, e.key === "ArrowUp" ? -1 : 1);
                }
              }}
              onDragStart={(e) => {
                const v = view.current;
                if (!v) return;
                drag.current = { from: handle.pos, doc: v.state.doc };
                setBlockMenu(null);
                closeSlash();
                e.dataTransfer.effectAllowed = "move";
                e.dataTransfer.setData(
                  "application/x-still-block",
                  String(handle.pos),
                );
                const node = v.nodeDOM(handle.pos);
                if (node instanceof HTMLElement)
                  e.dataTransfer.setDragImage(node, 0, 0);
              }}
              onDragEnd={() => {
                handlePressed.current = false;
                drag.current = null;
                setDropLine(null);
                setHandle(null);
              }}
            >
              <GripVertical size={15} />
            </button>
            {blockMenu && (
              <div
                className="block-menu"
                role="group"
                aria-label="Block actions"
                onMouseDown={(e) => e.preventDefault()}
                onKeyDown={(e) => {
                  if (e.key === "Escape") {
                    setBlockMenu(null);
                    view.current?.focus();
                  }
                }}
              >
                {blockMenu === "turn" ? (
                  <>
                    <button onClick={() => setBlockMenu("actions")}>
                      ← Back
                    </button>
                    {matchingCommands("")
                      .filter((c) =>
                        [
                          "paragraph",
                          "heading1",
                          "heading2",
                          "heading3",
                          "bullet",
                          "number",
                          "quote",
                        ].includes(c.id),
                      )
                      .map((c) => (
                        <button key={c.id} onClick={() => runBlockAction(c.id)}>
                          {c.label}
                        </button>
                      ))}
                  </>
                ) : (
                  <>
                    {view.current?.state.doc.nodeAt(handle.pos)
                      ?.isTextblock && (
                      <button onClick={() => setBlockMenu("turn")}>
                        Turn into…
                      </button>
                    )}
                    <button onClick={() => runBlockAction("duplicate")}>
                      Duplicate
                    </button>
                    <button onClick={() => runBlockAction("delete")}>
                      Delete
                    </button>
                  </>
                )}
              </div>
            )}
          </div>,
          document.body,
        )}
      {props.visible &&
        dropLine &&
        createPortal(
          <div
            className="block-drop-line"
            style={{
              left: dropLine.left,
              top: dropLine.top,
              width: dropLine.width,
            }}
          />,
          document.body,
        )}
    </div>
  );
}
