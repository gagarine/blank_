import AppKit
import BlankCore

@MainActor enum NativeLabelAcceptance {
    static func check(_ condition: @autoclosure () -> Bool,_ label: String) {
        guard condition() else { fatalError("FAIL: \(label)") }; print("PASS: \(label)")
    }
    static func run(controller original: DocumentWindow) {
        let session = DocumentSession(), controller = DocumentWindow(session:session)
        AppController.shared.controllers.append(controller)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        defer {
            session.saveWork?.cancel(); session.dirty = false
            controller.nativeDocument.updateChangeCount(.changeCleared); controller.window?.close()
            original.window?.makeKeyAndOrderFront(nil)
        }
        let board = NSPasteboard.general
        let clipboard = board.pasteboardItems?.map { item in Dictionary(uniqueKeysWithValues:item.types.compactMap { type in item.data(forType:type).map { (type,$0) } }) } ?? []
        defer {
            board.clearContents()
            board.writeObjects(clipboard.map { contents -> NSPasteboardItem in let item = NSPasteboardItem(); for (type,data) in contents { item.setData(data,forType:type) }; return item })
        }
        let fixture = "= Café 👩🏽‍💻 <intro>\n\nText <note> and *bold <strong-tag>* and `code <raw-tag>` and \\<escaped\\>.\n\n- Item <list-tag>\n\n#table(columns: 1, [日本 <cell-tag>], [<next-cell>])\n\n#let hidden = [Hidden <code-tag>]\n#ref(<reference-tag>)"
        session.buffer.loadExternal(fixture)
        let revision = session.buffer.revision, selection = session.buffer.selection
        session.editor?.refresh(reveal:true)
        var editor: NativeTextView { session.editor! }
        func range(_ text: String) -> NSRange {
            let range = (editor.string as NSString).range(of:text)
            check(range.location != NSNotFound,"Fixture retains visible \(text)"); return range
        }
        func color(_ text: String,_ offset: Int = 0) -> NSColor? {
            editor.layoutManager?.temporaryAttribute(.backgroundColor,atCharacterIndex:range(text).location+offset,effectiveRange:nil) as? NSColor
        }
        for label in ["<intro>","<note>","<strong-tag>","<list-tag>","<cell-tag>","<next-cell>"] {
            check(color(label) == .quaternaryLabelColor,"Write distinguishes literal \(label) with a display-only tag background")
        }
        for text in ["<raw-tag>","<escaped>","<code-tag>","<reference-tag>"] {
            check(color(text) == nil,"Code, escapes and label-valued expressions retain their existing appearance: \(text)")
        }
        check(session.buffer.source.utf8.elementsEqual(fixture.utf8) && session.buffer.revision == revision && session.buffer.selection == selection && !session.buffer.canUndo && !session.dirty,"Rendering label backgrounds does not change source, selection, history or dirty state")
        editor.setSelectedRange(range("<note>")); editor.copy(nil)
        check(board.string(forType:.string) == "<note>","Plain copy still includes the selected literal label")
        let fragment = try! JSONDecoder().decode(RichFragment.self,from:board.data(forType:NSPasteboard.PasteboardType("local.blank.typst-fragment"))!)
        let pasted = DocumentBuffer(); pasted.paste(fragment,range:NSRange(location:0,length:0))
        check(pasted.source == "<note>" && fragment.source == "<note>","Structured clipboard preserves the same literal label source")
        let rich = try! NSAttributedString(data:board.data(forType:.rtf)!,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
        check(rich.string == "<note>" && rich.attribute(.backgroundColor,at:0,effectiveRange:nil) == nil && editor.textStorage?.attribute(.backgroundColor,at:range("<note>").location,effectiveRange:nil) == nil,"Display-only label decoration stays out of RTF and native text storage")
        func search(_ query: String) {
            session.searchVisible = true; session.searchQuery = query
            session.searchController.update(revealFirst:false)
            let deadline = Date().addingTimeInterval(5)
            while session.searchController.searching && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
            check(!session.searchController.searching,"Native label search completes")
        }
        search("note")
        check(color("<note>") == .quaternaryLabelColor && color("<note>",1) == NSColor.systemYellow.withAlphaComponent(0.8),"Find overlays only the matched part of a label")
        search("")
        check(color("<note>",1) == .quaternaryLabelColor,"Empty Find restores the tag background")
        search("absent-label")
        check(color("<note>") == .quaternaryLabelColor,"Zero-result Find retains tag decoration")
        session.searchQuery = "intro"; session.searchQuery = "note"
        let deadline = Date().addingTimeInterval(5)
        while session.searchController.searching && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(color("<intro>",1) == .quaternaryLabelColor && color("<note>",1) == NSColor.systemYellow.withAlphaComponent(0.8),"Rapid Find queries reject stale highlights")
        session.hideSearch()
        check(color("<note>",1) == .quaternaryLabelColor && editor.layoutManager?.temporaryAttribute(.foregroundColor,atCharacterIndex:range("<note>").location+1,effectiveRange:nil) == nil,"Closing Find restores the background and clears search text color")
        session.switchMode(.source)
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(editor.string.utf8.elementsEqual(fixture.utf8) && color("<note>") == nil,"Source retains exact characters without Write tag backgrounds")
        editor.selectAll(nil); editor.copy(nil)
        check(board.string(forType:.string)?.utf8.elementsEqual(fixture.utf8) == true,"Source clipboard remains byte-exact")
        session.switchMode(.write)
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(color("<note>") == .quaternaryLabelColor,"Returning to Write restores tag decoration")

        let local = "Café <first>\n\n日本 <later>\n\n#table(columns: 1, [Cell <cell>], [Other])"
        session.buffer.loadExternal(local); editor.refresh(reveal:true)
        editor.setSelectedRange(NSRange(location:0,length:0)); editor.captureSelection()
        editor.insertText("👩🏽‍💻 ",replacementRange:editor.selectedRange())
        check(session.buffer.lastEditWasLocal && color("<first>") == .quaternaryLabelColor && color("<later>") == .quaternaryLabelColor && color("<cell>") == .quaternaryLabelColor,"Local Unicode typing shifts downstream label and native-table decoration")
        let shifted = session.buffer.source
        editor.setSelectedRange(range("first")); editor.captureSelection(); editor.insertText("renamed",replacementRange:editor.selectedRange())
        check(session.buffer.lastEditWasLocal && color("<renamed>") == .quaternaryLabelColor,"Label text stays natively editable through a local reparse")
        session.undo(); check(session.buffer.source == shifted && color("<first>") == .quaternaryLabelColor,"Label text Undo restores source and decoration")
        session.undo(true); check(color("<renamed>") == .quaternaryLabelColor,"Label text Redo restores decoration")
        session.undo(); session.undo()
        check(session.buffer.source.utf8.elementsEqual(local.utf8) && color("<cell>") == .quaternaryLabelColor,"Unicode Undo restores exact original source and table mapping")
        let closing = (session.buffer.source as NSString).range(of:"<later>")
        session.buffer.editSource(NSRange(location:NSMaxRange(closing)-1,length:1),text:"",group:""); editor.refresh()
        check(color("<later") == nil,"Breaking a label delimiter removes decoration")
        session.undo(); check(color("<later>") == .quaternaryLabelColor,"Restoring valid syntax restores decoration")
        editor.setSelectedRange(NSRange(location:range("<cell>").location,length:0)); editor.captureSelection()
        editor.insertText("Paragraph\n",replacementRange:editor.selectedRange())
        check(color("<cell>") == .quaternaryLabelColor && session.buffer.source.contains("Paragraph"),"A native cell paragraph keeps its label background mapped")
        session.undo(); check(session.buffer.source == local,"Native cell paragraph Undo keeps exact Typst options and labels")
        editor.setSelectedRange(NSRange(location:0,length:0)); editor.captureSelection()
        editor.setMarkedText("日本",selectedRange:NSRange(location:2,length:0),replacementRange:editor.selectedRange())
        session.searchController.clearHighlights()
        check(editor.hasMarkedText() && session.buffer.source == local,"Refreshing decoration does not finish active composition or edit source")
        editor.unmarkText(); editor.refresh(reveal:true)
        check(color("<first>") == .quaternaryLabelColor && color("<cell>") == .quaternaryLabelColor,"Finishing native composition restores current label decoration")
        let originalPath = session.active
        session.buffers["other.typ"] = DocumentBuffer("Other <other>")
        session.active = "other.typ"; session.searchController.clearHighlights()
        check(color("<first>") == nil,"A pending file switch does not decorate the old editor with new model ranges")
        editor.refresh(reveal:true); check(color("<other>") == .quaternaryLabelColor,"Refreshing the new file uses its own label spans")
        session.switchFile(originalPath); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(color("<first>") == .quaternaryLabelColor && color("<cell>") == .quaternaryLabelColor,"Returning to the original file restores its label decoration")
    }
}
