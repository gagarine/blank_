import AppKit
import SwiftUI

enum EditorPreferences {
    static func color(_ key: String, fallback: NSColor) -> Color {
        guard let values = UserDefaults.standard.array(forKey:key) as? [Double], values.count == 3 else { return Color(nsColor:fallback) }
        return Color(red:values[0],green:values[1],blue:values[2])
    }
    static func store(_ color: Color,key: String) {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
        UserDefaults.standard.set([rgb.redComponent,rgb.greenComponent,rgb.blueComponent],forKey:key)
    }
}
