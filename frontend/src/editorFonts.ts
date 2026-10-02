export const fonts: Record<string, { label: string; css: string }> = {
  serif: {
    label: "Iowan Old Style",
    css: '"Iowan Old Style", Palatino, Georgia, serif',
  },
  georgia: { label: "Georgia", css: "Georgia, serif" },
  palatino: { label: "Palatino", css: "Palatino, serif" },
  sans: {
    label: "System sans serif",
    css: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
  },
  mono: {
    label: "System monospace",
    css: '"SFMono-Regular", Menlo, Consolas, monospace',
  },
};

// Keep the old preset IDs so existing appearance preferences still load.
export function validFont(value: unknown): string {
  return typeof value === "string" &&
    (Object.hasOwn(fonts, value) ||
      (value.startsWith("family:") &&
        value.slice(7).trim().length > 0 &&
        !/[\u0000-\u001f\u007f]/.test(value)))
    ? value
    : "serif";
}
export function editorFontCSS(value: string): string {
  const font = validFont(value);
  if (Object.hasOwn(fonts, font)) return fonts[font].css;
  // A family name is a single quoted CSS string, never a CSS font-stack input.
  const family = font.slice(7).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return `"${family}", serif`;
}
