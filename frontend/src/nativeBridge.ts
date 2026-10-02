// Use the runtime bundled with the pinned Go framework. The small compatibility
// facade keeps editor code independent of the native window implementation.
export async function installNativeBridge() {
  if (location.protocol !== "wails:") return;
  const runtimeURL = "/wails/runtime.js";
  const { Call, Events } = await import(/* @vite-ignore */ runtimeURL);
  window.go = {
    main: { App: { Call: (method, params) => Call.ByName("main.Desktop.Call", method, params) } },
  };
  let stopDrop: (() => void) | undefined;
  window.runtime = {
    EventsOn: (name, cb) => Events.On(name, (event: { data: unknown }) => cb(event.data)),
    OnFileDrop: (cb) => {
      stopDrop?.();
      stopDrop = Events.On("filesDropped", (event: { data: { x: number; y: number; paths: string[] } }) => {
        cb(event.data.x, event.data.y, event.data.paths);
      });
    },
    OnFileDropOff: () => { stopDrop?.(); stopDrop = undefined; },
  };
}
