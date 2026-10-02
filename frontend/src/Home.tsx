import { useEffect, useState } from "react";
import { FilePlus2, FolderOpen, X } from "lucide-react";
import { call } from "./api";

type RecentDocument = {
  path: string;
  name: string;
  folder: string;
  available: boolean;
};

export function Home({
  onNew,
  onOpen,
  onHelp,
  onSettings,
  onChoose,
  onError,
}: {
  onNew: () => void;
  onOpen: () => void;
  onHelp: () => void;
  onSettings: () => void;
  onChoose: (path: string) => Promise<void>;
  onError: (error: unknown) => void;
}) {
  const [recent, setRecent] = useState<RecentDocument[]>([]);
  const [opening, setOpening] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    const refresh = () =>
      call<RecentDocument[]>("recent.list")
        .then((items) => {
          if (alive) setRecent(items);
        })
        .catch((error) => {
          if (alive) onError(error);
        });
    void refresh();
    window.addEventListener("focus", refresh);
    return () => {
      alive = false;
      window.removeEventListener("focus", refresh);
    };
  }, [onError]);
  const choose = async (path: string) => {
    if (opening) return;
    setOpening(path);
    try {
      await onChoose(path);
    } catch (error) {
      onError(error);
    } finally {
      setOpening(null);
    }
  };
  const forget = async (path: string) => {
    try {
      await call("recent.remove", { path });
      setRecent((items) => items.filter((item) => item.path !== path));
    } catch (error) {
      onError(error);
    }
  };
  return (
    <main className="home" aria-label="Home">
      <div className="home-content">
        <h1>blank_</h1>
        <div className="home-actions">
          <button onClick={onNew}>
            <FilePlus2 size={18} />
            <span>New Document</span>
            <kbd>⌘N</kbd>
          </button>
          <button onClick={onOpen}>
            <FolderOpen size={18} />
            <span>Open Document…</span>
            <kbd>⌘O</kbd>
          </button>
        </div>
        {recent.length > 0 ? (
          <section className="home-recents" aria-labelledby="recent-heading">
            <h2 id="recent-heading">Recent documents</h2>
            <ul>
              {recent.map((item) => (
                <li key={item.path}>
                  <button
                    className="recent-open"
                    disabled={!item.available || !!opening}
                    onClick={() => void choose(item.path)}
                  >
                    <span className="recent-name">
                      {item.name}
                      {opening === item.path ? " · Opening…" : ""}
                    </span>
                    <span className="recent-folder">
                      {item.folder}
                      {!item.available ? " · Unavailable" : ""}
                    </span>
                  </button>
                  <button
                    className="recent-forget"
                    aria-label={`Remove ${item.name} from recent documents`}
                    onClick={() => void forget(item.path)}
                  >
                    <X size={14} />
                  </button>
                </li>
              ))}
            </ul>
          </section>
        ) : (
          <p className="home-empty">Your recent documents will appear here.</p>
        )}
        <footer className="home-footer">
          <button onClick={onHelp}>Tutorial</button>
          <button onClick={onSettings}>Settings</button>
          <span>⌘K for commands</span>
        </footer>
      </div>
    </main>
  );
}
