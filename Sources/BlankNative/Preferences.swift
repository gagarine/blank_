import AppKit
import SwiftUI

enum EditorPreferences {
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
