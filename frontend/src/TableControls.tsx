import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { ChevronDown, Plus } from "lucide-react";
import type { EditorView } from "prosemirror-view";
import { TextSelection, type Command } from "prosemirror-state";
import {
  isInTable,
  selectedRect,
  addRowBefore,
  addRowAfter,
  addColumnBefore,
  addColumnAfter,
  deleteRow,
  deleteColumn,
} from "prosemirror-tables";
import type { Selection } from "./types";

type Props = {
  view: EditorView | null;
  visible: boolean;
  selection: Selection | null;
  revision: number;
};
type Position = {
  left: number;
  top: number;
  right: number;
  bottom: number;
  row: string;
  column: string;
};

export function TableControls({ view, visible, selection, revision }: Props) {
  const [position, setPosition] = useState<Position | null>(null);
  const [menu, setMenu] = useState<"row" | "column" | null>(null);
  const controls = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!view || !visible) {
      setPosition(null);
      setMenu(null);
      return;
    }
    let frame = 0;
    const update = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        if (
          (!view.hasFocus() &&
            !controls.current?.contains(document.activeElement)) ||
          !isInTable(view.state)
        ) {
          setPosition(null);
          setMenu(null);
          return;
        }
        const rect = selectedRect(view.state);
        const dom = view.nodeDOM(rect.tableStart - 1) as HTMLElement | null;
        const table = dom?.querySelector("table") || dom;
        const scroll = view.dom.closest(".writing-scroll");
        if (!table || !scroll) return;
        const box = table.getBoundingClientRect(),
          bounds = scroll.getBoundingClientRect();
        if (box.bottom < bounds.top || box.top > bounds.bottom) {
          setPosition(null);
          return;
        }
        const range = (from: number, to: number) =>
          to - from === 1 ? String(from + 1) : `${from + 1}–${to}`;
        const next = {
          left: Math.max(8, box.left),
          top: Math.max(bounds.top + 4, box.top - 32),
          right: Math.min(window.innerWidth - 28, box.right + 2),
          bottom: Math.min(bounds.bottom - 28, box.bottom + 2),
          row: range(rect.top, rect.bottom),
          column: range(rect.left, rect.right),
        };
        setPosition((old) =>
          old &&
          Object.keys(next).every(
            (key) => old[key as keyof Position] === next[key as keyof Position],
          )
            ? old
            : next,
        );
      });
    };
    update();
    document.addEventListener("scroll", update, true);
    document.addEventListener("focusin", update);
    window.addEventListener("resize", update);
    const observer = new ResizeObserver(update);
    observer.observe(view.dom);
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
      document.removeEventListener("scroll", update, true);
      document.removeEventListener("focusin", update);
      window.removeEventListener("resize", update);
    };
  }, [view, visible, selection, revision]);
  useEffect(() => {
    setMenu(null);
  }, [selection]);
  useEffect(() => {
    const close = (event: MouseEvent) => {
      if (!controls.current?.contains(event.target as Node)) setMenu(null);
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, []);
  if (!view || !position || !visible) return null;
  const run = (command: Command, append?: "row" | "column") => {
    if (!isInTable(view.state)) return;
    const original = selectedRect(view.state);
    if (append) {
      const rect = original;
      const cell = rect.map.positionAt(
        append === "row" ? rect.map.height - 1 : rect.top,
        append === "column" ? rect.map.width - 1 : rect.left,
        rect.table,
      );
      view.dispatch(
        view.state.tr.setSelection(
          TextSelection.near(
            view.state.doc.resolve(rect.tableStart + cell + 1),
          ),
        ),
      );
    }
    command(view.state, view.dispatch);
    if (append && isInTable(view.state)) {
      const rect = selectedRect(view.state);
      const cell = rect.map.positionAt(
        append === "row" ? original.map.height : original.top,
        append === "column" ? original.map.width : original.left,
        rect.table,
      );
      view.dispatch(
        view.state.tr
          .setSelection(
            TextSelection.near(
              view.state.doc.resolve(rect.tableStart + cell + 1),
            ),
          )
          .scrollIntoView(),
      );
    }
    view.focus();
    setMenu(null);
  };
  const actions =
    menu === "row"
      ? [
          { label: "Insert row above", command: addRowBefore },
          { label: "Insert row below", command: addRowAfter },
          { label: "Delete selected row", command: deleteRow },
        ]
      : [
          { label: "Insert column before", command: addColumnBefore },
          { label: "Insert column after", command: addColumnAfter },
          { label: "Delete selected column", command: deleteColumn },
        ];
  return createPortal(
    <div
      ref={controls}
      className="table-controls"
      onMouseDown={(e) => e.preventDefault()}
      onKeyDown={(e) => {
        if (e.key === "Escape") {
          e.preventDefault();
          setMenu(null);
          view.focus();
        }
      }}
    >
      <div
        className="table-tools"
        role="group"
        aria-label="Table controls"
        style={{ left: position.left, top: position.top }}
      >
        <button
          aria-expanded={menu === "row"}
          onClick={() => setMenu(menu === "row" ? null : "row")}
        >
          Row {position.row}
          <ChevronDown size={12} />
        </button>
        <button
          aria-expanded={menu === "column"}
          onClick={() => setMenu(menu === "column" ? null : "column")}
        >
          Column {position.column}
          <ChevronDown size={12} />
        </button>
        {menu && (
          <div
            className="table-action-menu"
            role="group"
            aria-label={`${menu} actions`}
          >
            {actions.map(({ label, command }) => (
              <button key={label} onClick={() => run(command)}>
                {label}
              </button>
            ))}
          </div>
        )}
      </div>
      <button
        className="table-add"
        style={{ left: position.left, top: position.bottom }}
        aria-label="Add row at end"
        title="Add row"
        onClick={() => run(addRowAfter, "row")}
      >
        <Plus size={14} />
        <span>Row</span>
      </button>
      <button
        className="table-add table-add-column"
        style={{ left: position.right, top: position.top + 34 }}
        aria-label="Add column at end"
        title="Add column"
        onClick={() => run(addColumnAfter, "column")}
      >
        <Plus size={14} />
      </button>
    </div>,
    document.body,
  );
}
