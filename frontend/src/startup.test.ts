import { expect, it, vi } from "vitest";
import { initialDocument } from "./startup";
import type { Project } from "./types";

it("leaves an empty session on Home without opening a previous file or Help", async () => {
  const empty = { id: "" } as Project;
  const call = vi.fn().mockResolvedValue(empty);
  expect(await initialDocument(call)).toBe(empty);
  expect(call.mock.calls).toEqual([["project.read"]]);
});
it("retains a file explicitly opened by the host", async () => {
  const opened = { id: "chosen-document" } as Project;
  const call = vi.fn().mockResolvedValue(opened);
  expect(await initialDocument(call)).toBe(opened);
  expect(call).toHaveBeenCalledOnce();
});
