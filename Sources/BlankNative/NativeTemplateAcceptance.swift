import AppKit
import PDFKit
import BlankCore

@MainActor enum NativeTemplateAcceptance {
    static func run(original: DocumentWindow) {
        let fm = FileManager.default, folder = fm.temporaryDirectory.appendingPathComponent("blank-templates-"+UUID().uuidString)
        let recents = NSDocumentController.shared.recentDocumentURLs
        var sessions: [DocumentSession] = [], windows: [DocumentWindow] = []
        var gallery: TemplateGalleryWindow?
        func check(_ value: Bool,_ label: String) { if !value { fatalError("Templates: "+label) }; print("PASS: "+label) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(90)
            while !condition() && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            check(condition(),"Template preview work completes")
        }
        defer {
            gallery?.window?.close()
            for window in windows { window.window?.close() }
            for session in sessions { session.saveWork?.cancel(); session.watchers.forEach { $0.cancel() }; session.recoveryQueue.sync {} }
            try? fm.removeItem(at:folder)
            NSDocumentController.shared.clearRecentDocuments(nil)
            recents.reversed().forEach { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
            original.window?.makeKeyAndOrderFront(nil)
        }
        do {
            let library = try TemplateLibrary(root:folder.appendingPathComponent("library"))
            check(library.templates.map(\.name) == TemplateLibrary.starterNames,"Template library seeds six packaged starters")
            let menu = NSApp.mainMenu?.item(withTitle:"File")?.submenu
            check(menu?.item(withTitle:"Templates…") != nil && menu?.item(withTitle:"Save as Template…") != nil && CommandsSheet(session:original.session).actions.contains { $0.0 == "Templates…" },"File and Cmd-K expose the template library")
            check(original.session.buffer.source.isEmpty,"Adding templates keeps launch and New Document empty")
            let starters = library.templates
            for item in starters { library.requestPreview(item,full:true) }
            wait { starters.allSatisfy { library.pdf($0) != nil || library.renderErrors[$0.id] != nil } }
            for item in starters {
                check(library.renderErrors[item.id] == nil && library.image(item) != nil && (library.pdf(item).flatMap { PDFDocument(data:$0) }?.pageCount ?? 0) > 0,"Packaged \(item.name) compiles to a real PDF and thumbnail: \(library.renderErrors[item.id] ?? "")")
                if item.name == "Slides", let pdf = library.pdf(item).flatMap({ PDFDocument(data:$0) }) {
                    check(pdf.pageCount == 3,"Slides includes three editable example slides")
                    for index in 0..<pdf.pageCount {
                        let bounds = pdf.page(at:index)!.bounds(for:.mediaBox)
                        check(abs(bounds.width/bounds.height-16.0/9.0) < 0.001,"Every Slides page uses the HD projector aspect ratio")
                    }
                }
                let stored = try library.read(item); sessions.append(stored)
                let copy = try library.newDocument(from:item); sessions.append(copy)
                check(copy.root == nil && copy.dirty && copy.buffer.source == stored.buffer.source && copy.entry == "Untitled.typ" && !copy.buffer.canUndo,"\(item.name) creates an independent exact-source draft with clean history")
                check(copy.buffer.projection.blocks.filter { $0.kind == "source" }.allSatisfy(\.collapsed),"Template layout configuration folds without changing source")
            }
            let legacyRoot = folder.appendingPathComponent("existing-library")
            try fm.createDirectory(at:legacyRoot,withIntermediateDirectories:true)
            try Data().write(to:legacyRoot.appendingPathComponent(".initialized"))
            let upgraded = try TemplateLibrary(root:legacyRoot)
            check(upgraded.templates.map(\.name) == ["Slides"],"Existing libraries receive Slides once without reseeding deleted older starters")
            try upgraded.moveToTrash(upgraded.templates[0],using:{ try fm.removeItem(at:$0) })
            let upgradedAgain = try TemplateLibrary(root:legacyRoot)
            check(upgradedAgain.templates.isEmpty,"Deleting the new Slides starter remains permanent on reopening")
            let chooser = TemplateGalleryWindow(library:library); gallery = chooser
            chooser.showWindow(nil); chooser.window?.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until:Date().addingTimeInterval(0.3))
            func descendant<T: NSView>(_ view: NSView?,as type: T.Type) -> T? {
                guard let view else { return nil }; if let result = view as? T { return result }
                return view.subviews.lazy.compactMap { descendant($0,as:type) }.first
            }
            guard let grid = descendant(chooser.window?.contentView,as:TemplateGrid.self) else { fatalError("Missing native template grid") }
            check(grid.numberOfItems(inSection:0) == starters.count && grid.isSelectable && !grid.allowsMultipleSelection,"Gallery uses a native single-selection thumbnail collection")
            let firstFrame = grid.layoutAttributesForItem(at:IndexPath(item:0,section:0))!.frame
            let lastFrame = grid.layoutAttributesForItem(at:IndexPath(item:4,section:0))!.frame
            check(firstFrame.minY <= lastFrame.minY && (0..<starters.count).allSatisfy { grid.layoutAttributesForItem(at:IndexPath(item:$0,section:0))!.frame.maxX <= grid.bounds.maxX },"Starter thumbnails fit the gallery’s available width across native rows")
            check(chooser.window?.toolbar?.items.filter { $0.isBordered }.count == 4,"Template gallery uses native glass toolbar controls")
            grid.selectItems(at:[IndexPath(item:0,section:0)],scrollPosition:[]); library.selection = starters[0].id
            func key(_ code: UInt16,_ characters: String) -> NSEvent {
                NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:chooser.window!.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
            }
            grid.keyDown(with:key(124,String(UnicodeScalar(NSRightArrowFunctionKey)!)))
            check(library.selection == starters[1].id,"Arrow keys select templates through native collection navigation")
            grid.keyDown(with:key(49," "))
            let sheetDeadline = Date().addingTimeInterval(3)
            while chooser.window?.attachedSheet == nil && Date() < sheetDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            RunLoop.main.run(until:Date().addingTimeInterval(0.2))
            guard let sheet = chooser.window?.attachedSheet else { fatalError("Template Preview did not open") }
            check((descendant(sheet.contentView,as:PDFView.self)?.document?.pageCount ?? 0) > 1,"Space opens the complete multipage template in a native PDF preview sheet")
            let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
            _ = sheet.performKeyEquivalent(with:escape)
            RunLoop.main.run(until:Date().addingTimeInterval(0.2))
            check(chooser.window?.attachedSheet == nil,"Escape dismisses template Preview and returns to the gallery")
            grid.keyDown(with:key(49," "))
            RunLoop.main.run(until:Date().addingTimeInterval(0.2))
            guard let createSheet = chooser.window?.attachedSheet else { fatalError("Preview did not reopen") }
            let previousCount = AppController.shared.controllers.count
            let returnKey = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:createSheet.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
            _ = createSheet.performKeyEquivalent(with:returnKey)
            RunLoop.main.run(until:Date().addingTimeInterval(0.3))
            check(chooser.window?.attachedSheet == nil && AppController.shared.controllers.count == previousCount+1,"Creating from Preview first dismisses its sheet and opens exactly one document")
            let previewCopy = AppController.shared.controllers.last!
            windows.append(previewCopy); sessions.append(previewCopy.session)
            previewCopy.session.dirty = false; previewCopy.window?.close()
            chooser.showWindow(nil)
            grid.keyDown(with:key(36,"\r"))
            guard let created = AppController.shared.controllers.last, created !== original else { fatalError("Gallery Return did not create a document") }
            windows.append(created); sessions.append(created.session)
            let chosenSource = try library.read(starters[1]).buffer.source
            check(created.session.root == nil && created.session.dirty && created.session.buffer.source == chosenSource && chooser.window?.isVisible == false,"Return creates the chosen independent document and returns to the editor")
            created.session.dirty = false; created.window?.close()
            chooser.window?.close()
            let project = folder.appendingPathComponent("input")
            try fm.createDirectory(at:project.appendingPathComponent("chapters"),withIntermediateDirectories:true)
            let source = "// Preserve Café 👩🏽‍💻\n#set text(size: 11pt)\n\n= Research\n\n*Bold* and _italic_ 日本\n\n#include \"chapters/one.typ\"\n#read(\"note.txt\")\n"
            try source.write(to:project.appendingPathComponent("main.typ"),atomically:true,encoding:.utf8)
            try "== Child\n\nExact source".write(to:project.appendingPathComponent("chapters/one.typ"),atomically:true,encoding:.utf8)
            try Data("Asset café".utf8).write(to:project.appendingPathComponent("note.txt"))
            let imported = DocumentSession(); try imported.open(project.appendingPathComponent("main.typ")); sessions.append(imported)
            let item = try library.add(imported,name:"Research"), initialVersion = item.version
            let duplicate = try library.duplicate(item)
            check(duplicate.id != item.id && duplicate.name == "Research copy","Duplicating a template creates a separate named project")
            let secondDuplicate = try library.duplicate(item)
            check(secondDuplicate.name == "Research copy 2","Repeated duplication gives unambiguous names")
            let draft = try library.newDocument(from:item); sessions.append(draft)
            check(draft.buffer.source == source && draft.buffers["chapters/one.typ"]?.source == "== Child\n\nExact source" && draft.assets["note.txt"] == Data("Asset café".utf8),"Template copies preserve comments, Unicode, includes and assets")
            let destination = folder.appendingPathComponent("output/Document.typ")
            try draft.saveCopy(to:destination)
            check(try String(contentsOf:destination,encoding:.utf8) == source && Data(contentsOf:destination.deletingLastPathComponent().appendingPathComponent("note.txt")) == Data("Asset café".utf8),"Independent template documents save their dependencies")
            check(try String(contentsOf:library.url(item),encoding:.utf8) == source,"Saving the copy never changes its template")
            try chooser.openEditor(item)
            guard let controller = AppController.shared.controllers.last else { fatalError("Edit Template did not open") }
            let edit = controller.session; sessions.append(edit); windows.append(controller)
            let windowCount = AppController.shared.controllers.count
            try chooser.openEditor(item)
            check(AppController.shared.controllers.count == windowCount && edit.root?.path == library.folder(item.id).path,"Edit opens the stored template once in the ordinary document editor")
            edit.buffer.editSource(NSRange(location:edit.buffer.source.utf16.count,length:0),text:"\nEdited template")
            edit.changed(); edit.saveWork?.cancel()
            try edit.saveToDisk()
            let edited = library.templates.first { $0.id == item.id }!
            check(edited.version != initialVersion && !edit.dirty && edit.buffer.source == source+"\nEdited template","Ordinary template Save updates the gallery version and canonical writing")
            let editedCopy = try library.newDocument(from:edited); sessions.append(editedCopy)
            check(editedCopy.buffer.source == edit.buffer.source && draft.buffer.source == source,"New copies use saved edits while existing documents stay independent")
            try edit.renameEntry("Renamed")
            check(library.templates.first { $0.id == item.id }?.name == "Renamed","Native rename keeps app-owned template entry selection and gallery synchronized")
            var rejected = false
            do { try library.moveToTrash(edited,using:{ try fm.removeItem(at:$0) }) } catch { rejected = true }
            check(rejected && fm.fileExists(atPath:library.folder(item.id).path),"Trash rejects an open template editor")
            controller.window?.close()
            check(!library.isEditing(edited),"Closing a template releases its edit protection")
            let trash = folder.appendingPathComponent("trash")
            try fm.createDirectory(at:trash,withIntermediateDirectories:true)
            try library.moveToTrash(edited,using:{ try fm.moveItem(at:$0,to:trash.appendingPathComponent($0.lastPathComponent)) })
            check(!library.templates.contains { $0.id == item.id } && fm.fileExists(atPath:destination.path),"Trashing a template leaves created documents untouched")
            let count = library.templates.count
            for name in ["", ".typ", "../escape", "bad\nname"] {
                var rejected = false
                do { _ = try library.add(imported,name:name) } catch { rejected = true }
                check(rejected && library.templates.count == count,"Invalid template name is rejected without a partial project")
            }
            let broken = DocumentSession(); broken.buffer.loadExternal("#thisDoesNotExist()")
            let invalid = try library.add(broken,name:"Needs editing")
            library.requestPreview(invalid,full:true)
            wait { library.renderErrors[invalid.id] != nil }
            let invalidCopy = try library.newDocument(from:invalid); sessions.append(invalidCopy)
            check(invalidCopy.buffer.source == "#thisDoesNotExist()" && library.pdf(invalid) == nil,"An invalid template stays editable and copyable with a clear preview error")
            for item in Array(library.templates) { try library.moveToTrash(item,using:{ try fm.moveItem(at:$0,to:trash.appendingPathComponent($0.lastPathComponent)) }) }
            let reopened = try TemplateLibrary(root:library.root)
            check(reopened.templates.isEmpty,"Empty template libraries persist without reseeding deleted starters")
            print("PASS: native template library acceptance")
        } catch { fatalError("Native template acceptance: \(error)") }
    }
}
