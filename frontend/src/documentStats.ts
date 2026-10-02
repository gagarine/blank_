import type { Node } from "prosemirror-model";

const words = new Intl.Segmenter(undefined, { granularity: "word" });
export function documentStatistics(doc: Node) {
  let wordCount = 0,
    characters = 0,
    headings = 0;
  const files = new Set<string>();
  doc.forEach((section) => files.add(section.attrs.path));
  doc.descendants((node) => {
    if (node.type.name === "heading") headings++;
    if (!node.isTextblock) return;
    const text = node.textBetween(0, node.content.size, " ", " ");
    characters += Array.from(text).length;
    for (const part of words.segment(text)) if (part.isWordLike) wordCount++;
    return false;
  });
  return { words: wordCount, characters, headings, files: files.size };
}
