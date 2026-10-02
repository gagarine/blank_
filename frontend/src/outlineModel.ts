import type { Edit, Parsed, Project, Syntax } from "./types";
import { byteLength, byteSlice } from "./types";

export type OutlineMove = {
  path: string;
  start: number;
  end: number;
  scope: string;
  revision: number;
  kind: "section" | "include";
};
export type OutlineItem = {
  id: string;
  path: string;
  start: number;
  title: string;
  kind: "file" | "heading";
  children: OutlineItem[];
  move?: OutlineMove;
};
export function manuscriptOutline(
  project: Project,
  parsed: Record<string, Parsed>,
): OutlineItem[] {
  function file(path: string, id: string, ancestors: string[]): OutlineItem {
    const result: OutlineItem = {
      id,
      path,
      start: 0,
      title: path
        .split("/")
        .pop()!
        .replace(/\.typ$/, ""),
      kind: "file",
      children: [],
    };
    const source = project.files[path]?.text;
    if (source === undefined || ancestors.includes(path)) return result;
    const nodes = parsed[path]?.tree.children || [];
    const headings = nodes.filter((n) => n.kind === "Heading");
    const levelOf = (n: Syntax) =>
      byteSlice(source, n.start, n.end).match(/^=+/)?.[0].length || 1;
    const stack: { level: number; item: OutlineItem }[] = [
      { level: 0, item: result },
    ];
    const text = (n: Syntax): string => {
      if (n.kind === "Label" || n.kind.endsWith("Comment")) return "";
      if (["Markup", "Strong", "Emph"].includes(n.kind))
        return n.children.map(text).join("");
      if (["Star", "Underscore"].includes(n.kind)) return "";
      return byteSlice(source, n.start, n.end).replace(/^\\(?=.)/, "");
    };
    for (const [index, node] of nodes.entries()) {
      if (node.kind === "Heading") {
        const level = levelOf(node);
        while (stack.length > 1 && stack.at(-1)!.level >= level) stack.pop();
        const body = node.children.find((c) => c.kind === "Markup");
        const title = (
          body
            ? text(body)
            : byteSlice(source, node.start, node.end).replace(/^=+\s*/, "")
        ).trim();
        const end =
          headings.find((n) => n.start > node.start && levelOf(n) <= level)
            ?.start ?? byteLength(source);
        const item: OutlineItem = {
          id: `${id}:${node.start}`,
          path,
          start: node.start,
          title: title || "Untitled heading",
          kind: "heading",
          children: [],
          move: {
            path,
            start: node.start,
            end,
            scope: stack.at(-1)!.item.id,
            revision: project.files[path].revision,
            kind: "section",
          },
        };
        stack.at(-1)!.item.children.push(item);
        stack.push({ level, item });
      } else if (node.kind === "ModuleInclude") {
        const literal = byteSlice(source, node.start, node.end).match(
          /^include\s+"([^"\n]+)"\s*$/,
        );
        if (!literal) continue;
        const parts = literal[1].startsWith("/")
          ? []
          : path.split("/").slice(0, -1);
        for (const part of literal[1].split("/")) {
          if (part === "..") parts.pop();
          else if (part && part !== ".") parts.push(part);
        }
        const target = parts.join("/");
        if (!project.files[target] || [...ancestors, path].includes(target))
          continue;
        let chapter = file(target, `${id}/${node.start}:${target}`, [
          ...ancestors,
          path,
        ]);
        // The chapter title replaces its filename wrapper; the entrypoint itself
        // is never shown as an artificial root row.
        if (
          chapter.children.length === 1 &&
          chapter.children[0].kind === "heading"
        )
          chapter = chapter.children[0];
        const hash = nodes[index - 1];
        if (hash?.kind === "Hash") {
          const before = byteSlice(source, 0, hash.start),
            indent = before.slice(before.lastIndexOf("\n") + 1);
          const after = byteSlice(source, node.end),
            lineEnd = after.indexOf("\n");
          const tail = lineEnd < 0 ? after : after.slice(0, lineEnd);
          if (
            !indent.trim() &&
            (!tail.trim() || tail.trimStart().startsWith("//"))
          ) {
            chapter.move = {
              path,
              start: hash.start - byteLength(indent),
              end:
                node.end +
                byteLength(lineEnd < 0 ? after : after.slice(0, lineEnd + 1)),
              scope: stack.at(-1)!.item.id,
              revision: project.files[path].revision,
              kind: "include",
            };
          } else delete chapter.move;
        } else delete chapter.move;
        stack.at(-1)!.item.children.push(chapter);
      }
    }
    return result;
  }
  const roots = file(project.entry, project.entry, []).children;
  // This is the open document's outline, not a browser for neighbouring files.
  // A sole title in the entry file is already represented by the document itself;
  // start at its sections while keeping their source identities and move scopes.
  const title = roots[0];
  if (
    roots.length === 1 &&
    title.kind === "heading" &&
    title.path === project.entry &&
    title.children.length
  ) {
    return title.children;
  }
  return roots;
}

export function canReorderOutline(source: OutlineItem, target: OutlineItem) {
  const a = source.move,
    b = target.move;
  return !!(
    a &&
    b &&
    source.id !== target.id &&
    a.path === b.path &&
    a.scope === b.scope &&
    a.kind === b.kind &&
    (a.end <= b.start || b.end <= a.start)
  );
}
export function reorderOutline(
  project: Project,
  source: OutlineItem,
  target: OutlineItem,
  after: boolean,
): Edit[] {
  if (!canReorderOutline(source, target))
    throw Error(
      "Move a section beside another section at the same level, or a chapter beside another chapter.",
    );
  const a = source.move!,
    b = target.move!,
    file = project.files[a.path];
  if (!file || file.revision !== a.revision || file.revision !== b.revision)
    throw Error("The outline changed during the drag. Please try again.");
  const point = after ? b.end : b.start;
  if (point === a.start || point === a.end) return [];
  let text = byteSlice(file.text, a.start, a.end);
  // A last section may lack a final newline. Preserve its contents while
  // keeping its new neighbours on separate Typst lines.
  if (
    point > 0 &&
    !byteSlice(file.text, 0, point).endsWith("\n") &&
    !text.startsWith("\n")
  )
    text = "\n\n" + text;
  if (
    point < byteLength(file.text) &&
    !text.endsWith("\n") &&
    !byteSlice(file.text, point).startsWith("\n")
  )
    text += "\n\n";
  return [
    { path: a.path, start: a.start, end: a.end, text: "" },
    { path: a.path, start: point, end: point, text },
  ];
}
