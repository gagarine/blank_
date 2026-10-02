import { useEffect, useState } from "react";
import { call, parseSource } from "./api";
import type { Parsed, Preview, Project } from "./types";
import { projectDocument } from "./projection";
import { documentStatistics } from "./documentStats";

type Information = {
  agentSocket?: string;
  projectId: string;
  revision: number;
  files: Record<
    string,
    {
      created: string | null;
      lastSaved: string | null;
      bytes: number;
      dirty: boolean;
      missing: boolean;
    }
  >;
};
export function Statistics({
  project,
  path,
  preview,
}: {
  project: Project;
  path: string;
  preview: Preview | null;
}) {
  const [data, setData] = useState<{
    counts: ReturnType<typeof documentStatistics>;
    info: Information;
  } | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let cancelled = false;
    const timer = setTimeout(async () => {
      try {
        const parsed: Record<string, Parsed> = {};
        for (const file of Object.values(project.files).filter((f) =>
          f.path.endsWith(".typ"),
        )) {
          const result = await parseSource(project, file.path);
          if (cancelled || result.revision !== file.revision) return;
          parsed[file.path] = result;
        }
        const counts = documentStatistics(
          projectDocument(project, parsed, project.entry, true),
        );
        const info = await call<Information>("project.info");
        if (
          !cancelled &&
          info.projectId === project.id &&
          info.revision === project.revision
        ) {
          setData({ counts, info });
          setError("");
        }
      } catch (e) {
        if (!cancelled) setError(String(e));
      }
    }, 180);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [project]);
  if (error) return <p role="alert">{error}</p>;
  if (!data) return <p className="muted">Reading document information…</p>;
  const file = data.info.files[path];
  const date = (value?: string | null) =>
    value
      ? new Date(value).toLocaleString(undefined, {
          dateStyle: "medium",
          timeStyle: "short",
        })
      : "Unavailable";
  const details = [
    ["File", path],
    ["Project folder", project.unsaved ? "Not saved yet" : project.root],
    ["Main file", project.entry],
    ["Created", project.unsaved ? "Not saved yet" : date(file?.created)],
    ["Last saved", project.unsaved ? "Not saved yet" : date(file?.lastSaved)],
    [
      "File status",
      project.unsaved
        ? "Unsaved document"
        : file?.missing
          ? "Missing on disk"
          : project.files[path]?.conflict
            ? "Changes need review"
            : file?.dirty
              ? "Unsaved changes"
              : "Saved",
    ],
    ["Document headings", data.counts.headings.toLocaleString()],
    [
      "Typst files",
      Object.values(project.files)
        .filter((file) => file.path.endsWith(".typ"))
        .length.toLocaleString(),
    ],
    [
      "File size",
      file
        ? (file.bytes / 1024).toLocaleString(undefined, {
            maximumFractionDigits: 1,
          }) + " KB"
        : "Unavailable",
    ],
    [
      "PDF pages",
      preview?.revision === project.revision &&
      !preview.diagnostics?.length &&
      preview.pages
        ? String(preview.pages)
        : "Preview out of date",
    ],
  ];
  if (project.agentEnabled && data.info.agentSocket)
    details.push(["Agent socket", data.info.agentSocket]);
  return (
    <div className="statistics">
      <div className="statistics-counts">
        <div>
          <strong>{data.counts.words.toLocaleString()}</strong>
          <span>document words</span>
        </div>
        <div>
          <strong>{data.counts.characters.toLocaleString()}</strong>
          <span>characters</span>
        </div>
      </div>
      <dl>
        {details.map(([name, value]) => (
          <div key={name}>
            <dt>{name}</dt>
            <dd>{value}</dd>
          </div>
        ))}
      </dl>
      <p className="statistics-note">
        Counts include headings and writing text across the manuscript,
        including unsaved edits. Typst code and generated content are excluded.
      </p>
    </div>
  );
}
