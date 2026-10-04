import Foundation
import BlankCore

@MainActor enum FileAcceptance {
    static func run() {
        let fm = FileManager.default, folder = fm.temporaryDirectory.appendingPathComponent("blank-files-"+UUID().uuidString)
        var sessions: [DocumentSession] = []
        defer { sessions.forEach { $0.saveWork?.cancel(); $0.watchers.forEach { $0.cancel() }; $0.recoveryQueue.sync {} }; try? fm.removeItem(at:folder) }
        func check(_ value: Bool,_ label: String) { precondition(value,label); print("PASS: "+label) }
        do {
            let root = folder.appendingPathComponent("original"), copy = folder.appendingPathComponent("copy")
            try fm.createDirectory(at:root.appendingPathComponent("chapters"),withIntermediateDirectories:true); try fm.createDirectory(at:copy,withIntermediateDirectories:true)
            let main = root.appendingPathComponent("main.typ"), child = root.appendingPathComponent("chapters/one.typ")
            try "#include \"chapters/one.typ\"\n\nOriginal".write(to:main,atomically:true,encoding:.utf8)
            try "= Chapter\n\nHello".write(to:child,atomically:true,encoding:.utf8)
            let session = DocumentSession(); sessions.append(session); try session.open(main)
            check(session.includes.count == 2,"Multi-file opening follows literal includes")
            session.buffer.editSource(NSRange(location:session.buffer.source.utf16.count,length:0),text:" café"); session.dirty = true
            try session.saveToDisk()
            check(try String(contentsOf:main,encoding:.utf8) == session.buffer.source,"Autosave retains exact UTF-8 source")
            session.buffer.editSource(NSRange(location:session.buffer.source.utf16.count,length:0),text:" LOCAL")
            try "External".write(to:main,atomically:true,encoding:.utf8); session.checkDisk("main.typ")
            check(session.conflictDisk["main.typ"] == "External" && session.buffer.source.hasSuffix("LOCAL"),"External conflicts retain local writing")
            do { try session.saveToDisk(); preconditionFailure("Conflict overwritten") } catch {}
            check(try String(contentsOf:main,encoding:.utf8) == "External","Conflicting disk file is not overwritten")
            session.bases["main.typ"] = "External"; session.conflictDisk.removeAll(); try session.saveToDisk()
            try session.renameEntry("Research")
            check(session.entry == "Research.typ" && fm.fileExists(atPath:root.appendingPathComponent("Research.typ").path) && !fm.fileExists(atPath:main.path),"Rename keeps dependencies and source history")
            session.buffer.undo(); check(!session.buffer.source.hasSuffix("LOCAL"),"Rename retains undo history")
            session.buffer.redo(); try session.saveToDisk()
            try session.saveCopy(to:copy.appendingPathComponent("Copy.typ"))
            let reopened = DocumentSession(); sessions.append(reopened); try reopened.open(copy)
            check(reopened.entry == "Copy.typ" && reopened.includes.count == 2,"Save As copies chapters and updates project entry")
            try fm.removeItem(at:copy.appendingPathComponent("chapters/one.typ")); reopened.checkDisk("chapters/one.typ")
            check(reopened.deletedFiles.contains("chapters/one.typ"),"External deletion requests an explicit conflict decision")
            do { try reopened.saveToDisk(); preconditionFailure("Deleted file recreated silently") } catch {}
            reopened.persistRecovery(); reopened.recoveryQueue.sync {}
            let payload = try JSONDecoder().decode(Recovery.self,from:Data(contentsOf:reopened.recoveryURL))
            check(payload.files["chapters/one.typ"] == "= Chapter\n\nHello","Recovery retains externally deleted writing")
            try fm.createDirectory(at:folder.appendingPathComponent("collision/chapters"),withIntermediateDirectories:true)
            let collision = folder.appendingPathComponent("collision")
            try "Unrelated".write(to:collision.appendingPathComponent("chapters/one.typ"),atomically:true,encoding:.utf8)
            do { try session.saveCopy(to:collision.appendingPathComponent("Copy.typ")); preconditionFailure("Dependency collision overwritten") } catch {}
            check(!fm.fileExists(atPath:collision.appendingPathComponent("Copy.typ").path) && !fm.fileExists(atPath:collision.appendingPathComponent("writer.json").path),"Save As preflights all dependency collisions")
            check(session.projectAssetPath("../assets/a.png",file:"chapters/one.typ") == "assets/a.png","Nested chapter assets map to project paths")
        } catch { fatalError("File acceptance: \(error)") }
    }
}
