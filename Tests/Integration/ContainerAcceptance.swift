import AppKit
import PDFKit
import BlankCore
@testable import BlankNative

@MainActor enum ContainerAcceptance {
    static func run() {
        let fm = FileManager.default, folder = AppController.temporaryDirectory.appendingPathComponent("blank-typz-check-"+UUID().uuidString)
        let recents = NSDocumentController.shared.recentDocumentURLs
        var sessions: [DocumentSession] = []
        let existingWindows = Set(AppController.shared.controllers.map(ObjectIdentifier.init))
        defer {
            for controller in AppController.shared.controllers where !existingWindows.contains(ObjectIdentifier(controller)) {
                controller.session.dirty = false; controller.window?.close()
            }
            sessions.forEach {
                $0.saveWork?.cancel(); $0.diskScanWork?.cancel(); $0.watchers.forEach { $0.cancel() }; $0.recoveryQueue.sync {}
                try? fm.removeItem(at:$0.containerDirectory)
            }
            try? fm.removeItem(at:folder)
            NSDocumentController.shared.clearRecentDocuments(nil); recents.reversed().forEach { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
        }
        func check(_ condition: Bool,_ label: String) { guard condition else { fatalError("FAIL: "+label) }; print("PASS: "+label) }
        func session() -> DocumentSession { let value = DocumentSession(); sessions.append(value); return value }
        func compile(_ s: DocumentSession) {
            s.compile(); let end = Date().addingTimeInterval(25)
            while s.compiling && Date() < end { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
            check(s.pdf != nil && s.error == nil,"Official compiler renders the saved document: \(s.error ?? "success")")
        }
        func complete(_ operation: (@escaping (Error?) -> Void) -> Void) -> Error? {
            var done = false, result: Error?
            operation { result = $0; done = true }
            let end = Date().addingTimeInterval(15)
            while !done && Date() < end { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
            check(done,"Native bundle operation completes"); return result
        }
        do {
            let root = folder.appendingPathComponent("original")
            try fm.createDirectory(at:root.appendingPathComponent("chapters"),withIntermediateDirectories:true)
            try fm.createDirectory(at:root.appendingPathComponent("data"),withIntermediateDirectories:true)
            let source = "// Preserve exact Unicode and custom expressions\n#let path = \"../data/\" + \"café.txt\"\n#read(path)\n#include \"two.typ\"\n"
            try source.write(to:root.appendingPathComponent("chapters/main.typ"),atomically:true,encoding:.utf8)
            try "== 日本\n\nChild 👩🏽‍💻".write(to:root.appendingPathComponent("chapters/two.typ"),atomically:true,encoding:.utf8)
            try "Asset café".write(to:root.appendingPathComponent("data/café.txt"),atomically:true,encoding:.utf8)
            let unused = Data([0,255,42,1]); try unused.write(to:root.appendingPathComponent("unused.bin"))
            let s = session(); try s.open(root,selectedEntry:"chapters/main.typ")
            let originalBuffer = s.buffer
            s.buffer.selection = EditSelection(4,4)
            let url = folder.appendingPathComponent("Paper.typz")
            try s.saveFormatted(to:url,format:.container)
            check(s.documentURL == url && s.title == "Paper" && s.entry == "chapters/main.typ" && s.root != root,"Bundle has a file identity and a private compiler workspace")
            check(s.buffer === originalBuffer && s.buffer.source == source && s.buffer.selection == EditSelection(4,4),"Saving as .typz retains exact source, model and Unicode selection")
            let r = session(); try r.open(url)
            check(r.documentURL == url && r.entry == "chapters/main.typ" && r.buffer.source == source,"Opening .typz honors its nested ZIP-comment entrypoint")
            check(try Data(contentsOf:r.root!.appendingPathComponent("unused.bin")) == unused,"Unreferenced binary project files survive a bundle round trip")
            compile(r)
            r.buffer.editSource(NSRange(location:r.buffer.source.utf16.count,length:0),text:"\nNew writing 日本")
            let edited = r.buffer.source, modelRevision = r.buffer.revision
            r.changed(); r.saveWork?.cancel(); r.autosave()
            check(!r.dirty && r.buffer.revision == modelRevision && r.documentURL == url,"Autosave writes the same .typz file without rebuilding editing history")
            r.undo(); r.saveWork?.cancel(); check(r.buffer.source == source,"Bundle save preserves shared source Undo")
            r.undo(true); r.saveWork?.cancel(); check(r.buffer.source == edited,"Bundle save preserves shared source Redo")
            let again = session(); try again.open(url); check(again.buffer.source == edited,"Autosaved writing is in the actual .typz file")
            let recovery = r.recoverySnapshot()
            check(recovery.assets["unused.bin"] == unused && recovery.assets["data/café.txt"] != nil,"Bundle recovery includes binary and unreferenced dependencies")
            let native = NativeDocument(session:r)
            check(native.fileURL == url && native.fileType == DocumentFormat.container.typeName,"NSDocument title/proxy and type represent .typz, never working files")
            let renamed = folder.appendingPathComponent("Renamed.typz")
            check(complete { native.move(to:renamed,completionHandler:$0) } == nil && native.fileURL == renamed && !fm.fileExists(atPath:url.path),"Native Rename/Move acts on the .typz file")
            let export = folder.appendingPathComponent("Export.typz")
            check(complete { native.save(to:export,ofType:DocumentFormat.container.typeName,for:.saveToOperation,completionHandler:$0) } == nil && r.containerURL == renamed,"Native Save To exports a bundle without adopting its identity")
            let preview = folder.appendingPathComponent("Preview.pdf")
            _ = try TypstContainer.run(["--typz-preview",export.path,preview.path])
            check(PDFDocument(data:try Data(contentsOf:preview))?.page(at:0)?.string?.contains("New writing") == true,"A native bundle save contains its current rendered Quick Look PDF")
            let cached = session(); try cached.open(export)
            check(cached.pdf != nil && cached.assets.keys.allSatisfy { !$0.hasPrefix("blank-preview-") },"Opening a saved bundle shows its cached PDF without exposing cache files as project assets")
            let folderModel = r.buffer
            let folderCopy = folder.appendingPathComponent("Folder copy")
            try r.saveFormatted(to:folderCopy,format:.folder)
            check(r.containerURL == nil && r.root == folderCopy && r.buffer === folderModel,"Folder save switches from the bundle while retaining its session buffers")
            check(try String(contentsOf:folderCopy.appendingPathComponent(r.entry),encoding:.utf8) == edited,"Folder save preserves nested source and computed paths exactly")
            compile(r)
            let before = Set(try fm.contentsOfDirectory(atPath:folder.path))
            do { try r.saveFormatted(to:folder.appendingPathComponent("Computed.typ"),format:.document); fatalError("Computed paths silently changed") } catch {}
            check(Set(try fm.contentsOfDirectory(atPath:folder.path)) == before,"An unsafe single-file conversion fails before writing any files")
            let conflicting = session(); try conflicting.open(renamed)
            conflicting.buffer.editSource(NSRange(location:0,length:0),text:"LOCAL "); conflicting.changed(); conflicting.saveWork?.cancel()
            let external = Data("External replacement".utf8); try external.write(to:renamed,options:.atomic)
            do { try conflicting.saveToDisk(); fatalError("Conflicting .typz overwritten") } catch {}
            check(try Data(contentsOf:renamed) == external && conflicting.dirty,"External .typz replacements are never overwritten by autosave")
            let rescued = folder.appendingPathComponent("Rescued.typz"); try conflicting.saveFormatted(to:rescued,format:.container)
            let rescuedSession = session(); try rescuedSession.open(rescued)
            check(rescuedSession.buffer.source.hasPrefix("LOCAL "),"Save As rescues local bundle writing after an external conflict")
            let plain = session()
            plain.buffer.loadExternal("// Keep comments\n#include \"chapter.typ\"\n#read(\"note.txt\")\n")
            plain.buffers["chapter.typ"] = DocumentBuffer("== Chapter\n\nExact writing\n#read(\"/note.txt\")")
            plain.assets["note.txt"] = Data("Hello".utf8)
            let plainModel = plain.buffer
            plain.buffer.editSource(NSRange(location:plain.buffer.source.utf16.count,length:0),text:"日本👩🏽‍💻")
            let typingID = plain.buffer.undoID
            plain.buffer.selection = EditSelection(plain.buffer.source.utf8.count,plain.buffer.source.utf8.count)
            try plain.saveFormatted(to:folder.appendingPathComponent("Single.typ"),format:.document)
            check(plain.buffer === plainModel && plain.buffer.source.contains("\"chapter.typ\"") && plain.buffer.source.hasPrefix("// Keep comments"),"Single .typ save keeps dependency paths and canonical buffers")
            check(fm.fileExists(atPath:folder.appendingPathComponent("note.txt").path) && !fm.fileExists(atPath:folder.appendingPathComponent("Single-assets").path),"Single .typ dependencies retain the project hierarchy without a filename prefix")
            let savedSingle = plain.buffer.source, savedSelection = plain.buffer.selection
            check(plain.buffer.undoID == typingID,"Single-file Save As preserves the identity of the last user edit")
            plain.undo(); plain.saveWork?.cancel()
            check(!plain.buffer.source.hasSuffix("日本👩🏽‍💻") && plain.buffer.source.contains("\"chapter.typ\""),"Undo after single-file Save As reverses typing and keeps project paths")
            compile(plain)
            plain.undo(true); plain.saveWork?.cancel()
            check(plain.buffer.source == savedSingle && plain.buffer.selection == savedSelection,"Redo after relocation restores Unicode source and selection exactly")
            let reopened = session(); try reopened.open(folder.appendingPathComponent("Single.typ")); compile(reopened)
            let collision = folder.appendingPathComponent("assets/note.txt")
            try fm.createDirectory(at:collision.deletingLastPathComponent(),withIntermediateDirectories:true)
            try external.write(to:collision)
            let draft = session(); draft.assets["assets/note.txt"] = Data("Local".utf8)
            do { try draft.saveFormatted(to:folder.appendingPathComponent("Collision.typ"),format:.document); fatalError("Dependency overwritten") } catch {}
            check(try !fm.fileExists(atPath:folder.appendingPathComponent("Collision.typ").path) && Data(contentsOf:collision) == external,"Single-file save preflights dependency collisions")

        } catch { fatalError("Typst container acceptance: \(error)") }
    }
}
