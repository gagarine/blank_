import { createParseCache } from "./parseCache";
import type { Project, Edit, Parsed } from "./types";
declare global {
  interface Window {
    go?: {
      main: {
        App: { Call: (method: string, params: string) => Promise<string> };
      };
    };
    runtime?: {
      OnFileDrop?: (
        cb: (x: number, y: number, paths: string[]) => void,
        useDropTarget: boolean,
      ) => void;
      OnFileDropOff?: () => void;
      EventsOn: (name: string, cb: (data: any) => void) => () => void;
    };
  }
}
const base = location.port === "5173" ? "http://127.0.0.1:3415" : "";
export async function call<T = any>(
  method: string,
  params: any = {},
): Promise<T> {
  if (window.go)
    return JSON.parse(
      await window.go.main.App.Call(method, JSON.stringify(params)),
    );
  const r = await fetch(base + "/api", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  if (!r.ok) throw Error(await r.text());
  const data = await r.json();
  if (data.error) throw Error(data.error.message);
  return data.result;
}
export function subscribe(cb: (name: string, data: any) => void) {
  if (window.runtime) {
    const stops = ["document", "preview", "error", "command"].map((n) =>
      window.runtime!.EventsOn(n, (d) => cb(n, d)),
    );
    return () => stops.forEach((f) => f());
  }
  const stream = new EventSource(base + "/events");
  stream.onmessage = (e) => {
    const d = JSON.parse(e.data);
    cb(d.event, d.data);
  };
  return () => stream.close();
}
export function apply(project: Project, edits: Edit[], origin = "user") {
  const expected: Record<string, number> = {};
  for (const e of edits)
    expected[e.path] = project.files[e.path]?.revision || 0;
  return call<Project>("document.applyEdits", {
    projectId: project.id,
    expected,
    edits,
    origin,
  });
}

export const parseSource = createParseCache((path) =>
  call<Parsed>("document.parse", { path }),
);
