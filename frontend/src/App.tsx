import {
  useCallback,
  useEffect,
  useRef,
  useState,
  lazy,
  Suspense,
} from "react";
import { EditorView } from "prosemirror-view";
import { TextSelection } from "prosemirror-state";
import { Node as PMNode } from "prosemirror-model";
import { toggleMark } from "prosemirror-commands";
import {
  PanelLeft,
  PenLine,
  Code2,
  BookOpen,
  Search,
  Sun,
  Moon,
  Focus,
  Quote,
  Link,
  Check,
  FolderOpen,
  FileText,
  Download,
  X,
  Undo2,
  BookMarked,
  Command,
  Maximize,
  RefreshCw,
  Settings2,
  ChartNoAxesColumn,
} from "lucide-react";
import { call, subscribe, apply } from "./api";
import type {
  Project,
  Selection,
  Preview,
  Reference,
  PositionReader,
} from "./types";
import { byteLength, minimalEdit } from "./types";
import { writerSchema, escapeText } from "./projection";
import { RichEditor } from "./RichEditor";
import { Outline } from "./Outline";
import { ContentsSidebar } from "./ContentsSidebar";
import { initialDocument } from "./startup";
import { Home } from "./Home";
import { externalFilePaths } from "./fileDrop";
import { reorderOutline, type OutlineItem } from "./outlineModel";
import { editorPosition } from "./projection";
import { SourceEditor } from "./SourceEditor";
import { Statistics } from "./Statistics";
import { Settings, useAppearance } from "./Settings";
const PdfPreview = lazy(() =>
  import("./PdfPreview").then((m) => ({ default: m.PdfPreview })),
);

type Modal =
  | "commands"
  | "statistics"
  | "settings"
  | "citation"
  | "open"
  | "save"
  | "equation"
  | "footnote"
  | "link"
  | "image"
  | "table"
  | "source"
  | "search"
  | "style"
  | "label"
  | "reference"
  | null;
export default function App() {
  const [project, setProject] = useState<Project | null>(null),
    [mode, setMode] = useState<"write" | "source" | "preview">("write"),
    [active, setActive] = useState(""),
    [continuous, setContinuous] = useState(true),
    [navigation, setNavigation] = useState(0),
    [sidebar, setSidebar] = useState(false),
    [focus, setFocus] = useState(false),
    [typewriter, setTypewriter] = useState(false),
    [theme, setTheme] = useState(
      localStorage.getItem("still-theme") || "light",
    ),
    [modal, setModal] = useState<Modal>(null),
    [error, setError] = useState(""),
    [preview, setPreview] = useState<Preview | null>(null),
    [busy, setBusy] = useState(false),
    [selection, setSelection] = useState<Selection | null>(null),
    [atom, setAtom] = useState<PMNode | null>(null),
    [atomRevision, setAtomRevision] = useState(0),
    [query, setQuery] = useState(""),
    [field, setField] = useState(""),
    [extra, setExtra] = useState(""),
    [refs, setRefs] = useState<Reference[]>([]),
    [chosen, setChosen] = useState<Reference[]>([]),
    [library, setLibrary] = useState("personal"),
    [groups, setGroups] = useState<any[]>([]),
    [citeForm, setCiteForm] = useState(""),
    [finding, setFinding] = useState(false),
    [citationError, setCitationError] = useState(""),
    [imageWidth, setImageWidth] = useState("85"),
    [imageAlt, setImageAlt] = useState(""),
    [pdfPage, setPdfPage] = useState("1");
  const [appearance, setAppearance] = useAppearance();
  const displayedFile = project?.entry || "";
  useEffect(() => {
    const title = displayedFile?.split("/").pop() || "blank_";
    document.title = title;
    if (window.go)
      call("window.title", { title }).catch((fail) => console.error(fail));
  }, [displayedFile]);
  const previousModal = useRef<Modal>(null);
  const selectionRef = useRef(selection);
  selectionRef.current = selection;
  const editor = useRef<EditorView | null>(null),
    current = useRef(project),
    scroller = useRef<HTMLDivElement>(null),
    lastCompiled = useRef(-1),
    compileTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  current.current = project;
  const modeRef = useRef(mode);
  modeRef.current = mode;
  const writePosition: PositionReader = useRef(null);
  const sourcePosition: PositionReader = useRef(null);
  const previewPosition: PositionReader = useRef(null);
  const switchMode = useCallback((next: "write" | "source" | "preview") => {
    if (next === modeRef.current) return;
    const readers = {
      write: writePosition,
      source: sourcePosition,
      preview: previewPosition,
    };
    const position =
      readers[modeRef.current].current?.() || selectionRef.current;
    if (position && current.current?.files[position.path]) {
      setSelection(position);
      selectionRef.current = position;
      setActive(position.path);
      call("context.selection", position).catch(() => {});
    }
    setMode(next);
  }, []);
  useEffect(() => {
    if (modal) {
      const dialog = document.querySelector<HTMLElement>('[role="dialog"]');
      if (dialog && !dialog.contains(document.activeElement)) dialog.focus();
    }
    if (previousModal.current && !modal && mode === "write")
      requestAnimationFrame(() => editor.current?.focus());
    previousModal.current = modal;
  }, [modal, mode]);
  const fail = useCallback(
    (e: unknown) => setError(e instanceof Error ? e.message : String(e)),
    [],
  );
  const accept = useCallback((p: Project) => {
    if (!p?.id) return;
    setProject((old) =>
      old?.id === p.id && old.revision > p.revision ? old : p,
    );
    setActive((old) => (p.files[old] ? old : p.entry));
  }, []);
  useEffect(() => {
    initialDocument(call).then(accept).catch(fail);
    return subscribe((event, data) => {
      if (event === "document") accept(data);
      if (
        event === "preview" &&
        data.projectId === current.current?.id &&
        data.revision === current.current?.revision
      )
        setPreview(data);
      if (event === "error") fail(data);
      if (event === "command") {
        if (data === "settings" || data === "statistics") openModal(data);
        if (data === "open") openFile();
        if (data === "new") newDoc();
        if (data === "help") openHelp();
        if (data === "save") saveDocument();
        if (data === "contents") setSidebar((value) => !value);
        if (data === "undo" || data === "redo") {
          const focused = document.activeElement;
          if (
            focused?.matches("input, textarea") &&
            !focused.closest(".cm-editor")
          ) {
            document.execCommand(data);
          } else
            call<Project>("document." + data)
              .then(accept)
              .catch(fail);
        }
      }
    });
  }, []);
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem("still-theme", theme);
  }, [theme]);
  useEffect(() => {
    const handler = () =>
      call<Project>("document.rescan").then(accept).catch(fail);
    window.addEventListener("focus", handler);
    return () => window.removeEventListener("focus", handler);
  }, []);
  useEffect(() => {
    lastCompiled.current = -1;
    setPreview(null);
    setSelection(null);
    setContinuous(true);
  }, [project?.id]);
  const compile = useCallback(async () => {
    if (!current.current || busy) return;
    const requested = current.current;
    setBusy(true);
    try {
      const p = await call<Preview>("preview.compile");
      if (
        p.projectId === current.current?.id &&
        p.revision === current.current?.revision
      ) {
        setPreview(p);
        lastCompiled.current = p.revision;
      }
    } catch (e) {
      if (
        requested.id === current.current?.id &&
        requested.revision === current.current?.revision
      ) {
        lastCompiled.current = requested.revision;
        fail(e);
      }
    } finally {
      setBusy(false);
    }
  }, [busy]);
  useEffect(() => {
    if (!project || lastCompiled.current === project.revision) return;
    clearTimeout(compileTimer.current);
    compileTimer.current = setTimeout(compile, 450);
    return () => clearTimeout(compileTimer.current);
  }, [project?.revision, project?.id, busy]);
  const select = useCallback((s: Selection) => {
    setSelection(s);
    call("context.selection", s).catch(() => {});
  }, []);
  const openModal = useCallback((m: Modal) => {
    if (
      m !== null &&
      !current.current &&
      !["commands", "settings", "open"].includes(m)
    )
      return;
    setModal(m);
    setField("");
    setExtra("");
    setQuery("");
    setAtom(null);
    setAtomRevision(0);
    if (m === "image") {
      setImageWidth("85");
      setImageAlt("");
      setPdfPage("1");
    }
    if (m === "citation") {
      setChosen([]);
      setRefs([]);
      setCitationError("");
      call<any[]>("zotero.groups")
        .then((g) => setGroups(g || []))
        .catch(() => {});
      setCiteForm("");
    }
  }, []);
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (e.key === "Escape") {
        setModal(null);
        setError("");
        return;
      }
      if (mod && e.key === ",") {
        e.preventDefault();
        openModal("settings");
      }
      if (mod && e.key.toLowerCase() === "k") {
        e.preventDefault();
        openModal("commands");
      }
      if (mod && e.key.toLowerCase() === "n") {
        e.preventDefault();
        newDoc();
      }
      if (mod && e.key.toLowerCase() === "o") {
        e.preventDefault();
        openFile();
      }
      if (mod && e.key === "s") {
        e.preventDefault();
        saveDocument();
      }
      if (mod && e.shiftKey && e.key.toLowerCase() === "c") {
        e.preventDefault();
        openModal("citation");
      }
      if (mod && e.key === "1") {
        e.preventDefault();
        switchMode("write");
      }
      if (mod && e.key === "2") {
        e.preventDefault();
        switchMode("source");
      }
      if (mod && e.key === "3") {
        e.preventDefault();
        switchMode("preview");
      }
      if (mod && e.key === "f") {
        e.preventDefault();
        openModal("search");
      }
    };
    const pinKey = (e: KeyboardEvent) => {
      if (
        (e.metaKey || e.ctrlKey) &&
        e.shiftKey &&
        !e.altKey &&
        e.key.toLowerCase() === "l"
      ) {
        e.preventDefault();
        e.stopPropagation();
        setSidebar((pinned) => !pinned);
      }
    };
    // Capture this shortcut before editor-specific selection bindings.
    window.addEventListener("keydown", pinKey, true);
    window.addEventListener("keydown", key);
    return () => {
      window.removeEventListener("keydown", pinKey, true);
      window.removeEventListener("keydown", key);
    };
  }, []);
  useEffect(() => {
    if (modal !== "citation") return;
    let alive = true;
    setFinding(true);
    const timer = setTimeout(
      () =>
        call<Reference[]>("zotero.search", { query, library })
          .then((r) => {
            if (alive) {
              setRefs(r || []);
              setCitationError("");
            }
          })
          .catch((e) => {
            if (alive) {
              setRefs([]);
              setCitationError(e instanceof Error ? e.message : String(e));
            }
          })
          .finally(() => {
            if (alive) setFinding(false);
          }),
      180,
    );
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [query, library, modal]);
  const insert = async (text: string, block = false) => {
    const p = current.current;
    if (!p) return;
    const s =
      selection && p.files[selection.path]
        ? selection
        : {
            path: active,
            start: byteLength(p.files[active].text),
            end: byteLength(p.files[active].text),
            revision: p.files[active].revision,
          };
    if (p.files[s.path].revision !== s.revision)
      throw Error(
        "The document changed; place the cursor again before inserting.",
      );
    const snippet = block ? "\n\n" + text + "\n\n" : text;
    accept(
      await apply(p, [
        { path: s.path, start: s.start, end: s.end, text: snippet },
      ]),
    );
    setModal(null);
  };
  const submit = async () => {
    try {
      if (
        atom &&
        atomRevision &&
        project?.files[atom.attrs.path]?.revision !== atomRevision &&
        !project?.files[atom.attrs.path]?.conflict
      )
        throw Error(
          "This source region changed. Close this dialog and select it again.",
        );
      if (modal === "open") {
        accept(await call("project.open", { path: field }));
        setModal(null);
      }
      if (modal === "save") {
        accept(await call("document.save", { path: field }));
        setModal(null);
      }
      if (modal === "equation") await insert("$ " + field + " $", true);
      if (modal === "label" || modal === "reference") {
        if (!/^[A-Za-z][\w:.-]*$/.test(field))
          throw Error(
            "Use a label starting with a letter, followed by letters, digits, colon, dash, or dot.",
          );
        await insert(modal === "label" ? "<" + field + ">" : "@" + field);
      }
      if (modal === "footnote")
        await insert("#footnote[" + escapeText(field) + "]");
      if (modal === "link")
        await insert(
          "#link(" +
            JSON.stringify(field) +
            ")[" +
            escapeText(extra || field) +
            "]",
        );
      if (modal === "image") {
        const width = Math.max(1, Math.min(100, Number(imageWidth) || 85));
        const text =
          "#figure(image(" +
          JSON.stringify(field) +
          ", width: " +
          width +
          "%, alt: " +
          JSON.stringify(imageAlt || extra) +
          (/\.pdf$/i.test(field)
            ? ", page: " + Math.max(1, Number(pdfPage) || 1)
            : "") +
          "), caption: [" +
          escapeText(extra) +
          "])";
        if (atom && project) {
          accept(
            await apply(project, [
              {
                path: atom.attrs.path,
                start: atom.attrs.start,
                end: atom.attrs.end,
                text,
              },
            ]),
          );
          setModal(null);
        } else await insert(text, true);
      }
      if (modal === "table") {
        const rows = Math.max(1, Math.min(30, Number(field) || 3)),
          cols = Math.max(1, Math.min(12, Number(extra) || 3));
        await insert(
          "#table(columns: " +
            cols +
            ",\n" +
            Array.from(
              { length: rows },
              (_, r) =>
                "  " +
                Array.from(
                  { length: cols },
                  (_, c) => "[" + (r === 0 ? "Column " + (c + 1) : "…") + "]",
                ).join(", ") +
                ",",
            ).join("\n") +
            "\n)",
          true,
        );
      }
      if (modal === "source" && atom && project) {
        const p = atom.attrs.path;
        accept(
          project.files[p]?.conflict
            ? await call("document.resolve", { path: p, text: field })
            : await apply(project, [
                {
                  path: p,
                  start: atom.attrs.start,
                  end: atom.attrs.end,
                  text: field,
                },
              ]),
        );
        setModal(null);
      }
      if (modal === "style" && project) {
        const path = project.entry,
          source = project.files[path].text;
        const changed = source.replace(
          /(#bibliography\([^\n]*style:\s*)"[^"\n]*"/g,
          "$1" + JSON.stringify(field || "apa"),
        );
        if (changed === source)
          throw Error(
            "Set the bibliography style in Source for this custom template.",
          );
        const edit = minimalEdit(path, source, changed);
        if (edit) accept(await apply(project, [edit]));
        setModal(null);
      }
      if (modal === "citation" && project) {
        const s = selection || {
          path: active,
          start: byteLength(project.files[active].text),
          end: byteLength(project.files[active].text),
          revision: project.files[active].revision,
        };
        accept(
          await call("citation.insert", {
            ...s,
            projectId: project.id,
            items: chosen,
            locator: field,
            form: citeForm,
          }),
        );
        setModal(null);
      }
    } catch (e) {
      if (modal === "citation")
        setCitationError(e instanceof Error ? e.message : String(e));
      else fail(e);
    }
  };
  const importedFigure = (path: string, keepSettings = false) => {
    if (!path) return;
    const dir = (selectionRef.current?.path || active).split("/").slice(0, -1);
    if (!keepSettings) openModal("image");
    setField("../".repeat(dir.length) + path);
  };
  const importFiles = async (files: File[]) => {
    try {
      if (!files.length) return;
      if (files.length > 1)
        throw Error("Insert one figure at a time to give each a caption.");
      const file = files[0];
      if (file.size > 32 * 1024 * 1024)
        throw Error("Choose a figure smaller than 32 MB.");
      const encoded = await new Promise<string>((resolve, reject) => {
        const reader = new FileReader();
        reader.onerror = () => reject(reader.error);
        reader.onload = () => resolve(String(reader.result).split(",")[1]);
        reader.readAsDataURL(file);
      });
      importedFigure(
        await call<string>("asset.add", {
          name: file.name || "pasted-image.png",
          data: encoded,
        }),
      );
    } catch (e) {
      fail(e);
    }
  };
  useEffect(() => {
    if (!window.runtime?.OnFileDrop) return;
    window.runtime.OnFileDrop((x, y, droppedPaths) => {
      const paths = externalFilePaths(droppedPaths);
      // Wails/macOS also emits this callback for internal text/block drags.
      // Ignore those before touching the editor selection or importing files.
      if (!paths.length) return;
      const v = editor.current;
      const at = v?.posAtCoords({ left: x, top: y });
      if (v && at) {
        v.focus();
        v.dispatch(
          v.state.tr.setSelection(
            TextSelection.near(v.state.doc.resolve(at.pos)),
          ),
        );
      }
      if (paths.length !== 1) {
        fail("Insert one figure at a time to give each a caption.");
        return;
      }
      call<string[]>("asset.importPaths", { paths })
        .then((p) => importedFigure(p[0]))
        .catch(fail);
    }, true);
    return () => window.runtime?.OnFileDropOff?.();
  }, [active]);
  const openFile = async () => {
    try {
      if (window.go) {
        const p = await call<Project>("project.dialog");
        if (p) accept(p);
      } else openModal("open");
    } catch (e) {
      fail(e);
    }
  };
  const newDoc = async () => {
    try {
      const p = await call<Project>("document.new");
      if (p) accept(p);
    } catch (e) {
      fail(e);
    }
  };
  const openHelp = async () => {
    try {
      const p = await call<Project>("window.help");
      if (p) accept(p);
    } catch (error) {
      fail(error);
    }
  };
  const saveDocument = async () => {
    if (!current.current) return;
    if (!window.go && current.current?.unsaved) {
      setField("");
      openModal("save");
      return;
    }
    try {
      accept(await call<Project>("document.save"));
    } catch (error) {
      fail(error);
    }
  };
  const exportPDF = async () => {
    try {
      await call(
        "preview.exportPDF",
        window.go ? {} : { path: project?.root + "/manuscript.pdf" },
      );
    } catch (e) {
      fail(e);
    }
  };
  const conflict =
    project && Object.values(project.files).find((f) => f.conflict);
  const navigate = useCallback(
    (item: OutlineItem) => {
      const file = current.current?.files[item.path];
      if (!file) return;
      setNavigation((n) => n + 1);
      setSelection({
        path: item.path,
        start: item.start,
        end: item.start,
        revision: file.revision,
      });
      if (item.kind === "file") {
        setActive(item.path);
        setContinuous(false);
      } else if (!continuous) setActive(item.path);
      setMode("write");
      const v = editor.current;
      if (
        v &&
        (continuous || active === item.path) &&
        item.kind === "heading"
      ) {
        const pos = editorPosition(v.state.doc, item.path, item.start);
        v.dispatch(
          v.state.tr
            .setSelection(TextSelection.near(v.state.doc.resolve(pos)))
            .scrollIntoView(),
        );
        v.focus();
      }
    },
    [continuous, active],
  );
  const reorder = useCallback(
    async (
      source: OutlineItem,
      target: OutlineItem,
      after: boolean,
      projectId: string,
    ) => {
      const p = current.current;
      if (!p || p.id !== projectId)
        throw Error("The project changed during the drag.");
      const edits = reorderOutline(p, source, target, after);
      if (!edits.length) return;
      const saved = await apply(p, edits);
      accept(saved);
      const moved = source.move!;
      const insertion = edits[1];
      const offset =
        moved.kind === "include"
          ? source.start
          : insertion.start -
            (insertion.start > moved.start ? moved.end - moved.start : 0) +
            (insertion.text.startsWith("\n\n") ? 2 : 0);
      select({
        path: source.path,
        start: offset,
        end: offset,
        revision: saved.files[source.path].revision,
      });
      if (!continuous) setActive(source.path);
      setNavigation((n) => n + 1);
    },
    [continuous, accept, select],
  );
  const command = (action: () => void) => () => {
    setModal(null);
    action();
  };
  const commandMatches = (c: { label: string; keywords?: string }) =>
    (project ||
      [
        "Settings",
        "Open document",
        "New document",
        "Tutorial",
        "Dark theme",
        "Light theme",
        "Fullscreen",
      ].includes(c.label)) &&
    `${c.label} ${c.keywords || ""}`
      .toLowerCase()
      .includes(query.toLowerCase());
  const commands = [
    {
      label: "Settings",
      hint: "⌘ ,",
      icon: Settings2,
      run: () => openModal("settings"),
    },
    {
      label: "Statistics & info",
      icon: ChartNoAxesColumn,
      run: () => openModal("statistics"),
    },
    {
      label: "Open document",
      hint: "⌘ O",
      icon: FolderOpen,
      run: command(openFile),
    },
    {
      label: "Save",
      hint: "⌘ S",
      icon: Check,
      run: command(saveDocument),
    },
    {
      label: sidebar ? "Unpin table of contents" : "Pin table of contents",
      hint: "⌘ ⇧ L",
      keywords: "sidebar outline toc show hide pin unpin",
      icon: PanelLeft,
      run: command(() => {
        setSidebar(!sidebar);
      }),
    },
    {
      label: focus ? "Turn off paragraph focus" : "Paragraph focus",
      icon: Focus,
      run: command(() => setFocus(!focus)),
    },
    {
      label: typewriter
        ? "Turn off typewriter scrolling"
        : "Typewriter scrolling",
      icon: PenLine,
      run: command(() => setTypewriter(!typewriter)),
    },
    {
      label: "Write mode",
      hint: "⌘ 1",
      icon: PenLine,
      run: command(() => switchMode("write")),
    },
    {
      label: "Source mode",
      hint: "⌘ 2",
      icon: Code2,
      run: command(() => switchMode("source")),
    },
    {
      label: "Preview mode",
      hint: "⌘ 3",
      icon: BookOpen,
      run: command(() => switchMode("preview")),
    },
    {
      label: continuous ? "Show only current chapter" : "Show all chapters",
      keywords: "whole manuscript continuous document",
      icon: BookOpen,
      run: command(() => {
        if (continuous && selection) setActive(selection.path);
        setContinuous(!continuous);
        setMode("write");
      }),
    },
    {
      label: "Find in document",
      hint: "⌘ F",
      icon: Search,
      run: () => openModal("search"),
    },
    {
      label: "New document",
      hint: "⌘ N",
      icon: FileText,
      run: command(newDoc),
    },
    {
      label: "Tutorial",
      keywords: "help guide tutorial demo getting started",
      icon: BookOpen,
      run: command(openHelp),
    },
    {
      label: "Export PDF",
      icon: Download,
      run: command(() => {
        exportPDF();
      }),
    },
    {
      label: theme === "light" ? "Dark theme" : "Light theme",
      icon: theme === "light" ? Moon : Sun,
      run: command(() => {
        setAppearance({ ...appearance, background: null, textColor: null });
        setTheme(theme === "light" ? "dark" : "light");
      }),
    },
    {
      label: "Fullscreen",
      icon: Maximize,
      run: command(() => {
        call("window.fullscreen").catch(fail);
      }),
    },
    {
      label: "Refresh preview",
      icon: RefreshCw,
      run: command(() => {
        lastCompiled.current = -1;
        compile();
      }),
    },
    { label: "Bibliography style", icon: Quote, run: () => openModal("style") },
    {
      label: "Refresh Zotero references",
      icon: RefreshCw,
      run: command(() => {
        call<Project>("citation.refresh").then(accept).catch(fail);
      }),
    },
    {
      label: project?.agentEnabled
        ? "Disable agent access"
        : "Enable agent access",
      icon: Command,
      run: command(() => {
        call<Project>("project.agent", { enabled: !project?.agentEnabled })
          .then(accept)
          .catch(fail);
      }),
    },
    {
      label: "Undo latest agent edit",
      icon: Undo2,
      run: command(() => {
        call<Project>("document.undo", { origin: "agent" })
          .then(accept)
          .catch(fail);
      }),
    },
  ];
  const atomEdit = (n: PMNode) => {
    setAtom(n);
    setAtomRevision(project?.files[n.attrs.path]?.revision || 0);
    const image = n.attrs.raw.match(
      /^#figure\(image\("([^"]+)"[\s\S]*caption:\s*\[([^\]]*)\]\)$/,
    );
    if (image) {
      setField(image[1]);
      setExtra(image[2]);
      setImageWidth(n.attrs.raw.match(/width:\s*(\d+)%/)?.[1] || "85");
      setImageAlt(n.attrs.raw.match(/alt:\s*"([^"]*)"/)?.[1] || "");
      setPdfPage(n.attrs.raw.match(/page:\s*(\d+)/)?.[1] || "1");
      setModal("image");
    } else {
      setField(n.attrs.raw);
      setModal("source");
    }
  };
  return (
    <div className={"app " + (window.go ? "native" : "")} data-file-drop-target>
      <div className="window-dragbar">
        <span className="window-title">
          {displayedFile?.split("/").pop() || "blank_"}
        </span>
      </div>
      {error && (
        <div className="error-banner" role="alert">
          <span>{error}</span>
          <button onClick={() => setError("")} aria-label="Dismiss error">
            <X size={16} />
          </button>
        </div>
      )}
      {!project ? (
        <Home
          onNew={newDoc}
          onOpen={openFile}
          onHelp={openHelp}
          onSettings={() => openModal("settings")}
          onChoose={async (path) => {
            const p = await call<Project>("window.open", { path });
            if (p) accept(p);
          }}
          onError={fail}
        />
      ) : (
        <div className="workspace">
          <ContentsSidebar pinned={sidebar} disabled={!!modal} mode={mode}>
            <Outline
              project={project}
              active={selection?.path || active}
              activeOffset={selection?.start || 0}
              onNavigate={navigate}
              onReorder={reorder}
              onError={fail}
            />
          </ContentsSidebar>
          <main className="editor-shell">
            {conflict && (
              <div className="conflict-banner">
                <strong>Two versions of {conflict.path}</strong>
                <p>
                  Your writing is preserved. Review the disk change before
                  saving this file.
                </p>
                <div>
                  <button
                    onClick={() => {
                      setAtom(
                        writerSchema.nodes.raw_block.create({
                          path: conflict.path,
                          start: 0,
                          end: byteLength(conflict.text),
                          raw: conflict.text,
                        }),
                      );
                      setField(conflict.text);
                      setModal("source");
                    }}
                  >
                    Review local version
                  </button>
                  <button
                    onClick={() =>
                      call<Project>("document.resolve", {
                        path: conflict.path,
                        text: conflict.text,
                      })
                        .then(accept)
                        .catch(fail)
                    }
                  >
                    Keep my version
                  </button>
                  <button
                    onClick={() =>
                      call<Project>("document.resolve", {
                        path: conflict.path,
                        text: conflict.conflict!.disk,
                      })
                        .then(accept)
                        .catch(fail)
                    }
                  >
                    Use disk version
                  </button>
                </div>
                <details>
                  <summary>Compare disk text</summary>
                  <pre>{conflict.conflict!.disk || "(file deleted)"}</pre>
                </details>
              </div>
            )}
            {
              <div
                className="writing-scroll"
                style={{ display: mode === "write" ? "block" : "none" }}
                ref={scroller}
              >
                <div className="writing-column">
                  <RichEditor
                    positionReader={writePosition}
                    visible={mode === "write"}
                    navigation={navigation}
                    selection={selection}
                    key={project.id}
                    project={project}
                    active={active}
                    continuous={continuous}
                    focus={focus}
                    typewriter={typewriter}
                    onError={fail}
                    onChange={accept}
                    onSelection={select}
                    onAtom={atomEdit}
                    onView={(v) => (editor.current = v)}
                    onCite={() => openModal("citation")}
                    onInsert={openModal}
                    onMedia={importFiles}
                  />
                </div>
              </div>
            }
            {
              <SourceEditor
                positionReader={sourcePosition}
                visible={mode === "source"}
                selection={selection}
                project={project}
                path={active}
                onChange={accept}
                onError={fail}
                onSelection={select}
              />
            }
            {mode === "preview" && (
              <Suspense
                fallback={
                  <div className="editor-loading">Opening preview…</div>
                }
              >
                <PdfPreview
                  preview={preview}
                  busy={busy}
                  selection={selection}
                  project={project}
                  positionReader={previewPosition}
                />
              </Suspense>
            )}
            {mode === "preview" &&
              preview &&
              preview.diagnostics?.length > 0 && (
                <details className="diagnostics">
                  <summary>
                    {preview.diagnostics.length} typesetting issue
                    {preview.diagnostics.length > 1 ? "s" : ""} · last
                    successful preview retained
                  </summary>
                  {preview.diagnostics.map((d, i) => (
                    <button
                      key={i}
                      onClick={() => {
                        if (d.path && project.files[d.path]) setActive(d.path);
                        setMode("source");
                      }}
                    >
                      <Code2 size={14} />
                      <span>
                        {d.path}: {d.message}
                      </span>
                    </button>
                  ))}
                </details>
              )}
          </main>
        </div>
      )}
      {mode === "write" &&
        selection &&
        selection.end > selection.start &&
        editor.current &&
        !modal && (
          <div className="format-bar">
            <button
              title="Bold"
              onMouseDown={(e) => {
                e.preventDefault();
                const v = editor.current!;
                toggleMark(writerSchema.marks.strong)(v.state, v.dispatch);
              }}
            >
              <strong>B</strong>
            </button>
            <button
              title="Italic"
              onMouseDown={(e) => {
                e.preventDefault();
                const v = editor.current!;
                toggleMark(writerSchema.marks.em)(v.state, v.dispatch);
              }}
            >
              <em>I</em>
            </button>
            <button title="Link" onClick={() => openModal("link")}>
              <Link size={15} />
            </button>
            <button title="Citation" onClick={() => openModal("citation")}>
              <Quote size={16} />
            </button>
          </div>
        )}
      {modal && (
        <div
          className="modal-backdrop"
          onMouseDown={(e) => {
            if (e.target === e.currentTarget) setModal(null);
          }}
        >
          <div
            className={
              "modal " + (modal === "citation" ? "citation-modal" : "")
            }
            onKeyDown={(e) => {
              if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                const buttons = Array.from(
                  e.currentTarget.querySelectorAll<HTMLButtonElement>(
                    ".command-list button,.reference-results button",
                  ),
                );
                if (buttons.length) {
                  e.preventDefault();
                  const index = buttons.indexOf(
                    document.activeElement as HTMLButtonElement,
                  );
                  buttons[
                    (index +
                      (e.key === "ArrowDown" ? 1 : buttons.length - 1) +
                      buttons.length) %
                      buttons.length
                  ].focus();
                }
              }
              if (
                (e.metaKey || e.ctrlKey) &&
                e.key === "Enter" &&
                modal === "citation"
              ) {
                e.preventDefault();
                submit();
              }
            }}
            role="dialog"
            tabIndex={-1}
            aria-modal="true"
            aria-label={modal}
          >
            <div className="modal-heading">
              <h2>
                {
                  (
                    {
                      commands: "Commands",
                      statistics: "Statistics & info",
                      settings: "Settings",
                      citation: "Find a reference",
                      open: "Open document",
                      new: "New document",
                      save: "Save document",
                      equation: "Insert an equation",
                      footnote: "Add a footnote",
                      link: "Add a link",
                      image: "Image and caption",
                      table: "Insert a table",
                      source: "Edit Typst",
                      search: "Find in document",
                      style: "Bibliography style",
                      label: "Add a label",
                      reference: "Insert a cross-reference",
                    } as Record<string, string>
                  )[modal]
                }
              </h2>
              <button className="icon-button" onClick={() => setModal(null)}>
                <X size={18} />
              </button>
            </div>
            {modal === "commands" ? (
              <>
                <div className="search-field">
                  <Search size={18} />
                  <input
                    autoComplete="off"
                    autoFocus
                    placeholder="Search commands…"
                    value={query}
                    onChange={(e) => setQuery(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") {
                        const match = commands.find(commandMatches);
                        if (match) {
                          e.preventDefault();
                          match.run();
                        }
                      }
                    }}
                  />
                  <kbd>ESC</kbd>
                </div>
                <div className="command-list">
                  {commands.filter(commandMatches).map((c) => (
                    <button key={c.label} onClick={c.run}>
                      <c.icon size={17} />
                      <span>{c.label}</span>
                      <kbd>{c.hint || ""}</kbd>
                    </button>
                  ))}
                </div>
              </>
            ) : modal === "settings" ? (
              <Settings
                value={appearance}
                onChange={setAppearance}
                theme={theme}
              />
            ) : modal === "statistics" ? (
              project ? (
                <Statistics
                  project={project}
                  path={selection?.path || active || project.entry}
                  preview={preview}
                />
              ) : (
                <p>Open document to see its information.</p>
              )
            ) : modal === "citation" ? (
              <>
                <p className="modal-subtitle">
                  Your Zotero library, right where you're writing.
                </p>
                <div className="search-field">
                  <Search size={18} />
                  <input
                    autoComplete="off"
                    autoFocus
                    placeholder="Search by title, author, or year"
                    value={query}
                    onChange={(e) => setQuery(e.target.value)}
                  />
                </div>
                <select
                  value={library}
                  onChange={(e) => setLibrary(e.target.value)}
                >
                  <option value="personal">Personal library</option>
                  {groups.map((g) => (
                    <option key={g.id} value={"groups/" + g.id}>
                      {g.data?.name || g.name || "Group " + g.id}
                    </option>
                  ))}
                </select>
                {citationError && <p role="alert">{citationError}</p>}
                <div className="reference-results">
                  {finding && <p className="muted">Searching Zotero…</p>}
                  {refs.map((r) => (
                    <button
                      className={
                        chosen.some((c) => c.citeKey === r.citeKey)
                          ? "chosen"
                          : ""
                      }
                      key={r.citeKey}
                      onClick={() =>
                        setChosen((old) =>
                          old.some((c) => c.citeKey === r.citeKey)
                            ? old.filter((c) => c.citeKey !== r.citeKey)
                            : [...old, r],
                        )
                      }
                    >
                      <span className="reference-check">
                        {chosen.some((c) => c.citeKey === r.citeKey) ? (
                          <Check size={14} />
                        ) : (
                          <BookMarked size={15} />
                        )}
                      </span>
                      <span>
                        <strong>{r.title}</strong>
                        <small>
                          {r.author} <span>·</span> {r.year}
                        </small>
                      </span>
                    </button>
                  ))}
                  {!finding && !citationError && !refs.length && (
                    <p className="muted">
                      No references found. Try another search.
                    </p>
                  )}
                </div>
                <div className="citation-options">
                  <label>
                    Page / locator
                    <input
                      autoComplete="off"
                      placeholder="e.g. pp. 24–26"
                      value={field}
                      onChange={(e) => setField(e.target.value)}
                    />
                  </label>
                  <label>
                    Citation form
                    <select
                      value={citeForm}
                      onChange={(e) => setCiteForm(e.target.value)}
                    >
                      <option value="">Parenthetical</option>
                      <option value="prose">Narrative</option>
                      <option value="author">Author only</option>
                      <option value="year">Year only</option>
                    </select>
                  </label>
                </div>
                <div className="modal-actions">
                  <span>{chosen.length} selected</span>
                  <button
                    className="primary"
                    disabled={!chosen.length}
                    onClick={submit}
                  >
                    Insert citation
                  </button>
                </div>
              </>
            ) : modal === "search" ? (
              <>
                <div className="search-field">
                  <Search size={18} />
                  <input
                    autoComplete="off"
                    autoFocus
                    value={query}
                    onChange={(e) => setQuery(e.target.value)}
                    placeholder="Find words or phrases…"
                  />
                </div>
                <div className="search-results">
                  {query &&
                    project &&
                    Object.values(project.files)
                      .filter((f) => f.path.endsWith(".typ"))
                      .flatMap((f) =>
                        f.text
                          .split("\n")
                          .map((line, i) => ({ path: f.path, line, i }))
                          .filter((l) =>
                            l.line.toLowerCase().includes(query.toLowerCase()),
                          ),
                      )
                      .slice(0, 80)
                      .map((r, i) => (
                        <button
                          key={i}
                          onClick={() => {
                            setActive(r.path);
                            setContinuous(false);
                            setMode("source");
                            setModal(null);
                          }}
                        >
                          <small>
                            {r.path}:{r.i + 1}
                          </small>
                          <span>{r.line}</span>
                        </button>
                      ))}
                </div>
              </>
            ) : (
              <form
                autoComplete="off"
                onSubmit={(e) => {
                  e.preventDefault();
                  submit();
                }}
              >
                {modal === "source" ||
                modal === "equation" ||
                modal === "footnote" ? (
                  <textarea
                    autoComplete="off"
                    autoFocus
                    className={modal === "footnote" ? "" : "code-input"}
                    rows={modal === "source" ? 12 : 5}
                    value={field}
                    onChange={(e) => setField(e.target.value)}
                    placeholder={
                      modal === "equation" ? "E = m c^2" : "Write here…"
                    }
                  />
                ) : (
                  <label>
                    {modal === "open"
                      ? "Project path"
                      : modal === "save"
                        ? "Save as (.typ file path)"
                        : modal === "link"
                          ? "URL"
                          : modal === "table"
                            ? "Rows"
                            : modal === "style"
                              ? "Style name or local CSL path"
                              : modal === "label" || modal === "reference"
                                ? "Label name"
                                : "Project-relative image path"}
                    <input
                      autoComplete="off"
                      autoFocus
                      value={field}
                      onChange={(e) => setField(e.target.value)}
                      placeholder={
                        modal === "style"
                          ? "apa"
                          : modal === "table"
                            ? "3"
                            : modal === "image"
                              ? "assets/figure.png"
                              : modal === "link"
                                ? "https://…"
                                : "/Users/…/My thesis"
                      }
                    />
                  </label>
                )}
                {modal === "image" &&
                  (window.go ? (
                    <button
                      type="button"
                      onClick={() =>
                        call<string>("asset.import")
                          .then((p) => importedFigure(p, true))
                          .catch(fail)
                      }
                    >
                      Choose image or PDF…
                    </button>
                  ) : (
                    <label>
                      Choose image or PDF
                      <input
                        autoComplete="off"
                        type="file"
                        accept=".png,.jpg,.jpeg,.svg,.webp,.gif,.pdf"
                        onChange={(e) =>
                          importFiles(Array.from(e.target.files || []))
                        }
                      />
                    </label>
                  ))}
                {(modal === "link" ||
                  modal === "image" ||
                  modal === "table") && (
                  <label>
                    {modal === "link"
                      ? "Link text"
                      : modal === "table"
                        ? "Columns"
                        : "Caption"}
                    <input
                      autoComplete="off"
                      value={extra}
                      onChange={(e) => setExtra(e.target.value)}
                    />
                  </label>
                )}
                {modal === "image" && (
                  <>
                    <div className="citation-options">
                      <label>
                        Width (%)
                        <input
                          autoComplete="off"
                          type="number"
                          min="1"
                          max="100"
                          value={imageWidth}
                          onChange={(e) => setImageWidth(e.target.value)}
                        />
                      </label>
                      {/\.pdf$/i.test(field) && (
                        <label>
                          PDF page
                          <input
                            autoComplete="off"
                            type="number"
                            min="1"
                            value={pdfPage}
                            onChange={(e) => setPdfPage(e.target.value)}
                          />
                        </label>
                      )}
                    </div>
                    <label>
                      Alternative text
                      <input
                        autoComplete="off"
                        value={imageAlt}
                        onChange={(e) => setImageAlt(e.target.value)}
                        placeholder="Describe the figure for a reader who cannot see it"
                      />
                    </label>
                    <p className="muted">
                      PNG, JPEG, SVG, GIF, WebP, or PDF · up to 32 MB. Paste or
                      drop a file into the writing view.
                    </p>
                  </>
                )}
                {modal === "equation" && (
                  <p className="muted">
                    Use Typst math syntax. The exact equation appears in
                    Preview.
                  </p>
                )}
                {modal === "source" && (
                  <p className="muted">
                    This source region is preserved exactly in your document.
                  </p>
                )}
                <div className="modal-actions">
                  <button type="button" onClick={() => setModal(null)}>
                    Cancel
                  </button>
                  <button className="primary" type="submit">
                    {modal === "open"
                      ? "Open"
                      : modal === "save"
                        ? "Save"
                        : modal === "source"
                          ? "Apply changes"
                          : "Insert"}
                  </button>
                </div>
              </form>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
