import { useEffect, useState } from "react";
import { call } from "./api";
import { fonts, validFont, editorFontCSS } from "./editorFonts";

export type Appearance = {
  background: string | null;
  textColor: string | null;
  font: string;
  size: number;
};
export const defaultAppearance: Appearance = {
  background: null,
  textColor: null,
  font: "serif",
  size: 18,
};
export function useAppearance() {
  const [appearance, setAppearance] = useState<Appearance>(() => {
    try {
      const saved = JSON.parse(
        localStorage.getItem("blank-appearance") || "null",
      );
      if (!saved) return defaultAppearance;
      return {
        background: /^#[a-f\d]{6}$/i.test(saved.background)
          ? saved.background
          : null,
        textColor: /^#[a-f\d]{6}$/i.test(saved.textColor)
          ? saved.textColor
          : null,
        font: validFont(saved.font),
        size: Number.isFinite(saved.size)
          ? Math.max(12, Math.min(32, saved.size))
          : 18,
      };
    } catch {
      return defaultAppearance;
    }
  });
  useEffect(() => {
    localStorage.setItem("blank-appearance", JSON.stringify(appearance));
    const root = document.documentElement.style;
    root.removeProperty("--bg");
    root.removeProperty("--ink");
    for (const [property, value] of [
      ["--writing-bg", appearance.background],
      ["--writing-ink", appearance.textColor],
    ]) {
      if (value) root.setProperty(property!, value);
      else root.removeProperty(property!);
    }
    root.setProperty("--editor-font", editorFontCSS(appearance.font));
    root.setProperty("--editor-font-size", appearance.size + "px");
  }, [appearance]);
  return [appearance, setAppearance] as const;
}
export function Settings({
  value,
  onChange,
  theme,
}: {
  value: Appearance;
  onChange: (value: Appearance) => void;
  theme: string;
}) {
  const [families, setFamilies] = useState<string[]>([]);
  const [fontError, setFontError] = useState(false);
  useEffect(() => {
    let cancelled = false;
    call<string[]>("settings.fonts")
      .then((available) => {
        if (!cancelled)
          setFamilies(
            [...new Set(available)].sort((a, b) => a.localeCompare(b)),
          );
      })
      .catch(() => {
        if (!cancelled) setFontError(true);
      });
    return () => {
      cancelled = true;
    };
  }, []);
  const selectedFamily = value.font.startsWith("family:")
    ? value.font.slice(7)
    : null;
  return (
    <div className="settings-form">
      <label>
        <span>Background color</span>
        <input
          type="color"
          aria-label="Background color"
          value={value.background || (theme === "dark" ? "#252c21" : "#ffffff")}
          onInput={(e) =>
            onChange({ ...value, background: e.currentTarget.value })
          }
        />
      </label>
      <label>
        <span>Text color</span>
        <input
          type="color"
          aria-label="Text color"
          value={value.textColor || (theme === "dark" ? "#cbd7c0" : "#343a37")}
          onInput={(e) =>
            onChange({ ...value, textColor: e.currentTarget.value })
          }
        />
      </label>
      <label>
        <span>Editor font</span>
        <select
          value={value.font}
          onChange={(e) =>
            onChange({ ...value, font: e.target.value as Appearance["font"] })
          }
        >
          <optgroup label="Quick choices">
            {Object.entries(fonts).map(([id, font]) => (
              <option key={id} value={id}>
                {font.label}
              </option>
            ))}
          </optgroup>
          {selectedFamily && !families.includes(selectedFamily) && (
            <option value={value.font}>{selectedFamily}</option>
          )}
          {families.length > 0 && (
            <optgroup label="Installed fonts">
              {families.map((family) => (
                <option key={family} value={"family:" + family}>
                  {family}
                </option>
              ))}
            </optgroup>
          )}
        </select>
      </label>
      {fontError && (
        <p className="statistics-note" role="status">
          Couldn’t load installed fonts. Close and reopen Settings to retry.
        </p>
      )}
      <label className="font-size-setting">
        <span>
          Font size <output>{value.size} px</output>
        </span>
        <input
          type="range"
          min="12"
          max="32"
          step="1"
          value={value.size}
          onChange={(e) => onChange({ ...value, size: Number(e.target.value) })}
        />
      </label>
      <p className="statistics-note">
        Applies to your writing view. Document typography and PDF output are
        controlled by Typst.
      </p>
      <button
        className="text-button"
        onClick={() => onChange(defaultAppearance)}
      >
        Restore defaults
      </button>
    </div>
  );
}
