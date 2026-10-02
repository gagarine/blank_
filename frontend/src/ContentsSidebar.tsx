import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";

export function ContentsSidebar({
  pinned,
  disabled,
  mode,
  children,
}: {
  pinned: boolean;
  disabled: boolean;
  mode: "write" | "source" | "preview";
  children: ReactNode;
}) {
  const panel = useRef<HTMLElement>(null);
  const latched = useRef(false);
  const [revealed, setRevealed] = useState(false);
  const [zoneWidth, setZoneWidth] = useState(0);
  const bounds = useRef({ left: 0, top: 0, bottom: 0, width: 0 });

  useLayoutEffect(() => {
    const workspace = panel.current?.parentElement;
    const column = workspace?.querySelector(".writing-column");
    if (!workspace) return;
    const measure = () => {
      const area = workspace.getBoundingClientRect();
      const text = column?.getBoundingClientRect();
      // Reserve the full 32px paragraph handle and a 16px gap before revealing.
      const width =
        mode === "write" && text?.width
          ? Math.max(0, text.left - area.left - 32 - 16)
          : 24;
      bounds.current = {
        left: area.left,
        top: area.top,
        bottom: area.bottom,
        width,
      };
      setZoneWidth(width);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(workspace);
    if (column) observer.observe(column);
    if (panel.current) observer.observe(panel.current);
    window.addEventListener("resize", measure);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", measure);
    };
  }, [mode, pinned]);

  const hide = useCallback(() => {
    latched.current = false;
    setRevealed(false);
  }, []);
  useEffect(() => {
    if (disabled) hide();
  }, [disabled, hide]);
  const track = useCallback(
    (event: { clientX: number; clientY: number; buttons: number }) => {
      if (pinned || disabled || event.buttons) return;
      const area = bounds.current;
      const x = event.clientX - area.left;
      const insideHeight =
        event.clientY >= area.top && event.clientY <= area.bottom;
      const panelWidth = panel.current?.getBoundingClientRect().width || 160;
      if (latched.current && insideHeight && x >= 0 && x < panelWidth) return;
      latched.current = false;
      if (!insideHeight || x < 0 || x >= area.width) {
        setRevealed(false);
        return;
      }
      // Once revealed, keep the panel available while the pointer is over it.
      latched.current = true;
      setRevealed(true);
    },
    [pinned, disabled],
  );
  useEffect(() => {
    document.addEventListener("mousemove", track);
    window.addEventListener("blur", hide);
    return () => {
      document.removeEventListener("mousemove", track);
      window.removeEventListener("blur", hide);
    };
  }, [track, hide]);
  const shown = pinned || (!disabled && revealed);
  return (
    <>
      {!pinned && !disabled && (
        <div
          className="contents-reveal-edge"
          aria-hidden="true"
          style={{ width: zoneWidth }}
          onMouseEnter={track}
          onMouseLeave={track}
        />
      )}
      <aside
        ref={panel}
        className={`sidebar ${pinned ? "" : "sidebar-peek "}${shown ? "sidebar-revealing" : "sidebar-hidden"}`}
        inert={!shown}
        aria-hidden={!shown}
        onMouseEnter={track}
        onMouseLeave={track}
      >
        <div className="sidebar-scroll">{children}</div>
      </aside>
    </>
  );
}
