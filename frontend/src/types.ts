export type SourceFile = {
  path: string;
  text: string;
  revision: number;
  dirty: boolean;
  conflict?: { base: string; local: string; disk: string; deleted: boolean };
};
export type Project = {
  unsaved?: boolean;
  id: string;
  root: string;
  entry: string;
  files: Record<string, SourceFile>;
  revision: number;
  agentEnabled: boolean;
  lastOrigin: string;
};
export type Edit = { path: string; start: number; end: number; text: string };
export type Selection = {
  path: string;
  start: number;
  end: number;
  revision: number;
};
export type Syntax = {
  kind: string;
  start: number;
  end: number;
  children: Syntax[];
};
export type Parsed = { revision: number; tree: Syntax };
export type Diagnostic = {
  path?: string;
  start?: number;
  end?: number;
  message: string;
  hints?: string[];
};
export type Preview = {
  projectId?: string;
  revision: number;
  pdf?: string;
  previousPdf?: string;
  pages?: number;
  sourceMap?: PreviewAnchor[];
  pageRatios?: number[];
  diagnostics: Diagnostic[];
};
export type PreviewAnchor = {
  path: string;
  start: number;
  end: number;
  page: number;
  y: number;
};
export type PositionReader = { current: (() => Selection | null) | null };
export type Reference = {
  key: string;
  library: string;
  citeKey: string;
  title: string;
  author: string;
  year: string;
  version: number;
};
export const enc = new TextEncoder();
export const dec = new TextDecoder();
export const byteLength = (s: string) => enc.encode(s).length;
const byteCache = new Map<string, Uint8Array>();
const byteCacheBudget = 4 * 1024 * 1024;
let cachedBytes = 0;
export const byteSlice = (s: string, start: number, end?: number) => {
  let bytes = byteCache.get(s);
  if (!bytes) {
    bytes = enc.encode(s);
    // Keep one oversized source rather than encoding it again for every span.
    while (
      byteCache.size &&
      (byteCache.size >= 24 || cachedBytes + bytes.byteLength > byteCacheBudget)
    ) {
      const oldest = byteCache.keys().next().value!;
      cachedBytes -= byteCache.get(oldest)!.byteLength;
      byteCache.delete(oldest);
    }
    byteCache.set(s, bytes);
    cachedBytes += bytes.byteLength;
  }
  return dec.decode(bytes.subarray(start, end));
};
export function minimalEdit(
  path: string,
  before: string,
  after: string,
  offset = 0,
): Edit | null {
  if (before === after) return null;
  let start = 0,
    beforeEnd = before.length,
    afterEnd = after.length;
  while (
    start < Math.min(beforeEnd, afterEnd) &&
    before.charCodeAt(start) === after.charCodeAt(start)
  )
    start++;
  // Keep UTF-16 surrogate pairs together before converting to UTF-8 offsets.
  const splitsPair = (text: string, at: number) =>
    at > 0 &&
    at < text.length &&
    text.charCodeAt(at - 1) >= 0xd800 &&
    text.charCodeAt(at - 1) <= 0xdbff &&
    text.charCodeAt(at) >= 0xdc00 &&
    text.charCodeAt(at) <= 0xdfff;
  if (splitsPair(before, start) || splitsPair(after, start)) start--;
  while (
    beforeEnd > start &&
    afterEnd > start &&
    before.charCodeAt(beforeEnd - 1) === after.charCodeAt(afterEnd - 1)
  ) {
    beforeEnd--;
    afterEnd--;
  }
  if (splitsPair(before, beforeEnd) || splitsPair(after, afterEnd)) {
    beforeEnd++;
    afterEnd++;
  }
  const firstByte = offset + byteLength(before.slice(0, start));
  return {
    path,
    start: firstByte,
    end: firstByte + byteLength(before.slice(start, beforeEnd)),
    text: after.slice(start, afterEnd),
  };
}
