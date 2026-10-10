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
            editor.clearInsertionStyle()
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
        check(fontMenu?.items.count == 4,"Native Font submenu exposes source-backed Bold, Italic, Underline and Strikethrough")
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
        decorations(controller:controller)
        codeBlocks(controller:controller)
        load(""); editor.setSelectedRange(NSRange(location:0,length:0)); editor.captureSelection()
    }
    static func decorations(controller: DocumentWindow) {
        let session = controller.session, editor = session.editor!
        func check(_ condition: @autoclosure () -> Bool,_ label: String) {
            guard condition() else { fatalError("FAIL: \(label) | source=\(session.buffer.source)") }; print("PASS: \(label)")
        }
        func load(_ source: String) { session.buffer.loadExternal(""); session.buffer.loadExternal(source); session.revision += 1; editor.clearInsertionStyle(); editor.refresh(); controller.window?.makeFirstResponder(editor) }
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0]+($0.submenu.map(items) ?? []) } }
        func context(_ action: Selector) {
            editor.ensureNativeLayout()
            let point = editor.convert(editor.rectFor(editor.selectedRange().location).origin,to:nil)
            let event = NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            guard let menu = editor.menu(for:event), let item = items(menu).first(where:{ $0.action == action }) else { fatalError("Missing decoration context action") }
            check(NSApp.sendAction(action,to:item.target,from:item),"Native decoration context menu dispatches its source action")
        }
        let underline = items(NSApp.mainMenu!).first { $0.action == #selector(AppController.underline(_:)) }!
        let strike = items(NSApp.mainMenu!).first { $0.action == #selector(AppController.strikethrough(_:)) }!
        check(underline.title == "Underline" && underline.keyEquivalent == "u" && strike.title == "Strikethrough","Format exposes both decorations with Command-U for Underline")
        let original = "Before *café 👩🏽‍💻* and _日本_ after // Keep\n"
        load(original)
        let range = (editor.string as NSString).range(of:"café 👩🏽‍💻")
        editor.setSelectedRange(range); editor.captureSelection()
        context(#selector(NativeTextView.blankUnderline(_:)))
        NSApp.sendAction(strike.action!,to:strike.target,from:strike)
        let decorated = session.buffer.source
        check(decorated == original.replacingOccurrences(of:"*café 👩🏽‍💻*",with:"#strike[#underline[*café 👩🏽‍💻*]]") && editor.selectedRange() == range,"Decoration menus compose with Bold and preserve Unicode selection and surrounding source")
        func hasDecorations(_ at: Int) -> Bool {
            editor.textStorage!.attribute(.underlineStyle,at:at,effectiveRange:nil) as? Int == NSUnderlineStyle.single.rawValue && editor.textStorage!.attribute(.strikethroughStyle,at:at,effectiveRange:nil) as? Int == NSUnderlineStyle.single.rawValue
        }
        check(hasDecorations(range.location),"Write renders real native underline and strikethrough attributes")
        editor.copy(nil)
        let board = NSPasteboard.general, rich = board.data(forType:.rtf)!, fragment = board.data(forType:NSPasteboard.PasteboardType("local.blank.typst-fragment"))!
        load("Paste here")
        editor.setSelectedRange(NSRange(location:5,length:0)); editor.captureSelection(); editor.paste(nil)
        check(session.buffer.source.contains("#strike[#underline[*café 👩🏽‍💻*]]") && hasDecorations(5),"Structured native clipboard retains both decorations at a mid-paragraph caret")
        load("")
        board.clearContents(); board.setData(rich,forType:.rtf)
        editor.setSelectedRange(NSRange(location:0,length:0)); editor.captureSelection(); editor.paste(nil)
        check(editor.string == "café 👩🏽‍💻" && hasDecorations(0) && !session.buffer.parsed.erroneous,"External RTF paste preserves underline and strikethrough as Typst styles")
        board.clearContents(); board.setData(fragment,forType:NSPasteboard.PasteboardType("local.blank.typst-fragment")); board.setData(rich,forType:.rtf)
        load(original); editor.setSelectedRange(range); editor.captureSelection()
        NSApp.sendAction(underline.action!,to:underline.target,from:underline)
        context(#selector(NativeTextView.blankStrikethrough(_:)))
        session.switchMode(.source); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(editor.string == decorated && hasDecorations((editor.string as NSString).range(of:"café").location),"Source retains every decoration expression with native style attributes")
        session.undo(); session.undo(); check(session.buffer.source == original,"Decoration actions share exact-source Undo across modes")
        session.undo(true); session.undo(true); check(session.buffer.source == decorated,"Decoration actions share Redo across modes")
        NSApp.sendAction(underline.action!,to:underline.target,from:underline)
        check(session.buffer.source == decorated && !AppController.shared.validateMenuItem(underline),"Source disables rich-format commands without changing source")
        session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1)); editor.setSelectedRange(range)
        context(#selector(NativeTextView.blankStrikethrough(_:))); context(#selector(NativeTextView.blankUnderline(_:)))
        check(session.buffer.source == original,"Repeated decoration commands remove only their own marks")
        load("Typing "); editor.setSelectedRange(NSRange(location:7,length:0)); editor.captureSelection()
        let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:"u",charactersIgnoringModifiers:"u",isARepeat:false,keyCode:32)!
        editor.keyDown(with:event); context(#selector(NativeTextView.blankStrikethrough(_:)))
        editor.setMarkedText("日本👩🏽‍💻",selectedRange:NSRange(location:9,length:0),replacementRange:editor.selectedRange()); editor.unmarkText()
        check(session.buffer.source == "Typing #strike[#underline[日本👩🏽‍💻]]" && hasDecorations(7),"Command-U and caret Strikethrough survive native marked-text composition")
        context(#selector(NativeTextView.blankUnderline(_:))); context(#selector(NativeTextView.blankStrikethrough(_:)))
        editor.insertText(" normal",replacementRange:editor.selectedRange())
        check(session.buffer.projection.blocks[0].inlines.flatMap(\.runs).last.map { !$0.style.underline && !$0.style.strikethrough } == true,"Caret decorations toggle off before ordinary typing")
        load("#table(columns: 2, inset: 8pt, [Café 👋], [Keep])\n\nAfter // Keep\n")
        let tableSource = session.buffer.source
        editor.focusTableCell(0,0); context(#selector(NativeTextView.blankUnderline(_:))); context(#selector(NativeTextView.blankStrikethrough(_:)))
        check(session.buffer.source == tableSource.replacingOccurrences(of:"[Café 👋]",with:"[#strike[#underline[Café 👋]]]") && hasDecorations(0),"Native table menus decorate only the selected cell and retain table options")
        session.undo(); session.undo(); check(session.buffer.source == tableSource,"Table decorations retain shared Undo and exact surrounding source")
        for backward in [false,true] {
            let source = "Before #strike[#underline[*Café 日本 👩🏽‍💻*]] after\n\nNext"
            load(source)
            let selected = (editor.string as NSString).range(of:"日本 👩🏽‍💻")
            editor.setSelectedRange(selected); editor.captureSelection()
            let before = session.buffer.selection
            let key = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:backward ? "\u{7f}" : "\u{f728}",charactersIgnoringModifiers:backward ? "\u{7f}" : "\u{f728}",isARepeat:false,keyCode:backward ? 51 : 117)!
            editor.keyDown(with:key)
            let changed = source.replacingOccurrences(of:"日本 👩🏽‍💻",with:""), after = session.buffer.selection
            check(session.buffer.source == changed && editor.selectedRange() == NSRange(location:selected.location,length:0),"Native Backspace/forward Delete inside decorated Unicode text preserves wrappers, neighbors and caret")
            session.undo(); check(session.buffer.source == source && session.buffer.selection == before,"Decorated native Delete restores exact source and selection with Undo")
            session.undo(true); check(session.buffer.source == changed && session.buffer.selection == after,"Decorated native Delete restores exact source and caret with Redo")
        }
    }
    static func codeBlocks(controller: DocumentWindow) {
        let session = controller.session, editor = session.editor!
        func check(_ condition: @autoclosure () -> Bool,_ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }; print("PASS: \(label)")
        }
        let priorDefaults = editor.inputDefaults, prior = NativeInputDefaults(editor)
        defer { editor.inputDefaults = priorDefaults; prior.apply(to:editor,source:false) }
        editor.isAutomaticQuoteSubstitutionEnabled = true; editor.isAutomaticDashSubstitutionEnabled = true
        editor.isAutomaticTextReplacementEnabled = true; editor.isContinuousSpellCheckingEnabled = true
        editor.inputDefaults = NativeInputDefaults(editor)
        let raw = "#{\n  let café = \"日本 👋\"\n  let count = 42\n  text(café) // keep\n}"
        let original = "Before 👩🏽‍💻\n\n"+raw+"\n\nAfter"
        func load() { session.buffer.loadExternal(original); session.revision += 1; editor.refresh() }
        func range(_ text: String) -> NSRange { (editor.string as NSString).range(of:text) }
        func color(_ text: String) -> NSColor? { editor.textStorage?.attribute(.foregroundColor,at:range(text).location,effectiveRange:nil) as? NSColor }
        load()
        check(color("let") == .systemPurple && color("42") == .systemOrange && color("\"日本 👋\"") == .systemGreen && color("text(café)") == .systemPurple && color("// keep") == .secondaryLabelColor,"Write code blocks use parser-backed keyword, number, string, function and comment colors")
        check(color("Before") == session.inkColor && color("After") == session.inkColor && session.buffer.source == original,"Code coloring preserves neighboring prose and canonical source")
        let opening = range("#{"), closing = range("}")
        for part in [NSRange(location:opening.location,length:1),NSRange(location:opening.location+1,length:1),closing] {
            editor.setSelectedRange(part); editor.deleteBackward(nil)
            check(session.buffer.source == original,"Write prevents deleting an individual code delimiter")
            editor.setSelectedRange(part); editor.insertText("replacement",replacementRange:editor.selectedRange())
            check(session.buffer.source == original,"Write prevents replacing an individual code delimiter")
        }
        editor.setSelectedRange(opening)
        editor.setMarkedText("日本",selectedRange:NSRange(location:2,length:0),replacementRange:editor.selectedRange())
        check(!editor.hasMarkedText() && session.buffer.source == original,"Composition cannot replace the structural code opener")
        editor.setSelectedRange(NSRange(location:range("café").location,length:0))
        editor.textViewDidChangeSelection(Notification(name:NSTextView.didChangeSelectionNotification,object:editor))
        check(!editor.isAutomaticQuoteSubstitutionEnabled && !editor.isAutomaticDashSubstitutionEnabled && !editor.isAutomaticTextReplacementEnabled && !editor.isContinuousSpellCheckingEnabled,"Code caret disables prose substitutions and spelling without changing stored preferences")
        let end = NSMaxRange(range("42"))
        editor.setSelectedRange(NSRange(location:end,length:0)); editor.captureSelection(); editor.insertNewline(nil)
        check(session.buffer.source.contains("42\n  \n  text") && !session.buffer.parsed.erroneous,"Return inserts an indented newline inside a code block")
        session.undo(); check(session.buffer.source == original,"Code Return has exact-source Undo")
        editor.setSelectedRange(NSRange(location:range("café").location,length:4))
        editor.setMarkedText("日本",selectedRange:NSRange(location:2,length:0),replacementRange:editor.selectedRange()); editor.unmarkText()
        check(session.buffer.source == original.replacingOccurrences(of:"let café",with:"let 日本"),"Composition inside code preserves the surrounding source and delimiters")
        session.undo(); check(session.buffer.source == original,"Code composition has exact-source Undo")
        editor.setSelectedRange(NSRange(location:range("42").location,length:0)); editor.captureSelection()
        session.switchMode(.source); session.switchMode(.write); editor.refresh()
        editor.setSelectedRange(NSRange(location:range("After").location,length:0))
        editor.textViewDidChangeSelection(Notification(name:NSTextView.didChangeSelectionNotification,object:editor))
        check(editor.isAutomaticQuoteSubstitutionEnabled && editor.isAutomaticDashSubstitutionEnabled && editor.isAutomaticTextReplacementEnabled && editor.isContinuousSpellCheckingEnabled,"Returning to prose restores input preferences after Write/Source switches from code")
        let block = session.buffer.projection.blocks.firstIndex { $0.kind == "source" }!
        editor.toggleCode(block)
        check(editor.textStorage!.attribute(.foregroundColor,at:session.buffer.projection.blocks[block].display.location,effectiveRange:nil) as? NSColor == session.inkColor.withAlphaComponent(0.65),"Collapsed code summaries retain their subdued presentation instead of token offsets")
        editor.setSelectedRange(session.buffer.projection.blocks[block].display); editor.deleteBackward(nil)
        check(!session.buffer.source.contains(raw) && session.buffer.source.contains("Before 👩🏽‍💻") && session.buffer.source.contains("After"),"Deleting a whole folded code block preserves its surrounding prose")
        session.undo(); check(session.buffer.source == original,"Whole-block deletion restores every source byte with Undo")
        session.switchMode(.source); editor.refresh()
        let sourceOpening = range("#{")
        editor.setSelectedRange(NSRange(location:sourceOpening.location,length:1)); editor.deleteForward(nil)
        check(session.buffer.source == original.replacingOccurrences(of:"#{",with:"{"),"Source permits editing code delimiters directly")
        session.undo(); check(session.buffer.source == original,"Source delimiter edits share exact-source Undo")
        session.switchMode(.write); session.buffer.loadExternal(""); session.revision += 1; editor.refresh()
    }

}
