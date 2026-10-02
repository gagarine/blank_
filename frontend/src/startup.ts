import type { Project } from "./types";

// Only a document explicitly opened by the native host may replace Home.
// Stored recent paths are choices, never startup instructions.
export async function initialDocument(
  call: (method: string, params?: object) => Promise<Project>,
): Promise<Project> {
  return call("project.read");
}
