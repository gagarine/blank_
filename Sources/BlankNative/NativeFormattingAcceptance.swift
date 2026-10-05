import AppKit
import BlankCore

@MainActor enum NativeFormattingAcceptance {
    static func run(controller: DocumentWindow) {
        let session = controller.session, editor = session.editor!
        func check(_ condition: @autoclosure () -> Bool,_ label: String) {
            guard condition() else { fatalError("FAIL: \(label) | source=\(session.buffer.source)") }
            print("PASS: \(label)")
        }
        func load(_ source: String) {
            session.buffer.loadExternal(source); session.revision += 1; editor.refresh()
            editor.insertionBold = nil; editor.insertionItalic = nil
            controller.window?.makeFirstResponder(editor)
        }
        func contextMenu() -> NSMenu {
            editor.ensureNativeLayout()
            let point = editor.convert(editor.rectFor(editor.selectedRange().location).origin,to:nil)
            let event = NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:0,
                                          windowNumber:controller.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            return editor.menu(for:event)!
        }
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0]+($0.submenu.map(items) ?? []) }
        }
        func choose(_ italic: Bool) {
            let action = italic ? #selector(NativeTextView.blankItalic(_:)) : #selector(NativeTextView.blankBold(_:))
            guard let item = items(contextMenu()).first(where:{ $0.action == action }) else { fatalError("Missing native formatting menu action") }
            check(NSApp.sendAction(action,to:item.target,from:item),"Native context menu dispatches \(italic ? "Italic" : "Bold")")
        }
        let plain = "Before café 👩🏽‍💻 after // keep this comment\n"
        load(plain)
        let range = (editor.string as NSString).range(of:"café 👩🏽‍💻")
        editor.setSelectedRange(range)
        let fontMenu = contextMenu().items.compactMap(\.submenu).first { $0.items.contains { $0.action == #selector(NativeTextView.blankBold(_:)) } }
        check(fontMenu?.items.count == 2,"Native Font submenu exposes only source-backed Bold and Italic")
        choose(false)
        check(session.buffer.source == "Before *café 👩🏽‍💻* after // keep this comment\n" && editor.selectedRange() == range,"Context-menu Bold preserves Unicode, selection and untouched source")
        let font = editor.textStorage!.attribute(.font,at:range.location,effectiveRange:nil) as! NSFont
        check(NSFontManager.shared.traits(of:font).contains(.boldFontMask),"Context-menu Bold renders a real bold face")
        choose(true)
        check(session.buffer.projection.blocks[0].inlines.flatMap(\.runs).filter { $0.style.bold && $0.style.italic }.map(\.text).joined() == "café 👩🏽‍💻","Context-menu Italic composes with canonical Bold")
        let both = session.buffer.source
        session.switchMode(.source)
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(editor.string == both && !items(contextMenu()).contains { $0.action == #selector(NativeTextView.blankBold(_:)) || $0.action == #selector(NSFontManager.addFontTrait(_:)) },"Source displays exact formatting syntax without rich-font menu actions")
        let undoItem = items(NSApp.mainMenu!).first { $0.action == #selector(AppController.undo(_:)) }!
        check(NSApp.sendAction(undoItem.action!,to:undoItem.target,from:undoItem),"Native Undo menu reaches shared document history")
        check(session.buffer.source == "Before *café 👩🏽‍💻* after // keep this comment\n","Context-menu formatting shares undo with Source")
        let redoItem = items(NSApp.mainMenu!).first { $0.action == #selector(AppController.redo(_:)) }!
        check(NSApp.sendAction(redoItem.action!,to:redoItem.target,from:redoItem),"Native Redo menu reaches shared document history")
        check(session.buffer.source == both,"Context-menu formatting shares redo with Source")
        session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1)); editor.setSelectedRange(range)
        choose(true); choose(false)
        check(session.buffer.source == plain,"Repeated context-menu actions remove canonical inline marks")

        load("= Heading\n\n*Bold* and plain")
        editor.setSelectedRange(NSRange(location:0,length:7)); choose(false)
        check(session.buffer.source.hasPrefix("= *Heading*"),"Native heading face does not substitute for an inline bold mark")
        choose(false)
        check(session.buffer.source.hasPrefix("= Heading"),"Heading inline Bold toggles independently of heading typography")
        let mixed = (editor.string as NSString).range(of:"Bold and plain")
        editor.setSelectedRange(mixed); choose(false)
        let runs = session.buffer.projection.blocks[1].inlines.flatMap(\.runs)
        check(runs.allSatisfy(\.style.bold),"Mixed selection context-menu Bold applies to every selected run")

        load("Typing ")
        editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0))
        choose(true); editor.insertText("é",replacementRange:editor.selectedRange())
        check(session.buffer.projection.blocks[0].inlines.flatMap(\.runs).last?.style.italic == true && !session.buffer.parsed.erroneous,"Context-menu formatting at a caret writes canonical styled text")
        choose(true); editor.insertText(" normal",replacementRange:editor.selectedRange())
        check(session.buffer.projection.blocks[0].inlines.flatMap(\.runs).last?.style.italic == false,"Caret formatting toggles off through the context menu")

        load("#table(columns: 2, [Café 👋], [Keep])\n\nAfter // keep this comment\n")
        editor.focusTableCell(0,0); choose(false)
        check(session.buffer.source == "#table(columns: 2, [*Café 👋*], [Keep])\n\nAfter // keep this comment\n","Native table context-menu formatting edits only the selected cell source")
        session.undo()
        check(session.buffer.source == "#table(columns: 2, [Café 👋], [Keep])\n\nAfter // keep this comment\n","Native table context-menu formatting uses shared history")

        // Exercise the font-manager responder action too, independently of the
        // retargeted context menu (e.g. a system font command sent to the editor).
        load("Manager action")
        editor.selectAll(nil)
        let manager = NSFontManager.shared, oldTarget = manager.target, oldAction = manager.action
        let oldFont = manager.selectedFont, oldMultiple = manager.isMultiple
        manager.target = editor; manager.action = #selector(NSTextView.changeFont(_:))
        let trait = NSMenuItem(title:"",action:nil,keyEquivalent:"")
        trait.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
        manager.setSelectedFont(.systemFont(ofSize:18),isMultiple:false)
        manager.addFontTrait(trait)
        check(session.buffer.source == "*Manager action*","NSFontManager Bold also routes through the source transaction")
        trait.tag = Int(NSFontTraitMask.unboldFontMask.rawValue)
        manager.addFontTrait(trait)
        check(session.buffer.source == "Manager action","NSFontManager removal routes through the source transaction")
        let renderedFont = editor.textStorage!.attribute(.font,at:0,effectiveRange:nil) as! NSFont
        trait.tag = Int(NSFontAction.sizeUpFontAction.rawValue); manager.modifyFont(trait)
        check(session.buffer.source == "Manager action" && editor.textStorage!.attribute(.font,at:0,effectiveRange:nil) as? NSFont == renderedFont,"Unsupported font-manager size changes cannot diverge from the source")
        manager.target = oldTarget; manager.action = oldAction
        if let oldFont { manager.setSelectedFont(oldFont,isMultiple:oldMultiple) }
        load(""); editor.setSelectedRange(NSRange(location:0,length:0)); editor.captureSelection()
    }
}
