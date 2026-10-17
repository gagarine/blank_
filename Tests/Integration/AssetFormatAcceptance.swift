import AppKit
import BlankCore
@testable import BlankNative

@MainActor enum AssetFormatAcceptance {
    static func run() {
        let fm = FileManager.default
        let root = AppController.temporaryDirectory.appendingPathComponent("asset-formats-"+UUID().uuidString)
        let recents = NSDocumentController.shared.recentDocumentURLs
        var sessions: [DocumentSession] = []
        func stop(_ session: DocumentSession) {
            session.saveWork?.cancel(); session.diskScanWork?.cancel()
            session.watchers.forEach { $0.cancel() }; session.recoveryQueue.sync {}
        }
        defer {
            sessions.forEach { stop($0); try? fm.removeItem(at:$0.containerDirectory) }
            try? fm.removeItem(at:root)
            NSDocumentController.shared.clearRecentDocuments(nil)
            recents.reversed().forEach { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
        }
        func check(_ value: Bool,_ label: String) { precondition(value,label); print("PASS: "+label) }
        func session() -> DocumentSession { let value = DocumentSession(); sessions.append(value); return value }
        func compile(_ value: DocumentSession) {
            value.compile(); let end = Date().addingTimeInterval(20)
            while value.compiling && Date() < end { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
            check(!value.compiling && value.pdf != nil && value.error == nil,"Converted project compiles with its own assets: \(value.error ?? "success")")
        }
        func destination(_ directory: URL,_ format: DocumentFormat) -> URL {
            directory.appendingPathComponent(format == .container ? "Paper.typz" : format == .document ? "Paper.typ" : "Project")
        }
        do {
            try fm.createDirectory(at:root,withIntermediateDirectories:true)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            memset(bitmap.bitmapData!,255,bitmap.bytesPerRow*bitmap.pixelsHigh)
            let image = bitmap.representation(using:.png,properties:[:])!
            let input = root.appendingPathComponent("café 日本.png"); try image.write(to:input)
            for from in DocumentFormat.allCases {
                for to in DocumentFormat.allCases {
                    let pair = root.appendingPathComponent("\(from.rawValue)-\(to.rawValue)")
                    let original = pair.appendingPathComponent("original"), copy = pair.appendingPathComponent("copy")
                    try fm.createDirectory(at:original,withIntermediateDirectories:true)
                    try fm.createDirectory(at:copy,withIntermediateDirectories:true)
                    let draft = session(), path = try draft.importImage(input)
                    check(path.hasPrefix("assets/"),"Imported images start in the shared assets directory")
                    let source = "// Keep café 日本 and the exact figure options\n#figure(image(\(typstStringLiteral(path))), caption: [Keep *this*])\n#align(center, image(\(typstStringLiteral("/"+path)), width: 25%))\n#include \"chapters/child.typ\"\n"
                    let child = "// Keep child-relative paths\n#image(\(typstStringLiteral("../"+path)))\n"
                    draft.buffer.loadExternal(source); draft.buffers["chapters/child.typ"] = DocumentBuffer(child)
                    let first = destination(original,from); try draft.saveFormatted(to:first,format:from)
                    let opened = session(); try opened.open(first)
                    // No dependency compilation here: nested literal discovery
                    // must copy disk assets even in a newly reopened .typ file.
                    let second = destination(copy,to); try opened.saveFormatted(to:second,format:to)
                    check(opened.buffer.source == source && opened.buffers["chapters/child.typ"]?.source == child,"\(from.label) → \(to.label) preserves source and hierarchy")
                    let snapshot = try opened.projectSnapshot()
                    check(snapshot[path] == image && snapshot["chapters/child.typ"] == Data(child.utf8) && snapshot.keys.allSatisfy { !$0.contains("-assets/") && !$0.contains("assets/assets/") },"Conversion adds no filename prefix or nested assets directory")
                    stop(draft); stop(opened); try fm.removeItem(at:original)
                    let reopened = session(); try reopened.open(second)
                    check(reopened.buffer.source == source,"Converted source reopens exactly after its original location is removed")
                    compile(reopened)
                    stop(reopened)
                }
            }

            let nested = session(), oldEntry = "chapters/main.typ", path = "assets/photo.png"
            nested.entry = oldEntry; nested.active = oldEntry
            let original = "// Keep this comment\n#figure(image(\"../assets/photo.png\" /* Keep option comment */, width: 50%), caption: [Caption café])\n#align(center, image(\"/assets/photo.png\"))\n\nBefore"
            nested.buffers = [oldEntry:DocumentBuffer(original)]; nested.assets[path] = image
            nested.buffer.editSource(NSRange(location:nested.buffer.source.utf16.count,length:0),text:" 日本👩🏽‍💻")
            let identity = nested.buffer, undo = nested.buffer.undoID
            let target = root.appendingPathComponent("Relocated.typ")
            try nested.saveFormatted(to:target,format:.document)
            let expected = original.replacingOccurrences(of:"../assets/photo.png",with:"assets/photo.png")
            check(nested.buffer === identity && nested.buffer.undoID == undo && nested.buffer.source == expected+" 日本👩🏽‍💻","Relocating a nested entry rebases wrapped image paths and preserves source history identity")
            check(nested.buffer.source.contains("image(\"/assets/photo.png\")"),"Project-root absolute paths remain exact")
            let source = nested.buffer.source, selection = nested.buffer.selection
            nested.undo(); nested.saveWork?.cancel()
            check(nested.buffer.source == expected,"Undo reverses Unicode typing without restoring obsolete image paths")
            nested.undo(true); nested.saveWork?.cancel()
            check(nested.buffer.source == source && nested.buffer.selection == selection,"Redo restores source and byte selection after path relocation")
            compile(nested)

            let unsafe = session(); unsafe.entry = oldEntry; unsafe.active = oldEntry
            unsafe.buffers = [oldEntry:DocumentBuffer("#let name = \"photo.png\"\n#figure(image(\"../assets/\" + name))")]
            unsafe.assets[path] = image
            let before = Set(try fm.contentsOfDirectory(atPath:root.path))
            do { try unsafe.saveFormatted(to:root.appendingPathComponent("Unsafe.typ"),format:.document); preconditionFailure("Nested computed image was relocated") } catch {}
            check(Set(try fm.contentsOfDirectory(atPath:root.path)) == before && unsafe.entry == oldEntry,"Nested computed image paths block unsafe relocation before any writes")

            let computed = session()
            let computedSource = "#let name = \"photo.png\"\n#figure(image(\"assets/\" + name))"
            computed.buffer.loadExternal(computedSource); computed.assets[path] = image
            try computed.saveFormatted(to:root.appendingPathComponent("Computed project"),format:.folder)
            check(computed.buffer.source == computedSource,"Folder conversion preserves computed image paths exactly")
            compile(computed)

            let collision = session()
            collision.buffers["TARGET.typ"] = DocumentBuffer("Dependency that must survive")
            let collisionRoot = root.appendingPathComponent("collision"); try fm.createDirectory(at:collisionRoot,withIntermediateDirectories:false)
            do { try collision.saveFormatted(to:collisionRoot.appendingPathComponent("target.typ"),format:.document); preconditionFailure("Entry overwrote a dependency") } catch {}
            check(try fm.contentsOfDirectory(atPath:collisionRoot.path).isEmpty,"Entry/dependency filename collisions fail before writing")
        } catch { fatalError("Asset format acceptance: \(error)") }
    }
}
