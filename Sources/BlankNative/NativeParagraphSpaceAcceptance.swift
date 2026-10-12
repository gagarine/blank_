import AppKit
import BlankCore

@MainActor enum NativeParagraphSpaceAcceptance {
    static let prose = "Café 👩🏽‍💻\n\nCitation here\n\nNext"
    static let reference = ZoteroReference(key:"ABCD1234",library:"personal",title:"Citation acceptance reference",author:"Example",year:"2026",citeKey:"zotero-users-0-ABCD1234")
    static func prepare(_ session: DocumentSession,done: @escaping () -> Void) {
        session.buffer.loadExternal(prose); session.revision += 1; session.editor?.refresh()
        let range = (prose as NSString).range(of:"Citation here"), at = prose.byteOffset(utf16:NSMaxRange(range))
        ZoteroIntegration.insert([reference],session:session,anchor:EditSelection(at,at),locator:"",form:"normal") { error in
            guard error == nil else { fatalError("Paragraph Space citation fixture: \(error!)") }
            session.compile(); done()
        }
    }
    static func showFixture(controller: DocumentWindow) {
        URLProtocol.registerClass(CitationAcceptanceProtocol.self)
        prepare(controller.session) {
            controller.session.buffer.selection = EditSelection("Café 👩🏽‍💻".utf8.count,"Café 👩🏽‍💻".utf8.count)
            controller.session.editor?.refresh(reveal:true)
        }
    }
    static func run(original: DocumentWindow) {
        let session = DocumentSession(), controller = DocumentWindow(session:session)
        AppController.shared.controllers.append(controller)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        func check(_ value: @autoclosure () -> Bool,_ label: String) {
            guard value() else { fatalError("FAIL: Paragraph Space: \(label) | source=\(session.buffer.source) | native=\(session.editor?.string ?? "nil") | selection=\(String(describing:session.editor?.selectedRange()))") }
            print("PASS: Paragraph Space: \(label)")
        }
        func pump(until deadline: Date) {
            for _ in 0..<32 {
                guard Date() < deadline, let event = NSApp.nextEvent(matching:.any,until:Date(),inMode:.default,dequeue:true) else { break }
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until:Date().addingTimeInterval(0.01))
        }
        func wait(_ label: String,seconds: TimeInterval = 3,_ ready: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !ready() && Date() < deadline { pump(until:deadline) }
            check(ready(),label)
        }
        func settle() {
            let deadline = Date().addingTimeInterval(0.6)
            while Date() < deadline { pump(until:deadline) }
        }
        defer {
            session.revision += 1; session.saveWork?.cancel(); session.watchers.forEach { $0.cancel() }; session.recoveryQueue.sync {}
            session.dirty = false; controller.nativeDocument.updateChangeCount(.changeCleared)
            controller.window?.close(); original.window?.makeKeyAndOrderFront(nil); original.window?.makeFirstResponder(original.session.editor)
        }
        NSApp.activate(ignoringOtherApps:true)
        wait("fixture is an active native document") { NSApp.isActive && controller.window?.isKeyWindow == true && session.editor != nil }
        var prepared = false
        prepare(session) { prepared = true }
        wait("real insertion and official citation formatting complete",seconds:20) { prepared && !session.compiling && session.buffer.renderedReferences.contains { $0.kind == "citation" } }
        let inserted = session.buffer.source
        var editor: NativeTextView { session.editor! }
        func key(_ code: UInt16,_ characters: String) {
            controller.window?.makeFirstResponder(editor)
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:controller.window!.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
            NSApp.sendEvent(event)
        }
        let splitDisplay = "Café".utf16.count, splitByte = "Café".utf8.count
        editor.setSelectedRange(NSRange(location:splitDisplay,length:0)); editor.captureSelection(); session.buffer.breakUndoGroup()
        let beforeSplit = session.buffer.source, beforeSplitSelection = session.buffer.selection
        key(36,"\r")
        let splitSource = beforeSplit.replacingBytes(ByteSpan(splitByte,splitByte),with:"\n\n")
        check(session.buffer.source == splitSource && session.buffer.projection.blocks[1].text == " 👩🏽‍💻" && editor.selectedRange() == NSRange(location:splitDisplay+1,length:0),"native Return preserves the existing word separator and caret before it")
        session.undo(); check(session.buffer.source == beforeSplit && session.buffer.selection == beforeSplitSelection,"native Return has exact source and caret Undo")
        session.undo(true); check(session.buffer.source == splitSource && editor.selectedRange() == NSRange(location:splitDisplay+1,length:0),"native Return has exact source and caret Redo")
        for deletedCitation in [false,true] {
            for paragraph in ["Café 👩🏽‍💻","Citation here"] {
                session.buffer.loadExternal(""); session.buffer.loadExternal(inserted); session.revision += 1; editor.refresh()
                session.compile()
                wait("citation fixture is formatted",seconds:20) { !session.compiling && session.buffer.renderedReferences.contains { $0.kind == "citation" } }
                if deletedCitation {
                    let citation = session.buffer.renderedReferences.first { $0.kind == "citation" }!
                    let start = session.buffer.projection.displayOffset(at:citation.source.start), end = session.buffer.projection.displayOffset(at:citation.source.end)
                    editor.setSelectedRange(NSRange(location:start,length:end-start)); editor.captureSelection()
                    key(51,"\u{7f}")
                    check(!session.buffer.source.contains("#cite(") && session.buffer.source.contains("#bibliography("),"native citation deletion retains the bibliography")
                    settle()
                }
                let index = session.buffer.projection.blocks.firstIndex { $0.text.hasPrefix(paragraph) }!
                let block = session.buffer.projection.blocks[index], at = NSMaxRange(block.display)
                editor.setSelectedRange(NSRange(location:at,length:0)); editor.captureSelection(); session.buffer.breakUndoGroup()
                let before = session.buffer.source, selected = session.buffer.selection, sourceEnd = selected.focus
                for (count,characters) in [(1," "),(2," "),(3,"x")] {
                    key(characters == " " ? 49 : 7,characters)
                    let suffix = count == 1 ? " " : count == 2 ? "  " : "  x"
                    check(session.buffer.source == before.replacingBytes(ByteSpan(sourceEnd,sourceEnd),with:suffix),"native Space/typing preserves every surrounding source byte (deleted=\(deletedCitation))")
                    check(session.buffer.projection.blocks[index].kind == block.kind && session.buffer.projection.blocks[index].text == block.text+suffix,"Space remains in the same paragraph")
                    check(editor.selectedRange() == NSRange(location:at+suffix.utf16.count,length:0) && session.buffer.selection == EditSelection(sourceEnd+suffix.utf8.count,sourceEnd+suffix.utf8.count),"native Space caret advances within its paragraph")
                }
                settle()
                let changed = session.buffer.source
                check(editor.selectedRange() == NSRange(location:at+3,length:0) && session.buffer.projection.blocks[index].text == block.text+"  x","background reference formatting retains spaces and caret")
                session.switchMode(.source)
                wait("Source shows exact Space insertion") { editor.string == changed }
                session.undo(); check(session.buffer.source == before && session.buffer.selection == selected,"shared Source Undo restores exact paragraph source and caret")
                session.undo(true); check(session.buffer.source == changed,"shared Source Redo restores spaces and continued typing")
                session.switchMode(.write)
                wait("Write restores the exact Space caret") { editor.selectedRange() == NSRange(location:at+3,length:0) && editor.string == session.buffer.projection.text }
            }
        }

        // Deleting a sole citation leaves a real, editable paragraph slot.
        let sole = inserted.replacingOccurrences(of:"Citation here",with:"")
        session.buffer.loadExternal(""); session.buffer.loadExternal(sole); session.revision += 1; editor.refresh(); session.compile()
        wait("sole citation is formatted",seconds:20) { !session.compiling && session.buffer.renderedReferences.contains { $0.kind == "citation" } }
        let citation = session.buffer.renderedReferences.first { $0.kind == "citation" }!
        let start = session.buffer.projection.displayOffset(at:citation.source.start), end = session.buffer.projection.displayOffset(at:citation.source.end)
        editor.setSelectedRange(NSRange(location:start,length:end-start)); editor.captureSelection(); key(117,"\u{F728}")
        check(!session.buffer.source.contains("#cite("),"native forward Delete removes the sole citation")
        let empty = session.buffer.projection.blocks.first { $0.kind == "paragraph" && $0.text.isEmpty }!
        editor.setSelectedRange(NSRange(location:empty.display.location,length:0)); editor.captureSelection(); session.buffer.breakUndoGroup()
        let beforeEmpty = session.buffer.source, emptySelection = session.buffer.selection
        key(49," ")
        check(session.buffer.source == beforeEmpty.replacingBytes(emptySelection.span,with:" ") && editor.selectedRange() == NSRange(location:empty.display.location+1,length:0),"Space advances inside the paragraph left by sole-citation deletion")
        settle()
        check(editor.selectedRange() == NSRange(location:empty.display.location+1,length:0),"empty citation paragraph retains its Space caret after reformatting")
        key(7,"x")
        let changedEmpty = beforeEmpty.replacingBytes(emptySelection.span,with:" x")
        check(session.buffer.source == changedEmpty && session.buffer.projection.blocks.contains { $0.kind == "paragraph" && $0.text == " x" } && editor.selectedRange() == NSRange(location:empty.display.location+2,length:0),"Space followed by typing remains literal in the empty citation paragraph")
        session.undo(); check(session.buffer.source == beforeEmpty && session.buffer.selection == emptySelection,"empty paragraph Space has exact source and caret Undo")
        session.undo(true); check(session.buffer.source == changedEmpty && editor.selectedRange() == NSRange(location:empty.display.location+2,length:0),"empty paragraph Space and continued typing have exact Redo")

        let cellSource = "// Keep table options\n#table(columns:1,inset:8pt,[Café 👩🏽‍💻\n\nNext])\n\n"+inserted
        for backward in [false,true] {
            session.buffer.loadExternal(""); session.buffer.loadExternal(cellSource); session.revision += 1; editor.refresh()
            let tableIndex = session.buffer.projection.blocks.firstIndex { $0.kind == "table" }!, table = session.buffer.projection.blocks[tableIndex]
            editor.focusTableCell(tableIndex,0)
            let at = table.display.location+table.cellRanges[0].location+NSMaxRange(table.cellProjections[0].blocks[0].display)
            editor.setSelectedRange(NSRange(location:at,length:0)); editor.captureSelection(); session.buffer.breakUndoGroup()
            let selected = session.buffer.selection
            key(49," ")
            let spaced = cellSource.replacingBytes(selected.span,with:" ")
            check(session.buffer.source == spaced && editor.selectedRange() == NSRange(location:at+1,length:0),"native table paragraph Space preserves options, source and caret")
            session.buffer.breakUndoGroup()
            if !backward { editor.setSelectedRange(NSRange(location:at,length:1)); editor.captureSelection() }
            key(backward ? 51 : 117,backward ? "\u{7f}" : "\u{F728}")
            check(session.buffer.source == cellSource && editor.selectedRange() == NSRange(location:at,length:0),"native table Delete removes only its inserted Space (backward=\(backward))")
            session.undo(); check(session.buffer.source == spaced && editor.selectedRange() == NSRange(location:backward ? at+1 : at,length:backward ? 0 : 1),"native table Space deletion shares exact source and selection Undo")
            session.undo(true); check(session.buffer.source == cellSource && editor.selectedRange() == NSRange(location:at,length:0),"native table Space deletion shares exact source and caret Redo")
        }
    }
}
