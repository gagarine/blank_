import AppKit
import CoreText
import SwiftUI

enum EditorPreferences {
    static var reopensUnsavedDocuments: Bool {
        get { UserDefaults.standard.object(forKey:"reopenUnsavedDocuments") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue,forKey:"reopenUnsavedDocuments") }
    }
    static var installedEditorFamilies: [String] {
        var families = Set(NSFontManager.shared.availableFontFamilies)
        // macOS can omit installed supplemental faces from the picker list.
        // Include the resolved default/saved face only when its font file exists.
        for name in [UserDefaults.standard.string(forKey:"editorFont"),UserDefaults.standard.string(forKey:"readingFont")].compactMap({ $0 }) {
            if let font = NSFont(name:name,size:18) ?? NSFontManager.shared.font(withFamily:name,traits:[],weight:5,size:18), let family = font.familyName {
                let ct = CTFontCreateWithName(font.fontName as CFString,18,nil)
                if let url = CTFontCopyAttribute(ct,kCTFontURLAttribute) as? URL, url.isFileURL, FileManager.default.fileExists(atPath:url.path) { families.insert(family) }
            }
        }
        return ["System"]+families.sorted()
    }
    static var preferredEditorFamily: String {
        let saved = UserDefaults.standard.string(forKey:"editorFont")
        let legacy = UserDefaults.standard.string(forKey:"readingFont")
        return installedEditorFamily(saved ?? (legacy == "Iowan Old Style" ? nil : legacy))
    }
    static func installedEditorFamily(_ preference: String?) -> String {
        let families = installedEditorFamilies
        func key(_ name: String) -> String { name.lowercased().filter { !$0.isWhitespace && $0 != "-" } }
        guard let preferred = preference, preferred != "System" else { return "System" }
        if let exact = families.first(where:{ key($0) == key(preferred) }) { return exact }
        let resolved = NSFont(name:preferred,size:18)?.familyName ?? NSFontManager.shared.font(withFamily:preferred,traits:[],weight:5,size:18)?.familyName
        if let resolved, families.contains(resolved) { return resolved }
        return "System"
    }

    static var usesSystemColors: Bool {
        if let preference = UserDefaults.standard.object(forKey:"systemColors") as? Bool { return preference }
        // Earlier builds persisted their default light/dark palette as custom RGB.
        // Retain actual custom choices, but migrate those defaults to native colors.
        let paper = UserDefaults.standard.array(forKey:"paper") as? [Double]
        let ink = UserDefaults.standard.array(forKey:"ink") as? [Double]
        func matches(_ values: [Double]?, _ gray: Double) -> Bool {
            guard let values else { return true }
            guard values.count == 3 else { return false }
            let converted = NSColor(calibratedWhite:gray,alpha:1).usingColorSpace(.deviceRGB)!.redComponent
            return values.allSatisfy { abs($0-gray) < 0.015 } || values.allSatisfy { abs($0-converted) < 0.015 }
        }
        return (matches(paper,1) && matches(ink,0.2)) || (matches(paper,0.11) && matches(ink,0.87))
    }
    static func color(_ key: String, fallback: NSColor) -> Color {
        guard let values = UserDefaults.standard.array(forKey:key) as? [Double], values.count == 3 else { return Color(nsColor:fallback) }
        return Color(red:values[0],green:values[1],blue:values[2])
    }
    static func store(_ color: Color,key: String) {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
        UserDefaults.standard.set([rgb.redComponent,rgb.greenComponent,rgb.blueComponent],forKey:key)
    }
}
