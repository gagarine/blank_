import { describe, expect, it } from "vitest";
import { editorFontCSS, validFont } from "./editorFonts";

describe("editor font preferences", () => {
  it("keeps existing presets and installed font choices across reloads", () => {
    expect(validFont("mono")).toBe("mono");
    const saved = JSON.parse(JSON.stringify({ font: "family:Helvetica Neue" }));
    expect(validFont(saved.font)).toBe("family:Helvetica Neue");
    expect(editorFontCSS(saved.font)).toBe('"Helvetica Neue", serif');
  });
  it("treats font names as one CSS string and rejects malformed preferences", () => {
    expect(editorFontCSS('family:Writer "Text", Other')).toBe('"Writer \\"Text\\", Other", serif');
    for (const value of [null, {}, "__proto__", "family:", "family:Bad\nFont"]) {
      expect(validFont(value)).toBe("serif");
    }
  });
});
