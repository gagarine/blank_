import AppKit
import BlankCore

@MainActor enum NativeFigureAcceptance {
    static let fixture = "Before café 👩🏽‍💻.\n\n#figure(image(\"assets/original.png\", width: 85%, alt: \"Original alternative\"), caption: [Original caption])\n\nAfter."
    static func imageData(_ color: NSColor) -> Data {
        let image = NSImage(size:NSSize(width:120,height:80))
        image.lockFocus(); color.setFill(); NSBezierPath(rect:NSRect(x:0,y:0,width:120,height:80)).fill(); image.unlockFocus()
        return NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
    }
    static func showFixture(controller: DocumentWindow) {
        let session = controller.session
        session.assets["assets/original.png"] = imageData(.systemBlue)
        session.buffer.loadExternal(fixture); session.editor?.refresh(reveal:true)
    }
    static func field(_ view: NSView?,_ placeholder: String) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
        return view.subviews.lazy.compactMap { field($0,placeholder) }.first
    }
    static func check(_ condition: @autoclosure () -> Bool,_ label: String) {
        guard condition() else { fatalError("FAIL: \(label)") }; print("PASS: \(label)")
    }
    static func run(controller original: DocumentWindow) {
        let session = DocumentSession(), controller = DocumentWindow(session:session)
        AppController.shared.controllers.append(controller)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        defer {
            session.sheet = nil; session.saveWork?.cancel(); session.dirty = false
            controller.nativeDocument.updateChangeCount(.changeCleared); controller.window?.close()
            original.window?.makeKeyAndOrderFront(nil)
        }
        showFixture(controller:controller)
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        let editor = session.editor!
        func open() -> NSTextField {
            editor.refresh(reveal:true)
            let index = session.buffer.projection.blocks.firstIndex { $0.kind == "image" }!
            session.editObject(index)
            RunLoop.main.run(until:Date().addingTimeInterval(0.3))
            guard let caption = field(controller.window?.attachedSheet?.contentView,"Caption") else { fatalError("FAIL: Editing a literal figure offers the insertion caption controls") }
            return caption
        }
        func key(_ input: NSTextView,_ character: String,_ code: UInt16) {
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:controller.window!.attachedSheet!.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:code)!
            controller.window!.attachedSheet!.makeKeyAndOrderFront(nil)
            if !controller.window!.attachedSheet!.performKeyEquivalent(with:event) { NSApp.sendEvent(event) }
            RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        }
        let figureView = editor.subviews.compactMap { $0 as? FigureBlockView }.first!
        for child in figureView.subviews {
            let center = NSPoint(x:child.frame.midX,y:child.frame.midY)
            let point = editor.convert(center,from:figureView)
            check(editor.hitTest(editor.convert(point,to:editor.superview)) === figureView,"Image and caption clicks hit the shared figure editor")
        }
        let first = open()
        let content = controller.window?.attachedSheet?.contentView
        check(first.stringValue == "Original caption" && field(content,"Project-relative image path")?.stringValue == "assets/original.png" && field(content,"Alternative text")?.stringValue == "Original alternative","Literal figure editing offers populated path, caption and alternative text controls")
        let beforeRevision = session.revision, beforeBufferRevision = session.buffer.revision, beforeSelection = session.buffer.selection
        first.selectText(nil); key(first.currentEditor() as! NSTextView,"\r",36)
        check(session.sheet == nil && session.buffer.source == fixture && !session.buffer.canUndo && !session.dirty && session.revision == beforeRevision && session.buffer.revision == beforeBufferRevision && session.buffer.selection == beforeSelection,"No-op native Apply preserves source, selection, history and dirty revisions | sheet=\(String(describing:session.sheet)) same=\(session.buffer.source == fixture) undo=\(session.buffer.canUndo) dirty=\(session.dirty) rev=\(session.revision)/\(beforeRevision) buffer=\(session.buffer.revision)/\(beforeBufferRevision) selection=\(session.buffer.selection)/\(beforeSelection)")
        let cancel = open(); cancel.selectText(nil)
        let cancelInput = cancel.currentEditor() as! NSTextView
        cancelInput.insertText("Discarded caption",replacementRange:cancelInput.selectedRange()); key(cancelInput,"\u{1b}",53)
        check(session.sheet == nil && session.buffer.source == fixture && !session.buffer.canUndo && !session.dirty,"Escape cancels edited figure fields without changing source or history")
        let caption = open(); caption.selectText(nil)
        let input = caption.currentEditor() as! NSTextView, text = "Café 日本 👩🏽‍💻 #[]*_"
        input.insertText(text,replacementRange:input.selectedRange()); key(input,"\r",36)
        let expected = fixture.replacingOccurrences(of:"[Original caption]",with:"["+escapeTypst(text)+"]")
        check(session.sheet == nil && Array(session.buffer.source.utf8) == Array(expected.utf8),"Native Return applies Unicode caption text to the existing figure only")
        session.switchMode(.source); session.undo()
        check(session.buffer.source == fixture && session.buffer.selection == beforeSelection,"Figure Undo from Source restores exact Write source and selection")
        session.undo(true); check(session.buffer.source == expected,"Figure Redo restores the changed caption")
        session.switchMode(.write); session.undo()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blank-figure-acceptance-"+UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { session.saveWork?.cancel(); session.watchers.forEach { $0.cancel() }; session.diskScanWork?.cancel(); session.dirty = false; try? FileManager.default.removeItem(at:directory) }
        let replacement = directory.appendingPathComponent("replacement 日本.png"), replacementData = imageData(.systemOrange)
        try! replacementData.write(to:replacement)
        let assetSnapshot = session.assets
        _ = open(); let edit = FigureFieldEdit(session.objectOriginal)!
        session.buffer.editSource(NSRange(location:0,length:0),text:"Intervening 日本.\n",group:"")
        let stale = session.buffer.source
        check((try! session.applyFigure(edit,path:edit.path,caption:"Stale",alt:edit.alt,width:40,replacement:replacement)) == false && session.buffer.source == stale && session.assets == assetSnapshot,"Stale figure Apply rejects source and replacement asset changes")
        session.sheet = nil; session.error = nil; session.buffer.loadExternal(fixture); session.dirty = false
        _ = open(); let fresh = FigureFieldEdit(session.objectOriginal)!
        do {
            _ = try session.applyFigure(fresh,path:fresh.path,caption:fresh.caption,alt:fresh.alt,width:40,replacement:directory.appendingPathComponent("missing.png"))
            fatalError("Missing replacement must fail")
        } catch { check(session.assets == assetSnapshot && session.buffer.source == fixture && !session.buffer.canUndo,"Failed replacement reads preserve source, history and assets") }
        let blockedRoot = directory.appendingPathComponent("blocked")
        try! FileManager.default.createDirectory(at:blockedRoot,withIntermediateDirectories:true)
        try! Data("Unrelated file".utf8).write(to:blockedRoot.appendingPathComponent("assets"))
        session.root = blockedRoot
        do {
            _ = try session.applyFigure(fresh,path:fresh.path,caption:fresh.caption,alt:fresh.alt,width:40,replacement:replacement)
            fatalError("Blocked asset directory must fail")
        } catch { check(session.assets == assetSnapshot && session.buffer.source == fixture && (try! String(contentsOf:blockedRoot.appendingPathComponent("assets"),encoding:.utf8)) == "Unrelated file","Failed replacement writes preserve unrelated disk files, source and asset state") }
        session.root = nil; session.sheet = nil
        _ = open(); session.active = "other.typ"; session.buffers["other.typ"] = DocumentBuffer("Other file")
        check((try! session.applyFigure(fresh,path:fresh.path,caption:"Wrong file",alt:fresh.alt,width:40,replacement:replacement)) == false && session.assets == assetSnapshot && session.buffer.source == "Other file","Changing active files rejects replacement imports before touching assets")
        session.sheet = nil; session.error = nil; session.active = "main.typ"
        // Imported files remain project-relative when editing an included chapter.
        let chapter = fixture.replacingOccurrences(of:"assets/original.png",with:"../assets/original.png")
        session.buffers = ["main.typ":DocumentBuffer("#include \"chapters/one.typ\""),"chapters/one.typ":DocumentBuffer(chapter)]
        session.entry = "main.typ"; session.active = "chapters/one.typ"
        session.root = directory.appendingPathComponent("Project")
        try! FileManager.default.createDirectory(at:session.root!,withIntermediateDirectories:true)
        for (path,model) in session.buffers { try! DocumentSession.writeDependency(Data(model.source.utf8),path:path,root:session.root!) }
        for (path,data) in session.assets { try! DocumentSession.writeDependency(data,path:path,root:session.root!) }
        session.bases = session.buffers.mapValues(\.source)
        editor.refresh(reveal:true); _ = open(); let nested = FigureFieldEdit(session.objectOriginal)!
        check(try! session.applyFigure(nested,path:nested.path,caption:"Replacement caption",alt:"Replacement alternative 日本",width:40,replacement:replacement),"Replacement image Apply succeeds in an included chapter")
        let replaced = session.buffer.source
        let imageBlock = session.buffer.projection.blocks.first { $0.kind == "image" }!
        let replacedEdit = FigureFieldEdit(replaced.bytes(imageBlock.source))!
        let importedPath = session.projectAssetPath(replacedEdit.path)!
        check(replacedEdit.path.hasPrefix("../assets/") && session.assets[importedPath] == replacementData && session.assets["assets/original.png"] == assetSnapshot["assets/original.png"],"Replacement paths resolve from the included file and retain both old and new image assets")
        session.compile()
        let deadline = Date().addingTimeInterval(15)
        while session.compiling && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        check(session.pdf != nil && session.error == nil && session.pdf!.page(at:0)!.string!.contains("Replacement caption"),"Edited path, caption, alt and percentage width compile through the bundled official compiler | error=\(session.error ?? "none") compiling=\(session.compiling) rev=\(session.revision)/\(session.compileRevision) pdf=\(session.pdf?.pageCount ?? 0) text=\(session.pdf?.page(at:0)?.string ?? "none")")
        session.undo(); check(session.buffer.source == chapter && session.assets["assets/original.png"] != nil && session.assets[importedPath] != nil,"Replacement Undo restores the exact original chapter and keeps resolvable image assets")
        session.undo(true); check(session.buffer.source == replaced && session.assets[importedPath] == replacementData,"Replacement Redo retains the imported image")
        let draft = DocumentSession()
        draft.assets["assets/original.png"] = assetSnapshot["assets/original.png"]
        draft.buffer.loadExternal(fixture)
        draft.editSourceObject(draft.buffer.projection.blocks.first { $0.kind == "image" }!.source,title:"Edit Image")
        let draftEdit = FigureFieldEdit(draft.objectOriginal)!
        check(try! draft.applyFigure(draftEdit,path:draftEdit.path,caption:"Draft replacement",alt:draftEdit.alt,width:50,replacement:replacement),"Replacement figures also apply in independent unsaved drafts")
        draft.compile()
        let draftDeadline = Date().addingTimeInterval(15)
        while draft.compiling && Date() < draftDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        check(draft.pdf != nil && draft.error == nil,"An independent unsaved draft replacement compiles (\(draft.error ?? "no error"))")
        draft.saveWork?.cancel()
        session.buffer.loadExternal("#figure(image(\"../assets/original.png\", width: auto), caption: [*Rich*])"); editor.refresh()
        session.editObject(session.buffer.projection.blocks.firstIndex { $0.kind == "image" }!)
        RunLoop.main.run(until:Date().addingTimeInterval(0.3))
        check(session.objectTitle == "Edit source" && field(controller.window?.attachedSheet?.contentView,"Caption") == nil,"Custom width and rich captions retain the exact-source editor")
        session.sheet = nil
    }
}
