import AppKit
import BlankCore

@MainActor enum NativeDocumentAcceptance {
    static func run() {
        let fm = FileManager.default, folder = fm.temporaryDirectory.appendingPathComponent("blank-document-"+UUID().uuidString)
        let recents = NSDocumentController.shared.recentDocumentURLs
        var windows: [DocumentWindow] = []
        defer {
            windows.forEach { $0.window?.close(); $0.session.recoveryQueue.sync {} }
            try? fm.removeItem(at:folder)
            NSDocumentController.shared.clearRecentDocuments(nil)
            recents.reversed().forEach { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
        }
        func check(_ value: Bool,_ label: String) { if !value { fatalError(label) }; print("PASS: "+label) }
        func complete(_ operation: (@escaping ((any Error)?) -> Void) -> Void) -> (any Error)? {
            var finished = false, result: (any Error)?
            operation { result = $0; finished = true }
            let deadline = Date().addingTimeInterval(10)
            while !finished && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
            check(finished,"Native document operation completes")
            return result
        }
        do {
            try fm.createDirectory(at:folder,withIntermediateDirectories:true)
            let session = DocumentSession(), controller = DocumentWindow(session:session)
            windows.append(controller)
            controller.showWindow(nil)
            let document = controller.nativeDocument
            let source = "// Keep this comment\n= Café 👩🏽‍💻\n\n*Bold* and 日本\n\n#include \"child.typ\"\n"
            session.buffers["child.typ"] = DocumentBuffer("Child 日本")
            session.buffer.loadExternal(source); session.changed(); session.saveWork?.cancel()
            let revision = session.buffer.revision
            check(complete { document.autosave(withImplicitCancellability:false,completionHandler:$0) } == nil,"AppKit creates a real unsaved draft")
            check(session.root == nil && session.dirty && session.buffer.revision == revision && session.buffer.source == source,"Native draft autosave preserves canonical source, history and unsaved state")
            guard let draft = document.fileURL else { fatalError("Missing native draft URL") }
            let draftSource = try String(contentsOf:draft,encoding:.utf8)
            check(document.isDraft && draftSource == source,"Native title represents the actual UTF-8 draft")
            session.buffer.editSource(NSRange(location:session.buffer.source.utf16.count,length:0),text:"Second edit")
            session.buffers["child.typ"]!.editSource(NSRange(location:0,length:0),text:"Edited ")
            session.changed(); session.saveWork?.cancel()
            check(document.hasUnautosavedChanges,"Editing an autosaved draft marks new native changes")
            check(complete { document.autosave(withImplicitCancellability:true,completionHandler:$0) } == nil,"Native draft autosaves subsequent edits")
            check(try String(contentsOf:document.fileURL!,encoding:.utf8) == session.buffer.source,"Subsequent draft autosave retains every source character")
            check(try String(contentsOf:draft.deletingLastPathComponent().appendingPathComponent("child.typ"),encoding:.utf8) == "Edited Child 日本","Draft snapshots update included files without changing their histories")
            let renamedDraft = draft.deletingLastPathComponent().appendingPathComponent("Native name.typ")
            check(complete { document.move(to:renamedDraft,completionHandler:$0) } == nil,"Native draft rename completes")
            check(session.entry == "Native name.typ" && session.root == nil && document.isDraft,"Renaming a draft does not silently save it as a user document")
            let saved = folder.appendingPathComponent("Saved.typ")
            check(complete { document.save(to:saved,ofType:"org.typst.source",for:.saveAsOperation,completionHandler:$0) } == nil,"Native save panel backend adopts a saved document")
            check(session.root?.path == folder.path && document.fileURL == saved && !document.isDraft && !session.dirty && !document.isDocumentEdited,"Saving clears native draft/Edited state and synchronizes file identity")
            let project = folder.appendingPathComponent("project"), destination = folder.appendingPathComponent("moved")
            try fm.createDirectory(at:project,withIntermediateDirectories:true)
            try fm.createDirectory(at:destination,withIntermediateDirectories:true)
            let main = project.appendingPathComponent("main.typ")
            try "// untouched\n#include \"child.typ\"\n#read(\"note.txt\")".write(to:main,atomically:true,encoding:.utf8)
            try "= Child\n\n日本".write(to:project.appendingPathComponent("child.typ"),atomically:true,encoding:.utf8)
            try "Asset".write(to:project.appendingPathComponent("note.txt"),atomically:true,encoding:.utf8)
            let projectSession = DocumentSession(); try projectSession.open(main)
            let projectWindow = DocumentWindow(session:projectSession); windows.append(projectWindow)
            let projectDocument = projectWindow.nativeDocument, projectSource = projectSession.buffer.source
            let renamed = project.appendingPathComponent("Research.typ")
            check(complete { projectDocument.move(to:renamed,completionHandler:$0) } == nil,"Native saved-document rename uses the existing project transaction")
            check(projectSession.entry == "Research.typ" && projectDocument.fileURL == renamed && !fm.fileExists(atPath:main.path),"Native rename synchronizes file, model and title identity")
            let moved = destination.appendingPathComponent("Research.typ")
            projectSession.compileRevision = projectSession.revision
            check(complete { projectDocument.move(to:moved,completionHandler:$0) } == nil,"Native Move To relocates a multi-file document")
            check(projectSession.root?.path == destination.path && projectSession.buffer.source == projectSource && !fm.fileExists(atPath:renamed.path),"Native move preserves exact source and removes only the original entry")
            check(projectSession.compileRevision != projectSession.revision,"Moving a document invalidates preview navigation and export identity")
            let childSource = try String(contentsOf:destination.appendingPathComponent("child.typ"),encoding:.utf8), assetSource = try String(contentsOf:destination.appendingPathComponent("note.txt"),encoding:.utf8)
            check(childSource == "= Child\n\n日本" && assetSource == "Asset","Native move carries included files and referenced assets")
            check(complete { finish in projectDocument.lock { (success: Bool) in finish(success ? nil : CocoaError(.fileWriteNoPermission)) } } == nil,"Native title lock protects the actual document file")
            check(projectDocument.isLocked,"Native document reports its locked state")
            check(complete { finish in projectDocument.unlock { (success: Bool) in finish(success ? nil : CocoaError(.fileWriteNoPermission)) } } == nil && !projectDocument.isLocked,"Native title unlock restores editability")
            let collision = destination.appendingPathComponent("Occupied.typ")
            try "Unrelated".write(to:collision,atomically:true,encoding:.utf8)
            check(complete { projectDocument.move(to:collision,completionHandler:$0) } != nil && projectDocument.fileURL == moved,"Native move rejects a collision without adopting its path")
            projectSession.buffer.editSource(NSRange(location:projectSource.utf16.count,length:0),text:" LOCAL")
            projectSession.changed(); projectSession.saveWork?.cancel()
            try "EXTERNAL".write(to:moved,atomically:true,encoding:.utf8)
            check(complete { projectDocument.save(to:moved,ofType:"org.typst.source",for:.saveOperation,completionHandler:$0) } != nil,"Native save preserves existing external-conflict protection")
            check(try String(contentsOf:moved,encoding:.utf8) == "EXTERNAL","Native save never overwrites conflicting external writing")
        } catch { fatalError("Native document acceptance: \(error)") }
    }
}
