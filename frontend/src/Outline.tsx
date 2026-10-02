import { memo, useEffect, useMemo, useRef, useState } from "react";
import { ChevronRight, FileText } from "lucide-react";
import { parseSource } from "./api";
import type { Parsed, Project } from "./types";
import {
  canReorderOutline,
  manuscriptOutline,
  type OutlineItem,
} from "./outlineModel";

export const Outline = memo(function Outline({
  project,
  active,
  activeOffset,
  onNavigate,
  onReorder,
  onError,
}: {
  project: Project;
  active: string;
  activeOffset: number;
  onNavigate: (item: OutlineItem) => void;
  onReorder: (
    source: OutlineItem,
    target: OutlineItem,
    after: boolean,
    projectId: string,
  ) => Promise<void>;
  onError: (error: unknown) => void;
}) {
  const [items, setItems] = useState<OutlineItem[]>([]);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(true);
  const [drop, setDrop] = useState<{ id: string; after: boolean } | null>(null);
  const dragged = useRef<{ item: OutlineItem; projectId: string } | null>(null);
  useEffect(() => {
    setCollapsed(new Set());
    setItems([]);
    setLoading(true);
    dragged.current = null;
    setDrop(null);
  }, [project.id]);
  useEffect(() => {
    let cancelled = false;
    const timer = setTimeout(
      async () => {
        try {
          const parsed: Record<string, Parsed> = {};
          for (const f of Object.values(project.files).filter((f) =>
            f.path.endsWith(".typ"),
          )) {
            const result = await parseSource(project, f.path);
            if (cancelled || result.revision !== f.revision) return;
            parsed[f.path] = result;
          }
          if (!cancelled) {
            setItems(manuscriptOutline(project, parsed));
            setLoading(false);
          }
        } catch {
          /* Keep the last outline while the helper reconnects. */
        }
      },
      loading ? 0 : 200,
    );
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [project.id, project.revision]);
  let chapter: OutlineItem | undefined;
  const findChapter = (nodes: OutlineItem[], parentPath?: string) => {
    for (const item of nodes) {
      if (
        item.path === active &&
        item.path !== parentPath &&
        (!chapter ||
          (item.start <= activeOffset && item.start >= chapter.start))
      )
        chapter = item;
      findChapter(item.children, item.path);
    }
  };
  findChapter(items);
  const currentChapter = chapter?.id;
  function branch(item: OutlineItem, siblings: OutlineItem[]) {
    const expanded = !collapsed.has(item.id);
    return (
      <li key={item.id}>
        <div
          className={
            "outline-row " +
            (item.kind === "file" ? "outline-file " : "") +
            (currentChapter === item.id ? "current-chapter " : "") +
            (drop?.id === item.id
              ? drop.after
                ? "drop-after"
                : "drop-before"
              : "")
          }
          draggable={!!item.move}
          onDragStart={(e) => {
            if (!item.move) {
              e.preventDefault();
              return;
            }
            e.stopPropagation();
            dragged.current = { item, projectId: project.id };
            e.dataTransfer.effectAllowed = "move";
            e.dataTransfer.setData("application/x-blank-outline", item.id);
          }}
          onDragOver={(e) => {
            const source = dragged.current;
            if (!source) return;
            e.preventDefault();
            e.stopPropagation();
            if (!canReorderOutline(source.item, item)) {
              e.dataTransfer.dropEffect = "none";
              setDrop(null);
              return;
            }
            e.dataTransfer.dropEffect = "move";
            const bounds = e.currentTarget.getBoundingClientRect();
            setDrop({
              id: item.id,
              after: e.clientY > (bounds.top + bounds.bottom) / 2,
            });
          }}
          onDrop={(e) => {
            const source = dragged.current;
            if (!source) return;
            e.preventDefault();
            e.stopPropagation();
            const box = e.currentTarget.getBoundingClientRect();
            dragged.current = null;
            setDrop(null);
            if (canReorderOutline(source.item, item))
              onReorder(
                source.item,
                item,
                e.clientY > (box.top + box.bottom) / 2,
                source.projectId,
              ).catch(onError);
          }}
          onDragEnd={() => {
            dragged.current = null;
            setDrop(null);
          }}
        >
          {item.children.length > 0 ? (
            <button
              className="outline-toggle"
              aria-label={(expanded ? "Collapse " : "Expand ") + item.title}
              aria-expanded={expanded}
              onClick={() =>
                setCollapsed((old) => {
                  const next = new Set(old);
                  if (expanded) next.add(item.id);
                  else next.delete(item.id);
                  return next;
                })
              }
            >
              <ChevronRight
                size={12}
                style={{ transform: expanded ? "rotate(90deg)" : undefined }}
              />
            </button>
          ) : (
            <span className="outline-spacer" />
          )}
          <button
            className="outline-entry"
            aria-current={currentChapter === item.id ? "location" : undefined}
            onClick={() => onNavigate(item)}
            onKeyDown={(e) => {
              if (e.altKey && ["ArrowUp", "ArrowDown"].includes(e.key)) {
                e.preventDefault();
                const direction = e.key === "ArrowUp" ? -1 : 1;
                const index = siblings.indexOf(item);
                const target = siblings[index + direction];
                if (target && canReorderOutline(item, target))
                  onReorder(item, target, direction === 1, project.id).catch(
                    onError,
                  );
              }
            }}
          >
            {item.kind === "file" && <FileText size={13} />}
            <span>{item.title}</span>
          </button>
        </div>
        {item.children.length > 0 && expanded && (
          <ul>{item.children.map((child) => branch(child, item.children))}</ul>
        )}
      </li>
    );
  }
  const tree = useMemo(
    () => items.map((item) => branch(item, items)),
    [
      items,
      currentChapter,
      collapsed,
      drop,
      project.id,
      onNavigate,
      onReorder,
      onError,
    ],
  );
  return (
    <nav className="outline" aria-label="Table of contents">
      <ul>{tree}</ul>
      {!items.length && (
        <p className="outline-loading">
          {loading ? "Preparing table of contents…" : "No headings yet."}
        </p>
      )}
    </nav>
  );
});
