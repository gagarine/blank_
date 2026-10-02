import { useEffect, useRef } from "react";
import { EditorState } from "@codemirror/state";
import {
  EditorView,
  keymap,
  lineNumbers,
  highlightActiveLine,
  drawSelection,
} from "@codemirror/view";
import { defaultKeymap, indentWithTab } from "@codemirror/commands";
import {
  StreamLanguage,
  syntaxHighlighting,
  defaultHighlightStyle,
} from "@codemirror/language";
import type { Project, Selection, PositionReader } from "./types";
import { minimalEdit, byteLength, byteSlice } from "./types";
import { apply, call } from "./api";
const typst = StreamLanguage.define({
  token(stream) {
    if (stream.match("//")) {
      stream.skipToEnd();
      return "comment";
    }
    if (stream.match(/^=+(?=\s)/)) return "heading";
    if (stream.match(/^#[\w-]+/)) return "keyword";
    if (stream.match(/^@[^\s\[\]]+/)) return "variableName";
    if (stream.match(/^"(?:[^"\\]|\\.)*"/)) return "string";
    if (stream.match(/^\$[^$]*\$/)) return "string";
    stream.next();
    return null;
  },
});
export function SourceEditor({
  project,
  path,
  onChange,
  onError,
  onSelection,
  visible,
  selection,
  positionReader,
}: {
  positionReader: PositionReader;
  visible: boolean;
  selection: Selection | null;
  project: Project;
  path: string;
  onChange: (p: Project) => void;
  onError: (e: unknown) => void;
  onSelection: (s: Selection) => void;
}) {
  const host = useRef<HTMLDivElement>(null),
    view = useRef<EditorView | null>(null),
    shadow = useRef(project),
    latest = useRef({ onChange, onError, onSelection }),
    queue = useRef(Promise.resolve()),
    remote = useRef(false),
    blocked = useRef(false);
  latest.current = { onChange, onError, onSelection };
  positionReader.current = () => {
    const v = view.current;
    if (!v) return null;
    const bounds = v.scrollDOM.getBoundingClientRect();
    const sel = v.state.selection.main;
    const caret = v.coordsAtPos(sel.from);
    const inView =
      caret && caret.top >= bounds.top && caret.bottom <= bounds.bottom;
    const pos = inView
      ? sel.from
      : v.posAtCoords({
          x: v.contentDOM.getBoundingClientRect().left + 32,
          y: bounds.top + bounds.height * 0.35,
        });
    if (pos == null) return null;
    return {
      path,
      start: byteLength(v.state.doc.sliceString(0, pos)),
      end: byteLength(v.state.doc.sliceString(0, inView ? sel.to : pos)),
      revision: shadow.current.files[path].revision,
    };
  };
  useEffect(() => {
    blocked.current = false;
    shadow.current = project;
    const f = project.files[path];
    if (!f || !host.current) return;
    view.current = new EditorView({
      parent: host.current,
      state: EditorState.create({
        doc: f.text,
        extensions: [
          EditorView.contentAttributes.of({ autocomplete: "off" }),
          EditorState.transactionFilter.of((tr) =>
            blocked.current && !remote.current && tr.docChanged ? [] : tr,
          ),
          EditorView.domEventHandlers({
            compositionend: () => {
              setTimeout(
                () =>
                  call<Project>("project.read")
                    .then((p) => latest.current.onChange({ ...p }))
                    .catch(latest.current.onError),
                0,
              );
            },
          }),
          lineNumbers(),
          drawSelection(),
          highlightActiveLine(),
          typst,
          syntaxHighlighting(defaultHighlightStyle),
          EditorView.lineWrapping,
          keymap.of([
            ...defaultKeymap,
            indentWithTab,
            {
              key: "Mod-z",
              run: () => {
                call<Project>("document.undo")
                  .then(latest.current.onChange)
                  .catch(latest.current.onError);
                return true;
              },
            },
            {
              key: "Mod-Shift-z",
              run: () => {
                call<Project>("document.redo")
                  .then(latest.current.onChange)
                  .catch(latest.current.onError);
                return true;
              },
            },
          ]),
          EditorView.updateListener.of((update) => {
            if (remote.current) return;
            const before = shadow.current;
            if (update.docChanged) {
              const text = update.state.doc.toString();
              const edit = minimalEdit(path, before.files[path].text, text);
              if (edit) {
                const p = {
                  ...before,
                  revision: before.revision + 1,
                  lastOrigin: "user",
                  files: {
                    ...before.files,
                    [path]: {
                      ...before.files[path],
                      text,
                      revision: before.files[path].revision + 1,
                      dirty: true,
                    },
                  },
                };
                shadow.current = p;
                latest.current.onChange(p);
                queue.current = queue.current.then(async () => {
                  if (blocked.current) return;
                  try {
                    const saved = await apply(before, [edit]);
                    const v = view.current;
                    if (
                      v &&
                      saved.files[path].revision ===
                        shadow.current.files[path].revision
                    ) {
                      const sel = v.state.selection.main;
                      call("context.selection", {
                        path,
                        start: byteLength(v.state.doc.sliceString(0, sel.from)),
                        end: byteLength(v.state.doc.sliceString(0, sel.to)),
                        revision: saved.files[path].revision,
                      }).catch(() => {});
                    }
                  } catch (e) {
                    blocked.current = true;
                    localStorage.setItem(
                      "still-recovery-draft",
                      JSON.stringify(shadow.current),
                    );
                    latest.current.onError(e);
                  }
                });
              }
            }
            if (!update.selectionSet && !update.docChanged) return;
            const sel = update.state.selection.main;
            latest.current.onSelection({
              path,
              start: byteLength(update.state.doc.sliceString(0, sel.from)),
              end: byteLength(update.state.doc.sliceString(0, sel.to)),
              revision: shadow.current.files[path].revision,
            });
          }),
          EditorView.theme({
            "&": { height: "100%", fontSize: "14px" },
            ".cm-content": {
              fontFamily: '"SFMono-Regular", Consolas, monospace',
              padding: "32px 0",
            },
            ".cm-line": { padding: "0 28px" },
            ".cm-gutters": {
              background: "transparent",
              border: "none",
              color: "#a09c94",
            },
            ".cm-activeLine": { background: "var(--selection)" },
            ".cm-scroller": { overflow: "auto" },
            "&.cm-focused": { outline: "none" },
          }),
        ],
      }),
    });
    return () => {
      view.current?.destroy();
      view.current = null;
    };
  }, [project.id, path]);
  useEffect(() => {
    if (project.revision < shadow.current.revision) return;
    shadow.current = project;
    const v = view.current,
      text = project.files[path]?.text;
    if (
      v &&
      text !== undefined &&
      v.state.doc.toString() !== text &&
      !v.composing
    ) {
      remote.current = true;
      const a = v.state.doc.toString(),
        e = minimalEdit(path, a, text)!;
      const bytes = new TextEncoder().encode(a);
      const from = new TextDecoder().decode(bytes.slice(0, e.start)).length,
        to = new TextDecoder().decode(bytes.slice(0, e.end)).length;
      v.dispatch({ changes: { from, to, insert: e.text } });
      remote.current = false;
    }
  }, [project]);
  useEffect(() => {
    const v = view.current;
    if (!visible || !v) return;
    const s = selection;
    if (s?.path === path) {
      const text = v.state.doc.toString();
      remote.current = true;
      v.dispatch({
        selection: {
          anchor: byteSlice(text, 0, s.start).length,
          head: byteSlice(text, 0, s.end).length,
        },
        effects: EditorView.scrollIntoView(byteSlice(text, 0, s.start).length, {
          y: "center",
        }),
      });
      remote.current = false;
    }
    v.focus();
  }, [visible, path]);
  return (
    <div
      className="source-editor"
      style={{ display: visible ? "block" : "none" }}
      ref={host}
    />
  );
}
