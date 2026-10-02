// Wails' macOS bridge emits [""] when a drag has no file URLs. A block move
// must not become an attempted image import or change the drop selection.
export function externalFilePaths(paths: string[]): string[] {
  return paths.filter(
    (path) => path.startsWith("/") || /^[A-Za-z]:[\\/]/.test(path),
  );
}
