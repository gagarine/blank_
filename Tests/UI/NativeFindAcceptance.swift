@testable import BlankIntegrationTests
import AppKit
import PDFKit
import BlankCore
@testable import BlankNative

@MainActor enum NativeFindAcceptance {
    static func run(original: DocumentWindow) {
        let session = DocumentSession(), source = "Before café 日本👩🏽‍💻 after"
        session.buffer.loadExternal(source)
        let controller = DocumentWindow(session:session)
        AppController.shared.controllers.append(controller)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        func check(_ value: @autoclosure () -> Bool,_ label: String) {
            guard value() else { print("Find diagnostic: visible=\(session.searchVisible) request=\(session.searchFocusRequest) item=\(controller.searchItem != nil) fieldWindow=\(controller.searchItem?.searchField.window === controller.window) responder=\(String(describing:controller.window?.firstResponder)) width=\(controller.searchWidth?.constant as Any) active=\(NSApp.isActive) key=\(controller.window?.isKeyWindow == true)"); fatalError("FAIL: Find lifecycle: \(label) | source=\(session.buffer.source)") }
            print("PASS: Find lifecycle: \(label)")
        }
        func pump(until deadline: Date) {
            for _ in 0..<32 {
                guard Date() < deadline, let event = NSApp.nextEvent(matching:.any,until:Date(),inMode:.default,dequeue:true) else { break }
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until:Date().addingTimeInterval(0.01))
        }
        func wait(_ label: String,_ ready: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !ready() && Date() < deadline { pump(until:deadline) }
            check(ready(),label)
        }
        func settle() {
            let deadline = Date().addingTimeInterval(0.2)
            while Date() < deadline { pump(until:deadline) }
        }
        defer {
            session.saveWork?.cancel(); session.watchers.forEach { $0.cancel() }; session.recoveryQueue.sync {}
            session.dirty = false; controller.nativeDocument.updateChangeCount(.changeCleared)
            controller.window?.close(); original.window?.makeKeyAndOrderFront(nil)
            original.window?.makeFirstResponder(original.session.editor)
        }
        NSApp.activate(ignoringOtherApps:true)
        wait("disposable document is active and key") { NSApp.isActive && controller.window?.isKeyWindow == true && session.editor != nil }
        // Complete the fresh window's queued mounting and activation events before
        // testing commands; subsequent transitions must manage their own focus.
        let setupDeadline = Date().addingTimeInterval(3)
        pump(until:setupDeadline)
        NSApp.activate(ignoringOtherApps:true); controller.window?.makeKeyAndOrderFront(nil)
        wait("native toolbar is mounted in the active document") {
            NSApp.isActive && controller.window?.isKeyWindow == true &&
            controller.searchItem?.searchField.window === controller.window &&
            controller.searchItem?.searchField.bounds.isEmpty == false && AppController.shared.current === session
        }
        var editor: NativeTextView { session.editor! }
        controller.window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0)); editor.captureSelection()
        editor.insertText("!",replacementRange:editor.selectedRange())
        let edited = session.buffer.source, undoID = session.buffer.undoID
        let selection = session.buffer.selection
        let query = "café 日本👩🏽‍💻"
        func fieldEditor() -> NSTextView? {
            guard let field = controller.searchItem?.searchField.currentEditor() as? NSTextView,
                  field.isFieldEditor, controller.window?.firstResponder === field else { return nil }
            return field
        }
        func openFind() {
            check(AppController.shared.current === session,"Find targets the disposable document")
            AppController.shared.find(nil)
            wait("native Find owns focus") { fieldEditor() != nil }
        }
        func checkQuerySelection(_ label: String) {
            check(fieldEditor()?.string == query && fieldEditor()?.selectedRange() == NSRange(location:0,length:query.utf16.count),label)
        }
        func escapeFind() {
            let field = fieldEditor()!
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                                        windowNumber:controller.window!.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
            field.keyDown(with:event)
            wait("native Escape closes Find") { !session.searchVisible && controller.window?.firstResponder === (session.mode == .preview ? session.pdfView : session.editor) }
            settle()
            check(!session.searchVisible && session.searchQuery == query && session.buffer.source == edited && session.buffer.selection == selection && session.buffer.undoID == undoID,"Escape preserves query, exact Unicode source, caret and history")
        }
        openFind()
        let input = fieldEditor()!
        input.selectAll(nil); input.insertText(query,replacementRange:input.selectedRange())
        wait("native input propagates the Unicode query") { session.searchQuery == query }
        controller.window?.makeFirstResponder(editor)
        openFind(); checkQuerySelection("Cmd-F from the document selects the complete UTF-16 query")
        openFind(); checkQuerySelection("Cmd-F within Find selects the complete query without restarting interaction")
        escapeFind()

        openFind(); session.hideSearch(); AppController.shared.find(nil)
        wait("rapid Close and reopen keeps native Find focus") { session.searchVisible && fieldEditor() != nil }
        settle(); checkQuerySelection("rapid reopen keeps the query selected")
        escapeFind()
        AppController.shared.find(nil); session.hideSearch()
        settle()
        wait("Close before focus completion cannot reclaim document focus") { !session.searchVisible && controller.window?.firstResponder === editor }

        if let toolbar = controller.window?.toolbar,
           let index = toolbar.items.firstIndex(where:{ $0.itemIdentifier == .blankSearch }) {
            toolbar.removeItem(at:index)
            openFind()
            check(toolbar.items.contains(where:{ $0.itemIdentifier == .blankSearch }) && controller.searchItem?.searchField.window === controller.window,"Cmd-F restores a customized-away native Search item")
            checkQuerySelection("restored Search selects the retained Unicode query")
            escapeFind()
        } else { check(false,"fixture contains the native Search item before customization") }

        openFind(); session.hideSearch(); session.sheet = .commands
        wait("Commands receives its native field editor after closing Find") { (controller.window?.attachedSheet?.firstResponder as? NSTextView)?.isFieldEditor == true }
        let sheet = controller.window!.attachedSheet!, sheetFocus = sheet.firstResponder
        settle(); check(sheet.firstResponder === sheetFocus && controller.window?.attachedSheet === sheet,"late Find focus cannot steal Commands focus")
        session.sheet = nil
        wait("Commands dismissal returns to the document") { controller.window?.attachedSheet == nil && controller.window?.firstResponder === editor }

        openFind(); session.showContactSheet()
        wait("Contact Sheet receives native collection focus") { session.contactSheet && controller.window?.firstResponder is NSCollectionView }
        settle(); check(controller.window?.firstResponder is NSCollectionView && !session.searchVisible,"late Find focus cannot steal Contact Sheet focus")
        session.closeContactSheet()
        wait("Contact Sheet dismissal returns to the editor") { controller.window?.firstResponder === editor }

        openFind(); session.hideSearch(); NSApp.activate(ignoringOtherApps:true); original.window?.makeKeyAndOrderFront(nil)
        wait("another document remains key after Find closes") { original.window?.isKeyWindow == true }
        settle(); check(original.window?.isKeyWindow == true && AppController.shared.current === original.session,"late Find focus cannot activate the previous document")
        NSApp.activate(ignoringOtherApps:true); controller.window?.makeKeyAndOrderFront(nil)
        wait("disposable document becomes key again") { controller.window?.isKeyWindow == true }
        session.switchMode(.source)
        wait("Source projection is ready") { editor.string == session.buffer.source }
        openFind(); checkQuerySelection("Source Find selects its retained query")
        escapeFind()

        session.compile()
        let compileDeadline = Date().addingTimeInterval(15)
        while session.pdf == nil && session.compiling && Date() < compileDeadline { pump(until:compileDeadline) }
        check(session.pdf != nil,"official compiler supplies the Preview fixture")
        session.switchMode(.preview)
        wait("Preview native view is mounted") { session.pdfView?.window === controller.window }
        check(controller.window?.makeFirstResponder(session.pdfView) == true,"Preview fixture accepts native PDF focus")
        openFind(); checkQuerySelection("Preview Find selects its retained query")
        escapeFind()
        check(controller.window?.firstResponder === session.pdfView,"closing Preview Find restores PDF focus")
        check(session.buffer.source == edited && session.buffer.selection == selection && session.buffer.undoID == undoID,"Find lifecycle leaves canonical source, selection and history intact")
        // Leaving Preview deliberately maps its reading position back to source.
        // Verify that separate navigation selection survives native remounting.
        session.switchMode(.write)
        let readingSelection = session.buffer.selection
        wait("Write focus returns after Preview") { session.editor != nil && controller.window?.firstResponder === session.editor }
        check(session.buffer.source == edited && session.buffer.selection == readingSelection && session.buffer.undoID == undoID,"Preview navigation preserves exact source and shared history")
        check(editor.selectedRange().length == 0 && session.buffer.projection.sourceOffset(at:editor.selectedRange().location) == readingSelection.focus,"remounted Write caret matches the Preview navigation destination")
        AppController.shared.undo(nil); check(session.buffer.source == source,"shared Undo retains the native edit before Find")
        AppController.shared.redo(nil); check(session.buffer.source == edited,"shared Redo restores that edit exactly")
    }
}
