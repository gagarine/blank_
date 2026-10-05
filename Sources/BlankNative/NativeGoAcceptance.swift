import AppKit
import PDFKit
import BlankCore

@MainActor enum NativeGoAcceptance {
    private static func check(_ condition: @autoclosure () -> Bool,_ label: String) {
        guard condition() else { fatalError("FAIL: \(label)") }; print("PASS: \(label)")
    }
    static func text(original: DocumentWindow) {
        let session = DocumentSession()
        let source = "= First 🐈\n\nA café paragraph.\n\n== Second\n\n"+String(repeating:"Long paragraph for scrolling.\n\n",count:90)+"== Last\n\nEnd."
        session.buffer.loadExternal(source)
        let controller = DocumentWindow(session:session)
        AppController.shared.controllers.append(controller)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        defer { controller.window?.close(); original.window?.makeKeyAndOrderFront(nil) }
        RunLoop.main.run(until:Date().addingTimeInterval(0.15))
        guard let editor = session.editor else { fatalError("Missing Go test editor") }
        let second = session.headings[1].1.body.start
        let start = session.headings[0].1.body.start
        session.buffer.selection = EditSelection(start,start); editor.refresh(reveal:true)
        check(!session.canNavigate(.page) && !session.canNavigate(.previousItem),"Go disables page jumps and previous section at the start of Write")
        let arrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        func key(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:arrow,charactersIgnoringModifiers:arrow,isARepeat:false,keyCode:125)!
        }
        check(!NSApp.mainMenu!.performKeyEquivalent(with:key([])) && !NSApp.mainMenu!.performKeyEquivalent(with:key([.option])),"Go leaves ordinary arrows and Option-arrow editing shortcuts to the native editor")
        NSApp.mainMenu?.update()
        check(NSApp.mainMenu!.performKeyEquivalent(with:key([.command,.option])),"Command-Option-arrow invokes native Go Next Item")
        check(session.buffer.selection == EditSelection(second,second) && session.canNavigate(.back),"Go Next Item jumps to the next heading without editing")
        session.navigate(.back)
        check(session.buffer.selection == EditSelection(start,start) && session.canNavigate(.forward),"Go Back restores the native source selection")
        session.switchMode(.source); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        session.navigate(.forward)
        check(session.buffer.selection.focus == second && editor.selectedRange().location == source.utf16Offset(byte:second),"Go Forward survives Write/Source switching and Unicode position mapping")
        check(!session.canNavigate(.page),"Go to Page stays disabled in Source")
        session.navigate(.previousItem)
        check(session.buffer.selection.focus == start,"Source Previous Item navigates headings")
        editor.enclosingScrollView?.contentView.scroll(to:.zero)
        check(!session.canNavigate(.up) && session.canNavigate(.down),"Go scrolling validates the document edges")
        let selection = editor.selectedRange()
        session.navigate(.down)
        check(editor.visibleRect.minY > 0 && editor.selectedRange() == selection,"Go Down scrolls a viewport while preserving the editing selection")
        session.navigate(.up)
        check(editor.visibleRect.minY < 1,"Go Up returns to the previous viewport")
        check(session.buffer.source == source && !session.buffer.canUndo && !session.dirty,"Navigation leaves canonical source and edit history untouched")
        session.buffer.editSource(NSRange(location:0,length:0),text:"// changed\n"); session.changed()
        check(!session.canNavigate(.back) && !session.canNavigate(.forward),"Source edits invalidate obsolete navigation anchors")
        session.saveWork?.cancel()
        // Do not leave a dirty test document or a save/recovery prompt.
        session.dirty = false; controller.nativeDocument.updateChangeCount(.changeCleared)
    }
    static func preview(controller: DocumentWindow) {
        let session = controller.session
        guard let pdf = session.pdf, let view = session.pdfView else { fatalError("Missing Go PDF fixture") }
        check(session.canNavigate(.page),"Go to Page is enabled for a multipage Preview")
        // In continuous mode PDFKit's currentDestination can refer to the
        // trailing edge of the preceding page while currentPage is the next.
        // Use native single-page display for an unambiguous page-history check.
        let display = session.previewDisplayMode
        session.previewDisplayMode = .single
        view.displayMode = .singlePage
        view.layoutDocumentView()
        defer { session.previewDisplayMode = display; view.displayMode = display.pdfMode }
        session.goPage(1); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(!session.canNavigate(.previousItem) && session.canNavigate(.nextItem),"PDF Go menu validates first-page navigation")
        let source = session.buffer.source
        session.navigate(.nextItem); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(session.previewPage == 2 && !session.canNavigate(.nextItem),"Go Next Item uses PDFKit page navigation and disables at the last page")
        check(session.canNavigate(.back),"PDFKit supplies native Go history")
        session.navigate(.back); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(session.previewPage == 1 && session.canNavigate(.forward),"PDF Go Back returns to the prior page")
        session.navigate(.forward); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(session.previewPage == 2 && session.buffer.source == source,"PDF Go Forward restores the page without editing source (page: \(session.previewPage), native: \(view.currentPage.map { pdf.index(for:$0)+1 } ?? 0))")
        let single = PDFDocument(data:pdf.dataRepresentation()!)!
        while single.pageCount > 1 { single.removePage(at:single.pageCount-1) }
        session.pdf = single; view.document = single
        check(!session.canNavigate(.page),"Go to Page is disabled for a single-page PDF")
        session.pdf = pdf; view.document = pdf; session.goPage(2)
        session.sheet = .settings
        check(!session.canNavigate(.page) && !session.canNavigate(.previousItem),"Go actions are disabled while a sheet owns input")
        session.sheet = nil
        let go = NSApp.mainMenu!.items.first { $0.title == "Go" }!.submenu!
        check(go.items.map(\.title) == ["Up","Down","Previous Item","Next Item","Go to Page…","","Back","Forward"],"Native Go menu contains the Preview-style navigation commands")
        let page = go.items.first { $0.title == "Go to Page…" }!
        check(AppController.shared.validateMenuItem(page),"Native menu validation enables a multipage jump")
        session.mode = .source
        check(!AppController.shared.validateMenuItem(page),"Native menu validation grays out Go to Page outside Preview")
        session.mode = .preview
    }
}
