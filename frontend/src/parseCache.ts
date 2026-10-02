import type { Parsed, Project } from "./types";

// One parse per file revision, shared by the editor, contents and statistics.
// Switching projects releases the previous project's trees and source strings.
export function createParseCache(parse: (path: string) => Promise<Parsed>) {
  let projectId = "";
  const cache = new Map<
    string,
    { text: string; revision: number; result: Promise<Parsed> }
  >();
  return (project: Project, path: string): Promise<Parsed> => {
    if (projectId !== project.id) {
      cache.clear();
      projectId = project.id;
    }
    for (const key of cache.keys()) if (!project.files[key]) cache.delete(key);
    const file = project.files[path];
    const cached = cache.get(path);
    if (cached?.text === file.text && cached.revision === file.revision)
      return cached.result;
    const result = parse(path)
      .then((result) => {
        if (result.revision !== file.revision && cache.get(path) === entry)
          cache.delete(path);
        return result;
      })
      .catch((error) => {
        if (cache.get(path) === entry) cache.delete(path);
        throw error;
      });
    const entry = { text: file.text, revision: file.revision, result };
    cache.set(path, entry);
    return entry.result;
  };
}
