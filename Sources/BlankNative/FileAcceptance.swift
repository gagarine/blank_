import AppKit
import BlankCore

@MainActor enum FileAcceptance {
    static func run() {
        let fm = FileManager.default, folder = fm.temporaryDirectory.appendingPathComponent("blank-files-"+UUID().uuidString)
        let recentDocuments = NSDocumentController.shared.recentDocumentURLs
        var sessions: [DocumentSession] = []
        defer {
            sessions.forEach { $0.saveWork?.cancel(); $0.diskScanWork?.cancel(); $0.watchers.forEach { $0.cancel() }; $0.recoveryQueue.sync {} }
            try? fm.removeItem(at:folder)
            NSDocumentController.shared.clearRecentDocuments(nil)
            recentDocuments.reversed().forEach { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
        }
        func check(_ value: Bool,_ label: String) { precondition(value,label); print("PASS: "+label) }
        do {
            let root = folder.appendingPathComponent("original"), copy = folder.appendingPathComponent("copy")
            try fm.createDirectory(at:root.appendingPathComponent("chapters"),withIntermediateDirectories:true); try fm.createDirectory(at:copy,withIntermediateDirectories:true)
            let main = root.appendingPathComponent("main.typ"), child = root.appendingPathComponent("chapters/one.typ")
            try "#let helper() = [Imported]".write(to:root.appendingPathComponent("tools.typ"),atomically:true,encoding:.utf8)
            try "#import \"tools.typ\": *\n// #image(\"example-not-an-asset.png\")\n#include \"chapters/one.typ\"\n\nOriginal".write(to:main,atomically:true,encoding:.utf8)
            try "= Chapter\n\nHello".write(to:child,atomically:true,encoding:.utf8)
            let session = DocumentSession(); sessions.append(session); try session.open(main)
            check(session.includes.count == 2,"Multi-file opening follows literal includes")
            check(session.buffers["tools.typ"] != nil && !session.includes.contains("tools.typ"),"Local imports load as dependencies without expanding the manuscript")
            let two = root.appendingPathComponent("chapters/two.typ")
            try "= Second\n\nMore writing".write(to:two,atomically:true,encoding:.utf8)
            session.buffer.editSource(NSRange(location:session.buffer.source.utf16.count,length:0),text:"\n\n#include \"chapters/two.typ\"")
            session.changed()
            check(session.includes == ["main.typ","chapters/one.typ","chapters/two.typ"],"Editing includes loads new chapters in source order")
            let beforeMove = session.buffer.source
            session.switchFile("chapters/one.typ")
            check(session.moveChapter("chapters/two.typ",before:"chapters/one.typ") && session.includes == ["main.typ","chapters/two.typ","chapters/one.typ"],"Chapter movement reorders includes without changing the active chapter")
            session.undo(); check(session.buffers["main.typ"]?.source == beforeMove && session.active == "chapters/one.typ","Chapter Undo targets the parent file while preserving chapter focus")
            session.undo(true); check(session.includes[1] == "chapters/two.typ","Chapter Redo restores include order")
            session.switchFile("main.typ"); session.buffers["main.typ"]!.undo(); session.changed()
            session.buffers["main.typ"]!.undo(); session.changed()
            check(session.includes.count == 2 && session.buffers["chapters/two.typ"] != nil,"Removing an include hides the chapter and retains its source history")
            session.buffer.editSource(NSRange(location:session.buffer.source.utf16.count,length:0),text:"\n\n#include \"chapters/later.typ\""); session.changed()
            try session.saveToDisk()
            check(try String(contentsOf:root.appendingPathComponent("chapters/later.typ"),encoding:.utf8) == "","New chapter includes save an empty .typ file automatically")
            try "= Arrived later".write(to:root.appendingPathComponent("chapters/later.typ"),atomically:true,encoding:.utf8)
            let watchDeadline = Date().addingTimeInterval(2)
            while session.buffers["chapters/later.typ"]?.source != "= Arrived later" && Date() < watchDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
            check(session.buffers["chapters/later.typ"] != nil,"Edited includes create empty chapter files automatically")
            session.buffer.undo(); session.changed()
            session.buffer.editSource(NSRange(location:session.buffer.source.utf16.count,length:0),text:" café"); session.dirty = true
            try session.saveToDisk()
            check(try String(contentsOf:main,encoding:.utf8) == session.buffer.source,"Autosave retains exact UTF-8 source")
            session.buffer.editSource(NSRange(location:session.buffer.source.utf16.count,length:0),text:" LOCAL")
            let savedSource = session.bases["main.typ"]!, unreadable = Data([0xff,0xfe,0x80])
            try unreadable.write(to:main,options:.atomic); session.checkDisk("main.typ")
            check(session.error?.contains("UTF-8") == true && session.buffer.source.hasSuffix("LOCAL"),"Unreadable external source reports an error and retains local writing")
            do { try session.saveToDisk(); preconditionFailure("Invalid UTF-8 overwritten") } catch {}
            check(try Data(contentsOf:main) == unreadable,"Save preflight preserves invalid UTF-8 external bytes")
            session.recoveryQueue.sync {}
            let unreadableRecovery = try JSONDecoder().decode(Recovery.self,from:Data(contentsOf:session.recoveryURL))
            check(unreadableRecovery.files["main.typ"] == session.buffer.source,"Blocked save retains the local source in recovery")
            try savedSource.write(to:main,atomically:true,encoding:.utf8)
            session.buffers["new.typ"] = DocumentBuffer("New local writing")
            let newFile = root.appendingPathComponent("new.typ")
            try "Created externally".write(to:newFile,atomically:true,encoding:.utf8)
            do { try session.saveToDisk(); preconditionFailure("New external file overwritten") } catch {}
            let newDisk = try String(contentsOf:newFile,encoding:.utf8), mainDisk = try String(contentsOf:main,encoding:.utf8)
            check(newDisk == "Created externally" && mainDisk == savedSource,"New dependency collisions are rejected before any source is saved")
            session.buffers.removeValue(forKey:"new.typ"); try fm.removeItem(at:newFile)
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
            check(reopened.buffers["tools.typ"] != nil,"Save As preserves local imports and ignores commented asset examples")
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
            let conflict = DocumentSession(); sessions.append(conflict); try conflict.open(root.appendingPathComponent("Research.typ"))
            conflict.buffer.editSource(NSRange(location:conflict.buffer.source.utf16.count,length:0),text:" DISCARDED LOCAL")
            let localConflict = conflict.buffer.source
            try "Chosen disk text".write(to:root.appendingPathComponent("Research.typ"),atomically:true,encoding:.utf8); conflict.checkDisk(conflict.entry)
            check(conflict.useDiskVersion(),"Use disk version preserves a separate conflict recovery before discarding local changes")
            conflict.autosave(); check(conflict.ensureRecovery(),"Rolling recovery can be saved after a conflict choice")
            let archives = try fm.contentsOfDirectory(at:conflict.recoveryURL.deletingLastPathComponent(),includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix(conflict.id+"-conflict-") }
            check(archives.count == 1,"Conflict recovery has an independent file")
            let archived = try JSONDecoder().decode(Recovery.self,from:Data(contentsOf:archives[0]))
            check(archived.files[conflict.entry] == localConflict && conflict.buffer.source == "Chosen disk text","Later autosave/close recovery cannot overwrite discarded local writing")
            let nestedRoot = folder.appendingPathComponent("nested"), nestedCopy = folder.appendingPathComponent("nested-copy")
            try fm.createDirectory(at:nestedRoot.appendingPathComponent("chapters"),withIntermediateDirectories:true)
            try fm.createDirectory(at:nestedRoot.appendingPathComponent("assets"),withIntermediateDirectories:true)
            try fm.createDirectory(at:nestedCopy,withIntermediateDirectories:true)
            let nestedSource = "// #include \"untouched.typ\"\n#include \"one.typ\"\n#read(\"../assets/note.txt\")\n"
            try nestedSource.write(to:nestedRoot.appendingPathComponent("chapters/main.typ"),atomically:true,encoding:.utf8)
            try "= Nested chapter".write(to:nestedRoot.appendingPathComponent("chapters/one.typ"),atomically:true,encoding:.utf8)
            try "Asset contents".write(to:nestedRoot.appendingPathComponent("assets/note.txt"),atomically:true,encoding:.utf8)
            let nested = DocumentSession(); sessions.append(nested); try nested.open(nestedRoot,selectedEntry:"chapters/main.typ")
            try nested.saveCopy(to:nestedCopy.appendingPathComponent("Copy.typ"))
            check(nested.buffer.source == "// #include \"untouched.typ\"\n#include \"chapters/one.typ\"\n#read(\"assets/note.txt\")\n","Nested-entry Save As rebases literal include/asset paths and preserves comments")
            let nestedReopened = DocumentSession(); sessions.append(nestedReopened); try nestedReopened.open(nestedCopy)
            let copiedAsset = try String(contentsOf:nestedCopy.appendingPathComponent("assets/note.txt"),encoding:.utf8)
            check(nestedReopened.includes == ["Copy.typ","chapters/one.typ"] && copiedAsset == "Asset contents","Saved nested-entry projects reopen with chapters and assets intact")
            nestedReopened.compile()
            let compileDeadline = Date().addingTimeInterval(25)
            while nestedReopened.compiling && Date() < compileDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
            check(nestedReopened.pdf != nil && nestedReopened.error == nil,"Official compiler accepts app-generated nested include/read paths after Save As")
        } catch { fatalError("File acceptance: \(error)") }
    }
}
