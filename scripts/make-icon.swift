// Rebuild the simple native icon: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("blank-icon-"+UUID().uuidString)
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:temporary) }
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size*scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        bitmap.size = NSSize(width:pixels,height:pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSGraphicsContext.current!.cgContext.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
        let tile = NSBezierPath(roundedRect:NSRect(x:72,y:72,width:880,height:880),xRadius:190,yRadius:190)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.16); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width:0,height:-12)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor(calibratedWhite:0.98,alpha:1).setFill(); tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite:0.86,alpha:1).setStroke(); tile.lineWidth = 3; tile.stroke()
        let ink = NSColor(calibratedWhite:0.12,alpha:1)
        let font = NSFont.systemFont(ofSize:540,weight:.semibold)
        ("b" as NSString).draw(at:NSPoint(x:258,y:202),withAttributes:[.font:font,.foregroundColor:ink])
        ink.setFill(); NSBezierPath(roundedRect:NSRect(x:616,y:260,width:142,height:42),xRadius:9,yRadius:9).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using:.png,properties:[:])!.write(to:iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/iconutil")
process.arguments = ["-c","icns",iconset.path,"-o",root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { throw NSError(domain:"blank.icon",code:Int(process.terminationStatus),userInfo:[NSLocalizedDescriptionKey:"iconutil failed"]) }
