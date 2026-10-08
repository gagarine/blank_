import AppKit
import PDFKit
import SwiftUI
import BlankCore

@MainActor enum NativeAcceptance {
    static func run(controller: DocumentWindow) {
        let app = NSApplication.shared
        setbuf(stdout,nil)
        let originalClipboard = NSPasteboard.general.pasteboardItems?.map { item in Dictionary(uniqueKeysWithValues:item.types.compactMap { type in item.data(forType:type).map { (type,$0) } }) } ?? []
        defer {
            NSPasteboard.general.clearContents()
            let items = originalClipboard.map { contents -> NSPasteboardItem in let item = NSPasteboardItem(); for (type,data) in contents { item.setData(data,forType:type) }; return item }
            NSPasteboard.general.writeObjects(items)
        }
        // The normal AppKit event loop and delegate create this initial window.
        // Menu/focus checks therefore exercise real startup before any input.
        let session = controller.session
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        guard let view = session.editor else { fatalError("No native editor") }
        func check(_ condition: @autoclosure () -> Bool,_ label: String) { if !condition() { fatalError("FAIL: \(label) | source=\(session.buffer.source) | native=\(view.string)") }; print("PASS: \(label)") }
        check(app.activationPolicy() == .regular && app.mainMenu?.items.map(\.title) == ["blank_","File","Edit","Insert","Format","View","Go","Window","Help"],"Complete application menus are installed during launch preparation")
        check(app.mainMenu?.items.allSatisfy { $0.submenu?.items.isEmpty == false } == true && app.servicesMenu != nil && app.windowsMenu != nil && app.helpMenu != nil,"Launch menus include populated submenus and native Services, Window and Help integration")
        check(view.textLayoutManager == nil && view.layoutManager != nil,"TextKit 1 selected explicitly at creation")
        check(controller.window?.firstResponder === view,"Empty editor is focused")
        check(view.string.isEmpty,"Launch has no welcome screen")
        check(controller.window?.contentViewController === controller.splitController && controller.splitController.contentsItem.behavior == .sidebar,"Native split-view controller supplies sidebar behavior")
        check(controller.searchItem != nil && controller.shareButton != nil,"Search and Share use native toolbar controls")
        check(controller.sidebarItem?.isBordered == true && controller.modeItem?.isBordered == true,"Interactive toolbar controls opt into the system glass backing")
        NativeFigureAcceptance.run(controller:controller)
        NativeLabelAcceptance.run(controller:controller)
        NativeReferenceAcceptance.run(controller:controller)
        NativeSidebarAcceptance.run(controller:controller)
        NativeFormattingAcceptance.run(controller:controller)
        NativeGoAcceptance.text(original:controller)
        NativeCitationAcceptance.run(controller:controller)
        NativeTemplateAcceptance.run(original:controller)
        AppController.shared.commands(nil)
        for character in "fast café" {
            let key = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:String(character),charactersIgnoringModifiers:String(character),isARepeat:false,keyCode:0)!
            view.keyDown(with:key)
        }
        check(view.string.isEmpty && session.buffer.source.isEmpty,"Typing immediately after Cmd-K cannot reach the document")
        let commandDeadline = Date().addingTimeInterval(3)
        while (session.pendingCommandKeys.isEmpty == false || controller.window?.attachedSheet?.firstResponder as? NSTextView == nil) && Date() < commandDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        let commandField = controller.window?.attachedSheet?.firstResponder as? NSTextView
        check(session.commandQuery == "fast café" && commandField?.string == "fast café" && session.pendingCommandKeys.isEmpty,"Opening Commands delivers early Unicode keys to its native field editor")
        session.sheet = nil
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        AppController.shared.find(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        check((controller.window?.firstResponder as? NSTextView)?.isFieldEditor == true,"Cmd-F focuses the native Find field instead of the document")
        session.searchQuery = "Find again"
        controller.window?.makeFirstResponder(view)
        AppController.shared.find(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        let findEditor = controller.window?.firstResponder as? NSTextView
        check(findEditor?.isFieldEditor == true && findEditor?.string == "Find again","Repeated Cmd-F returns to the existing search field")
        session.hideSearch(); session.searchQuery = ""
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(controller.window?.firstResponder === view && view.string.isEmpty,"Closing search restores the untouched editor and caret")
        check(controller.window?.styleMask.contains(.fullSizeContentView) == true && controller.window?.titlebarAppearsTransparent == false,"Document extends beneath the native material toolbar")
        for scalar in "Hello café 👩🏽‍💻".unicodeScalars { view.insertText(String(scalar),replacementRange:view.selectedRange()) }
        check(session.buffer.projection.text == "Hello café 👩🏽‍💻","Native typing and Unicode")
        view.ensureNativeLayout()
        let firstLineEnd = view.rectFor(view.selectedRange().location)
        view.insertNewline(nil)
        view.ensureNativeLayout()
        let emptyParagraph = view.rectFor(view.selectedRange().location)
        check(emptyParagraph.minY-firstLineEnd.minY >= firstLineEnd.height+12,"Return shows paragraph spacing before typing")
        check(controller.window?.firstResponder === view && view.shouldDrawInsertionPoint,"Return keeps focus and a native insertion point")
        view.insertText("Second paragraph",replacementRange:view.selectedRange())
        check(session.buffer.projection.blocks.count == 2,"Return splits paragraph")
        check(controller.document as? NativeDocument === controller.nativeDocument && controller.nativeDocument.session === session,"Writing uses AppKit's attached document title control")
        view.ensureNativeLayout()
        let paragraphEnd = view.rectFor(view.selectedRange().location)
        view.insertLineBreak(nil)
        view.ensureNativeLayout()
        let softLine = view.rectFor(view.selectedRange().location)
        check(session.buffer.projection.blocks.count == 2 && session.buffer.projection.text.hasSuffix("\u{2028}"),"Shift-Return stays inside the paragraph")
        check(softLine.minY-paragraphEnd.minY < paragraphEnd.height+12,"Soft line break omits paragraph spacing")
        view.insertText("Continuation",replacementRange:view.selectedRange())
        let lastParagraph = session.buffer.projection.blocks.last!
        view.setSelectedRange(lastParagraph.display); view.copy(nil)
        check(NSPasteboard.general.string(forType:.string) == "Second paragraph\nContinuation","Soft line breaks copy as plain newlines")
        session.undo(); session.undo()
        check(session.buffer.projection.blocks.last?.text == "Second paragraph","Undo restores paragraph before soft break")
        view.setSelectedRange(NSRange(location:0,length:5)); view.captureSelection(); session.format(italic:false)
        check(session.buffer.source.contains("*Hello*"),"Native selection and bold")
        view.copy(nil)
        check(NSPasteboard.general.string(forType:.string) == "Hello","Write clipboard plain text")
        check(NSPasteboard.general.data(forType:NSPasteboard.PasteboardType("local.blank.typst-fragment")) != nil,"Write clipboard structured source")
        session.switchMode(.source); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(controller.modeItem?.selectedIndex == 1,"Native toolbar follows keyboard view changes")
        guard let sourceView = session.editor else { fatalError() }
        sourceView.selectAll(nil); sourceView.copy(nil)
        check(NSPasteboard.general.string(forType:.string) == session.buffer.source,"Source clipboard exact source")
        session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(session.editor?.textLayoutManager == nil,"TextKit 1 retained after switching")
        check(session.editor?.isAutomaticQuoteSubstitutionEnabled == session.editor?.inputDefaults?.quotes,"Write restores native input preferences after Source")
        session.undo(); check(!session.buffer.source.contains("*Hello*"),"Undo shared across views")
        session.undo(true); check(session.buffer.source.contains("*Hello*"),"Redo shared across views")
        let editor = session.editor!
        let beforeReplace = session.buffer.source
        editor.setSelectedRange(NSRange(location:0,length:5)); editor.captureSelection()
        session.searchQuery = "No such phrase"; session.replaceText = "Replacement"
        session.replace()
        check(session.buffer.source == beforeReplace,"Replace after an unmatched query preserves unrelated selected text")
        session.searchQuery = "Second paragraph"
        session.replace()
        check(session.buffer.source == beforeReplace && (editor.string as NSString).substring(with:editor.selectedRange()) == "Second paragraph","Replace first locates a match when the selection is unrelated")
        session.replace()
        check(session.buffer.projection.text.contains("Replacement") && !session.buffer.projection.text.contains("Second paragraph"),"Replace changes only the located match")
        session.undo(); session.searchQuery = ""; session.replaceText = ""
        check(session.buffer.source == beforeReplace,"Search replacement shares document undo")
        editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0)); editor.captureSelection()
        editor.setMarkedText("に",selectedRange:NSRange(location:1,length:0),replacementRange:editor.selectedRange())
        editor.setMarkedText("日本",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        editor.insertText("日本",replacementRange:NSRange(location:NSNotFound,length:0))
        check(session.buffer.projection.text.hasSuffix("日本"),"Native marked-text composition commits once")
        check(editor.textLayoutManager == nil,"TextKit 1 retained through composition")
        editor.setMarkedText("語",selectedRange:NSRange(location:1,length:0),replacementRange:editor.selectedRange())
        let terminatingController = AppController(); terminatingController.controllers = [controller]
        terminatingController.prepareDocumentsForTermination(); session.recoveryQueue.sync {}
        check(!editor.hasMarkedText() && session.buffer.projection.text.hasSuffix("日本語"),"Quit preparation commits visible marked text before autosave")
        let terminationRecovery = try! JSONDecoder().decode(Recovery.self,from:Data(contentsOf:session.recoveryURL))
        check(terminationRecovery.files[session.entry] == session.buffer.source,"Quit recovery includes the completed native composition")
        editor.formatNative(false)
        editor.insertText("A",replacementRange:editor.selectedRange()); editor.insertText("B",replacementRange:editor.selectedRange())
        check(session.buffer.projection.text.hasSuffix("日本語AB") && !session.buffer.parsed.erroneous,"Bold typing remains valid across keystrokes")
        editor.formatNative(false); editor.insertText("C",replacementRange:editor.selectedRange())
        check(!session.buffer.projection.blocks.last!.inlines.flatMap(\.runs).last!.style.bold && !session.buffer.parsed.erroneous,"Bold typing can be turned off inside a word")
        editor.insertionBold = nil
        for (marker,kind,level) in [("===","heading",3),("-","bullet",0),("+","number",0)] {
            session.buffer.loadExternal(""); session.revision += 1; editor.lastRevision = -1; editor.refresh()
            var visible = ""
            for character in marker {
                visible.append(character)
                editor.insertText(String(character),replacementRange:editor.selectedRange())
                check(editor.string == visible,"Incomplete block marker remains visible while typing")
            }
            check(session.buffer.projection.blocks[0].kind == "paragraph","Incomplete shortcut stays ordinary visible text")
            editor.insertText(" ",replacementRange:editor.selectedRange())
            check(session.buffer.projection.blocks[0].kind == kind && session.buffer.projection.blocks[0].level == level,"Space completes the visible block shortcut")
            editor.insertText("Visible text",replacementRange:editor.selectedRange())
            check(editor.string == "Visible text","Completed block shortcut accepts native typing")
        }
        for input in ["*bold* ordinary ","*_both_* ","snake_case_name ","=== "] {
            session.buffer.loadExternal("Target\n"); session.revision += 1; editor.refresh(); editor.setSelectedRange(NSRange(location:0,length:0)); editor.captureSelection(); editor.insertionBold = nil; editor.insertionItalic = nil
            for scalar in input.unicodeScalars { editor.insertText(String(scalar),replacementRange:editor.selectedRange()) }
            let expected = input == "*bold* ordinary " ? "bold ordinary Target" : input == "*_both_* " ? "both Target" : input == "=== " ? "Target" : "snake_case_name Target"
            check(session.buffer.projection.text == expected && !session.buffer.parsed.erroneous,"Go typing shortcut: "+input)
            if input == "=== " { check(session.buffer.projection.blocks[0].level == 3,"Heading prefix keeps existing content") }
        }
        editor.insertionBold = nil; editor.insertionItalic = nil
        func resetParagraphs(_ text: String) {
            session.buffer.loadExternal(text); session.revision += 1; editor.refresh()
            editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0)); editor.captureSelection()
        }
        resetParagraphs("")
        editor.insertNewline(nil); editor.insertNewline(nil)
        check(controller.window?.firstResponder === editor && editor.shouldDrawInsertionPoint,"Repeated Return retains the native insertion point in an empty paragraph")
        editor.insertText("Third",replacementRange:editor.selectedRange())
        check(session.buffer.projection.blocks.map(\.text) == ["","","Third"],"Repeated Return retains empty paragraphs")
        editor.setSelectedRange(NSRange(location:2,length:0)); editor.deleteBackward(nil)
        check(session.buffer.projection.blocks.map(\.text) == ["","Third"],"Backspace joins an empty paragraph")
        resetParagraphs("First\n\nSecond")
        editor.setSelectedRange(NSRange(location:5,length:0)); editor.captureSelection(); editor.insertNewline(nil)
        editor.insertText("Middle",replacementRange:editor.selectedRange())
        check(session.buffer.projection.blocks.map(\.text) == ["First","Middle","Second"],"Return creates an editable paragraph between existing blocks")
        let tutorial = try! String(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("Tutorial.typ"),encoding:.utf8)
        resetParagraphs(tutorial)
        let titleEnd = NSMaxRange(session.buffer.projection.blocks[0].display)
        editor.setSelectedRange(NSRange(location:titleEnd,length:0)); editor.captureSelection(); editor.insertNewline(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(session.buffer.projection.blocks[1].text.isEmpty && session.buffer.projection.blocks[1].kind == "paragraph","Tutorial title Return creates an empty body paragraph")
        check(editor.selectedRange() == NSRange(location:titleEnd+1,length:0) && controller.window?.firstResponder === editor && editor.shouldDrawInsertionPoint,"Tutorial title Return retains the mapped native caret and focus")
        let emptyBodyRect = editor.rectFor(titleEnd+1)
        check(emptyBodyRect.height > 10 && emptyBodyRect.height < editor.rectFor(0).height && editor.visibleRect.intersects(emptyBodyRect),"Tutorial empty paragraph has visible body-sized caret geometry")
        check((editor.textStorage!.attribute(.font,at:titleEnd+1,effectiveRange:nil) as? NSFont)?.pointSize == CGFloat(session.fontSize),"Tutorial empty paragraph uses body typography before typing")
        session.undo(); check(session.buffer.source == tutorial,"Tutorial heading Return undo preserves the exact tutorial")
        session.undo(true); check(session.buffer.projection.blocks[1].text.isEmpty,"Tutorial heading Return redo restores the empty paragraph")
        editor.insertText("Body 👋",replacementRange:editor.selectedRange())
        check(session.buffer.projection.blocks[1].text == "Body 👋","Tutorial heading Return inserts Unicode into the new body paragraph")
        resetParagraphs("= Heading")
        editor.insertNewline(nil); editor.insertText("Body",replacementRange:editor.selectedRange())
        check(session.buffer.projection.blocks.map(\.kind) == ["heading","paragraph"],"Return after a heading starts body text")
        resetParagraphs("- Item")
        editor.insertNewline(nil)
        check(session.buffer.projection.blocks.map(\.kind) == ["bullet","bullet"],"Return continues a list")
        editor.insertNewline(nil); editor.insertText("After",replacementRange:editor.selectedRange())
        check(session.buffer.projection.blocks.map(\.kind) == ["bullet","paragraph"],"Return on an empty item exits the list")
        for (kind,query,marker) in [("bullet","bullet","- "),("number","number","+ "),("heading","heading","= ")] {
            for original in ["/", "Before\n\n/\n\nAfter", "Before\n\n/\n\n"] {
                resetParagraphs(original.replacingOccurrences(of:"/",with:""))
                let slashAt = original.hasPrefix("Before") ? 7 : 0
                editor.setSelectedRange(NSRange(location:slashAt,length:0)); editor.captureSelection()
                for character in "/"+query { editor.insertText(String(character),replacementRange:editor.selectedRange()) }
                editor.slashIndex = editor.slashMatches.firstIndex { $0.kind == kind && ($0.kind != "heading" || $0.level == 1) }!
                editor.chooseSlash()
                let index = session.buffer.projection.blockIndex(at:slashAt), block = session.buffer.projection.blocks[index]
                check(block.kind == kind && block.text.isEmpty && editor.selectedRange() == NSRange(location:block.display.location,length:0),"Slash creates an empty \(kind) with its caret on the same line")
                check(session.buffer.source == original.replacingOccurrences(of:"/",with:marker),"Slash preserves surrounding source for \(kind)")
                let font = editor.typingAttributes[.font] as! NSFont
                let style = editor.typingAttributes[.paragraphStyle] as! NSParagraphStyle
                check(kind == "heading" ? font.pointSize > CGFloat(session.fontSize) : style.firstLineHeadIndent == 25,"Empty \(kind) has its native font and indentation before typing")
                check(editor.rectFor(block.display.location).minX >= editor.textContainerInset.width+(kind == "heading" ? 0 : 24),"Empty list caret follows its drawn marker")
                editor.insertText("Café 👩🏽‍💻",replacementRange:editor.selectedRange())
                check(session.buffer.projection.blocks[index].text == "Café 👩🏽‍💻","Typing fills the chosen \(kind), without a new paragraph")
                editor.setSelectedRange(session.buffer.projection.blocks[index].display); editor.captureSelection()
                editor.deleteBackward(nil)
                check(session.buffer.projection.blocks[index].text.isEmpty,"Deleting Unicode content retains an empty \(kind)")
                let beforeUnformat = session.buffer.source
                editor.deleteBackward(nil)
                check(session.buffer.projection.blocks[index].kind == "paragraph" && session.buffer.projection.blocks[index].text.isEmpty,"Backspace removes the empty \(kind) marker")
                session.undo(); check(session.buffer.source == beforeUnformat,"Undo restores the empty \(kind) exactly")
                editor.dismissSlash()
            }
        }
        resetParagraphs("Left selected right")
        editor.setSelectedRange(NSRange(location:5,length:8)); editor.captureSelection(); editor.insertNewline(nil)
        check(session.buffer.projection.blocks.map(\.text) == ["Left","right"],"Return replaces selection and splits its paragraph")
        session.undo(); check(session.buffer.source == "Left selected right","Selected Return is one undo transaction")
        for (source,kind) in [("= _Heading 👋_","heading"),("== *_Heading_*","heading"),("- _Item_","bullet"),("#quote(block: true)[_Quote_]","quote")] {
            resetParagraphs(source); editor.insertionBold = nil; editor.insertionItalic = nil
            let block = session.buffer.projection.blocks[0]
            editor.setSelectedRange(block.display); editor.captureSelection(); session.buffer.breakUndoGroup()
            editor.insertText("",replacementRange:editor.selectedRange())
            let emptySource = session.buffer.source
            check(session.buffer.projection.blocks[0].text.isEmpty && session.buffer.projection.blocks[0].kind == kind,"Deleting styled content clears inline marks and retains its block kind")
            for character in "/paragraph" {
                editor.insertText(String(character),replacementRange:editor.selectedRange())
                let font = editor.textStorage!.attribute(.font,at:editor.selectedRange().location-1,effectiveRange:nil) as! NSFont
                check(font.pointSize == CGFloat(session.fontSize) && NSFontManager.shared.traits(of:font).intersection([.boldFontMask,.italicFontMask]).isEmpty,"Empty-block slash filtering uses regular body typography for every character")
            }
            check(session.buffer.projection.blocks[0].kind == kind,"Opening slash does not change canonical block type")
            editor.chooseSlash(); editor.insertText("New text",replacementRange:editor.selectedRange())
            check(session.buffer.projection.blocks[0].kind == "paragraph" && session.buffer.projection.blocks[0].text == "New text" && !session.buffer.projection.blocks[0].inlines.flatMap(\.runs).contains { $0.style.bold || $0.style.italic },"Slash paragraph choice replaces the old kind without inheriting deleted marks")
            session.undo(); session.undo(); session.undo()
            check(session.buffer.source == emptySource,"Undo through slash choice restores the empty original block")
            editor.dismissSlash()
        }
        resetParagraphs("= Heading"); editor.selectAll(nil); editor.insertText("",replacementRange:editor.selectedRange())
        editor.insertText("/",replacementRange:editor.selectedRange()); editor.dismissSlash()
        let literalSlashFont = editor.textStorage!.attribute(.font,at:0,effectiveRange:nil) as! NSFont
        check(session.buffer.source == "= /" && literalSlashFont.pointSize > CGFloat(session.fontSize),"Escape restores heading typography for a literal slash without changing source")
        session.buffer.loadExternal("Slash target"); session.revision += 1; editor.refresh()
        editor.setSelectedRange(NSRange(location:0,length:0)); editor.captureSelection()
        for scalar in "/heading".unicodeScalars { editor.insertText(String(scalar),replacementRange:editor.selectedRange()) }
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(editor.slashPopover?.isShown == true && (editor.slashPopover?.contentViewController?.view.bounds.height ?? 0) >= 140,"Slash popover retains visible filtered rows")
        if let content = editor.slashPopover?.contentViewController?.view, let popoverWindow = content.window, let window = editor.window {
            func menuButtons(_ view: NSView) -> [MenuActionButton] { (view as? MenuActionButton).map { [$0] } ?? view.subviews.flatMap(menuButtons) }
            func cursorAreas(_ view: NSView) -> [SlashMenuCursorView] { (view as? SlashMenuCursorView).map { [$0] } ?? view.subviews.flatMap(cursorAreas) }
            let buttons = menuButtons(content)
            let cursorArea = cursorAreas(content).first!
            check(cursorArea.bounds.size == content.bounds.size,"Slash cursor tracking covers the entire native popover content")
            check(!buttons.isEmpty && buttons.allSatisfy { $0.bounds.width > content.bounds.width*0.8 },"Native command rows fill the menu width")
            check(buttons.allSatisfy { $0.hitTest(NSPoint(x:$0.frame.maxX-3,y:$0.frame.midY)) === $0 },"Empty trailing row space hits its native button")
            let menuRect = popoverWindow.convertToScreen(content.convert(content.bounds,to:nil))
            let caret = window.convertToScreen(editor.convert(editor.rectFor(0),to:nil))
            check(!menuRect.contains(NSPoint(x:caret.midX,y:caret.midY)),"Slash popover does not obscure the native caret")
            func menuPointer(_ screenPoint: NSPoint,in eventWindow: NSWindow) -> NSEvent {
                NSEvent.mouseEvent(with:.mouseMoved,location:eventWindow.convertPoint(fromScreen:screenPoint),modifierFlags:[],timestamp:0,windowNumber:eventWindow.windowNumber,context:nil,eventNumber:1,clickCount:0,pressure:0)!
            }
            let source = session.buffer.source, selection = editor.selectedRange()
            for point in [NSPoint(x:menuRect.midX,y:menuRect.midY),NSPoint(x:menuRect.maxX-3,y:menuRect.midY),NSPoint(x:menuRect.minX+3,y:menuRect.minY+3)] {
                NSCursor.iBeam.set(); cursorArea.cursorUpdate(with:menuPointer(point,in:popoverWindow))
                check(NSCursor.current == .arrow,"Slash menu owns the arrow cursor over rows and padding")
                editor.hoverBlock = 0
                editor.mouseMoved(with:menuPointer(point,in:window))
                check(NSCursor.current == .arrow && editor.hoverBlock == nil,"Menu hover cannot activate editor text or block handles underneath")
                editor.hoverBlock = 0; NSCursor.openHand.set(); editor.cursorUpdate(with:menuPointer(point,in:popoverWindow))
                check(NSCursor.current == .arrow && editor.hoverBlock == nil,"Popover-window cursor events use screen coordinates and clear underlying handles")
            }
            editor.cursorUpdate(with:menuPointer(NSPoint(x:caret.midX,y:caret.midY),in:window))
            check(NSCursor.current == .iBeam,"Text outside the open slash menu retains its native cursor")
            editor.slashQuery = "No such command"; editor.showSlash()
            RunLoop.main.run(until:Date().addingTimeInterval(0.1))
            let emptyMenu = editor.slashPopover!.contentViewController!.view
            let emptyWindow = emptyMenu.window!
            let emptyRect = emptyWindow.convertToScreen(emptyMenu.convert(emptyMenu.bounds,to:nil))
            NSCursor.iBeam.set(); cursorAreas(emptyMenu).first!.cursorUpdate(with:menuPointer(NSPoint(x:emptyRect.midX,y:emptyRect.midY),in:emptyWindow))
            editor.mouseMoved(with:menuPointer(NSPoint(x:emptyRect.midX,y:emptyRect.midY),in:window))
            check(NSCursor.current == .arrow,"Empty slash results retain the arrow cursor after filtering")
            check(session.buffer.source == source && editor.selectedRange() == selection && window.firstResponder === editor,"Menu pointer tracking preserves source, selection and typing focus")
            editor.slashQuery = "heading"; editor.showSlash()
        } else { fatalError("Missing native popover window") }
        if ProcessInfo.processInfo.environment["BLANK_GEOMETRY"] != nil {
            var actual = NSRange()
            print("Geometry",editor.frame,editor.visibleRect,editor.textContainerOrigin,editor.rectFor(0),editor.firstRect(forCharacterRange:NSRange(location:0,length:1),actualRange:&actual),editor.slashPopover?.contentViewController?.view.window?.frame as Any,controller.window?.frame as Any)

        }
        editor.slashIndex = 1; editor.chooseSlash()
        check(session.buffer.source == "== Slash target" && editor.slashPopover == nil,"Slash choice preserves content and dismisses menu")
        let restoredCaret = editor.rectFor(editor.selectedRange().location)
        let restoredPointer = NSEvent.mouseEvent(with:.mouseMoved,location:editor.convert(NSPoint(x:restoredCaret.midX,y:restoredCaret.midY),to:nil),modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:1,clickCount:0,pressure:0)!
        NSCursor.arrow.set(); editor.cursorUpdate(with:restoredPointer)
        check(NSCursor.current == .iBeam,"Dismissing slash restores the editor text cursor")
        session.undo(); check(session.buffer.source == "/headingSlash target","Slash conversion is one undo transaction")
        session.buffer.loadExternal(""); session.revision += 1; editor.lastRevision = -1; editor.refresh()
        for character in "/table" { editor.insertText(String(character),replacementRange:editor.selectedRange()) }
        editor.chooseSlash()
        let insertedTable = session.buffer.projection.blocks.firstIndex { $0.kind == "table" }!
        check(session.sheet == nil && session.buffer.projection.blocks[insertedTable].tableCells.count == 4,"Slash Table immediately creates an empty two-by-two table without a dialog")
        check(session.buffer.projection.tableCell(at:editor.selectedRange())?.cell == 0 && controller.window?.firstResponder === editor,"Slash Table focuses its first cell ready to type")
        editor.insertText("First cell",replacementRange:editor.selectedRange())
        check(session.buffer.source.contains("[First cell]"),"New slash table accepts typing immediately")
        session.buffer.loadExternal("First block\n\nSecond block\n\nThird block")
        session.revision += 1; editor.refresh(); editor.ensureNativeLayout()
        check(controller.window?.acceptsMouseMovedEvents == true,"Document window delivers handle hover events")
        func pointer(_ type: NSEvent.EventType,_ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:editor.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0 : 1)!
        }
        let handle = NSPoint(x:editor.textContainerInset.width-23,y:editor.blockRect(0).minY+12)
        editor.mouseEntered(with:pointer(.mouseMoved,handle))
        check(editor.hoverBlock == 0 && NSCursor.current == NSCursor.openHand,"Entering a handle shows an open hand")
        editor.mouseMoved(with:pointer(.mouseMoved,NSPoint(x:editor.textContainerInset.width+100,y:handle.y)))
        check(editor.hoverBlock == nil,"Hovering prose away from its left edge hides block handles")
        editor.mouseMoved(with:pointer(.mouseMoved,NSPoint(x:editor.textContainerInset.width+8,y:handle.y)))
        check(editor.hoverBlock == 0,"Approaching the text's left edge reveals its block handle")
        editor.mouseMoved(with:pointer(.mouseMoved,handle))
        let gutter = NSRect(x:editor.textContainerInset.width-30,y:editor.rectFor(0).midY-9,width:20,height:20)
        guard let handlePixels = editor.bitmapImageRepForCachingDisplay(in:gutter) else { fatalError("Missing native gutter bitmap") }
        editor.cacheDisplay(in:gutter,to:handlePixels)
        let paper = session.paperColor.usingColorSpace(.deviceRGB)!
        var visibleHandle = false
        for y in 0..<handlePixels.pixelsHigh { for x in 0..<handlePixels.pixelsWide {
            if let color = handlePixels.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.8,
               abs(color.redComponent-paper.redComponent)+abs(color.greenComponent-paper.greenComponent)+abs(color.blueComponent-paper.blueComponent) > 0.2 { visibleHandle = true }
        } }
        check(visibleHandle,"Handle dots are actually rendered outside the text-container clip")
        if ProcessInfo.processInfo.environment["BLANK_INTERACTION_IMAGES"] != nil, let bitmap = editor.bitmapImageRepForCachingDisplay(in:editor.visibleRect) {
            editor.cacheDisplay(in:editor.visibleRect,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/blank-block-handle.png"))
        }
        editor.hoverBlock = nil
        editor.mouseDown(with:pointer(.leftMouseDown,handle))
        check(editor.grabbed == 0 && NSCursor.current == NSCursor.closedHand,"Handle press grabs immediately without a prior hover")
        let destination = NSPoint(x:handle.x+50,y:editor.blockRect(2).minY-7)
        editor.mouseDragged(with:pointer(.leftMouseDragged,destination))
        let middle = (editor.blockRect(1).maxY+editor.blockRect(2).minY)/2
        check(editor.draggingBlock && editor.dragTarget == 2 && editor.dragImage != nil,"Block drag creates a native translucent preview")
        check(editor.dropIndicatorRect()?.height == 2 && abs((editor.dropIndicatorRect()?.midY ?? 0)-middle) < 0.1,"Block drag has one centered insertion line")
        if ProcessInfo.processInfo.environment["BLANK_INTERACTION_IMAGES"] != nil, let bitmap = editor.bitmapImageRepForCachingDisplay(in:editor.visibleRect) {
            editor.cacheDisplay(in:editor.visibleRect,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/blank-block-drag.png"))
        }
        editor.mouseUp(with:pointer(.leftMouseUp,destination))
        check(NSCursor.current == NSCursor.iBeam,"Dropping over text restores the text cursor")
        check(session.buffer.projection.blocks.map(\.text) == ["Second block","First block","Third block"],"Dropping a block moves its source")
        session.undo(); check(session.buffer.projection.blocks.first?.text == "First block","Block drag undo restores order")
        let shortDragSource = session.buffer.source
        let longDragSource = (0..<100).map { "Block \($0) café 👩🏽‍💻" }.joined(separator:"\n\n")
        session.buffer.loadExternal(longDragSource); session.revision += 1; editor.refresh()
        editor.scroll(.zero); editor.ensureNativeLayout()
        let longHandle = NSPoint(x:editor.textContainerInset.width-23,y:editor.blockRect(0).minY+12)
        editor.mouseDown(with:pointer(.leftMouseDown,longHandle))
        // Cross many viewports with the original block still grabbed. Geometry
        // must stay in document coordinates after its glyphs leave the screen.
        for target in [20,40,60,80] {
            let rect = editor.blockRect(target)
            editor.scroll(NSPoint(x:0,y:rect.minY-150)); editor.ensureNativeLayout()
            let drop = NSPoint(x:longHandle.x+50,y:editor.blockRect(target).minY-7)
            editor.mouseDragged(with:pointer(.leftMouseDragged,drop))
            check(editor.grabbed == 0 && editor.dragTarget == target,"Long block drag reaches block \(target) without jumping to the document start")
            check(editor.blockRect(0).maxY < editor.visibleRect.minY,"Offscreen block geometry stays above the viewport during dragging")
        }
        let heldDrop = NSPoint(x:longHandle.x+50,y:editor.visibleRect.maxY+12)
        editor.mouseDragged(with:pointer(.leftMouseDragged,heldDrop))
        let beforeAutoscroll = editor.visibleRect.minY
        RunLoop.main.run(until:Date().addingTimeInterval(0.25))
        check(editor.visibleRect.minY > beforeAutoscroll && editor.dragTarget > 80,"Holding a block below the viewport continues autoscrolling without new mouse events")
        let finalTarget = editor.dragTarget
        editor.mouseUp(with:pointer(.leftMouseUp,NSPoint(x:longHandle.x+50,y:editor.visibleRect.maxY)))
        check(session.buffer.projection.blocks[finalTarget-1].text == "Block 0 café 👩🏽‍💻" && editor.blockDragTimer == nil,"Long-distance drop preserves the block and stops autoscrolling")
        session.undo(); check(session.buffer.source == longDragSource,"Long-distance block move undoes to exact Unicode source")
        session.buffer.loadExternal(shortDragSource); session.revision += 1; editor.refresh(); editor.scroll(.zero); editor.ensureNativeLayout()
        let menuSource = session.buffer.source
        editor.showBlockMenu(0,event:pointer(.leftMouseUp,handle))
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        let handleMenu = (editor.blockPopover?.contentViewController as? NSHostingController<BlockActionMenu>)?.rootView
        check(editor.blockPopover?.isShown == true && handleMenu?.items.map { $0.item.title } == ["Turn into","Duplicate","Delete"],"Block handle uses the compact app popover without injected text-context actions")
        check(handleMenu?.items.first?.children.allSatisfy { ($0.item as? BlockMenuItem)?.command?.kind != "paragraph" } == true,"Turn into omits the current block type")
        if let content = editor.blockPopover?.contentViewController?.view {
            func menuButtons(_ view: NSView) -> [MenuActionButton] {
                (view as? MenuActionButton).map { [$0] } ?? view.subviews.flatMap(menuButtons)
            }
            guard let duplicateButton = menuButtons(content).first(where:{ $0.accessibilityLabel() == "Duplicate" }) else { fatalError("Missing Duplicate menu row") }
            var reportedHover = false
            let hover = duplicateButton.hover
            duplicateButton.hover = { value in hover(value); reportedHover = value }
            let event = NSEvent.enterExitEvent(with:.mouseEntered,location:duplicateButton.convert(NSPoint(x:10,y:10),to:nil),modifierFlags:[],timestamp:0,windowNumber:content.window!.windowNumber,context:nil,eventNumber:1,trackingNumber:0,userData:nil)!
            duplicateButton.mouseEntered(with:event)
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            check(duplicateButton.isHovered && reportedHover,"Native block menu pointer entry updates the highlighted row")
            duplicateButton.mouseExited(with:event)
            check(!duplicateButton.isHovered,"Leaving a menu row resets its native hover state")
        }
        if let duplicate = handleMenu?.items.first(where:{ $0.item.title == "Duplicate" }) { handleMenu?.choose(duplicate.item) }
        check(session.buffer.projection.blocks.count == 4 && controller.window?.firstResponder === editor,"Popover Duplicate uses the document transaction and restores editing focus")
        session.undo(); check(session.buffer.source == menuSource,"Popover block actions share exact-source undo")
        let selectionBeforeSidebar = editor.selectedRange(), editorBeforeSidebar = session.editor
        controller.toggleContents(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.3))
        check(!controller.splitController.contentsItem.isCollapsed && session.editor === editorBeforeSidebar && editor.selectedRange() == selectionBeforeSidebar,"Native sidebar reveal preserves the editor instance and selection")
        check(session.sidebar && controller.sidebarItem?.toolTip?.hasPrefix("Hide") == true,"Opening Sidebar updates its toolbar control")
        session.toggleSidebar()
        RunLoop.main.run(until:Date().addingTimeInterval(0.3))
        check(controller.splitController.contentsItem.isCollapsed && session.editor === editorBeforeSidebar && editor.selectedRange() == selectionBeforeSidebar,"Native sidebar collapse preserves the editor instance and selection")
        check(!session.sidebar && controller.sidebarItem?.toolTip?.hasPrefix("Show") == true,"Closing Sidebar updates its toolbar control")
        let sectionSource = "= One\n\n日本\n\n== Child\n\n#let custom = 42\n\n= Two\n\nBody\n\n= Three\n\nTail"
        session.buffer.loadExternal(sectionSource); session.revision += 1; editor.refresh()
        let contentsDrag = ContentsDrag(), firstRow = ContentsRowView(frame:NSRect(x:40,y:100,width:180,height:28)), lastRow = ContentsRowView(frame:NSRect(x:40,y:160,width:180,height:28))
        for row in [firstRow,lastRow] { row.session = session; row.drag = contentsDrag; contentsDrag.register(row); editor.addSubview(row) }
        firstRow.item = .heading(0); firstRow.label.stringValue = "One"
        lastRow.item = .heading(session.headings.last!.0); lastRow.label.stringValue = "Three"
        contentsDrag.source = firstRow; contentsDrag.path = session.active; contentsDrag.revision = session.buffer.revision
        session.sidebarOrderLocked = true
        check(!contentsDrag.canMove(to:lastRow,after:true),"Lock section order rejects sidebar reordering")
        session.sidebarOrderLocked = false; session.sidebar = true
        check(contentsDrag.canMove(to:lastRow,after:true),"Pinned Contents permits section moves when unlocked")
        session.sidebar = false
        let drop = ContentsTestDrag(source:firstRow,window:controller.window!)
        drop.draggingLocation = lastRow.convert(NSPoint(x:50,y:25),to:nil)
        check(lastRow.draggingEntered(drop) == .move && NSCursor.current == .closedHand,"Contents drag uses a closed hand and a move operation without a copy badge")
        check(contentsDrag.destination === lastRow && contentsDrag.after,"Lower row half targets insertion after the last section")
        lastRow.layoutSubtreeIfNeeded()
        let marker = lastRow.bitmapImageRepForCachingDisplay(in:lastRow.bounds)!
        lastRow.cacheDisplay(in:lastRow.bounds,to:marker)
        check((marker.colorAt(x:marker.pixelsWide-10,y:marker.pixelsHigh-1)?.alphaComponent ?? 0) > 0.9 && (marker.colorAt(x:marker.pixelsWide-10,y:0)?.alphaComponent ?? 1) < 0.1,"Contents insertion line renders across the bottom boundary, without a second line above")
        drop.draggingLocation = lastRow.convert(NSPoint(x:50,y:2),to:nil)
        check(lastRow.draggingUpdated(drop) == .move && !contentsDrag.after,"Upper row half targets insertion before the section")
        check(contentsDrag.destination === lastRow,"Contents drag has only one active insertion target")
        drop.draggingSource = NSObject()
        check(lastRow.draggingUpdated(drop).isEmpty,"Contents rejects foreign drag sources")
        drop.draggingSource = firstRow; drop.draggingLocation = lastRow.convert(NSPoint(x:50,y:25),to:nil)
        check(lastRow.prepareForDragOperation(drop) && lastRow.performDragOperation(drop),"Contents native drop moves a section after the final row")
        check(session.buffer.source.hasPrefix("= Two") && session.buffer.source.contains("Tail\n\n= One\n\n日本\n\n== Child\n\n#let custom = 42"),"Sidebar movement preserves nested sections, Unicode and custom code")
        check(contentsDrag.destination == nil,"Finishing a drop removes its insertion line")
        contentsDrag.finish()
        check(contentsDrag.source == nil,"Ending a drag releases its source row")
        session.undo(); check(session.buffer.source == sectionSource,"Sidebar section movement shares document undo")
        contentsDrag.source = firstRow; contentsDrag.path = session.active; contentsDrag.revision = session.buffer.revision-1
        check(!contentsDrag.canMove(to:lastRow,after:true),"Contents rejects stale document drag snapshots")
        contentsDrag.finish(); firstRow.removeFromSuperview(); lastRow.removeFromSuperview()
        let hierarchySource = "= Alpha\n\n== Child\n\n日本\n\n=== Nested\n\n#let custom = 42\n\n= Beta\n\n== Existing\n\nBody\n\n= Empty"
        session.buffer.loadExternal(hierarchySource); session.revision += 1; editor.refresh()
        let childRow = ContentsRowView(frame:NSRect(x:55,y:100,width:165,height:28))
        let parentRow = ContentsRowView(frame:NSRect(x:40,y:160,width:180,height:28))
        let descendantRow = ContentsRowView(frame:NSRect(x:55,y:191,width:165,height:28))
        for row in [childRow,parentRow,descendantRow] { row.session = session; row.drag = contentsDrag; contentsDrag.register(row); editor.addSubview(row) }
        childRow.item = .heading(session.headings.first { $0.1.text == "Child" }!.0)
        parentRow.item = .heading(session.headings.first { $0.1.text == "Beta" }!.0)
        descendantRow.item = .heading(session.headings.first { $0.1.text == "Existing" }!.0)
        contentsDrag.source = childRow; contentsDrag.path = session.active; contentsDrag.revision = session.buffer.revision
        if case let .heading(child) = childRow.item, case let .heading(parent) = parentRow.item { contentsDrag.collapsed = [child,parent] }
        let parentDrop = ContentsTestDrag(source:childRow,window:controller.window!)
        parentDrop.draggingLocation = parentRow.convert(NSPoint(x:50,y:14),to:nil)
        check(parentRow.draggingUpdated(parentDrop) == .move && contentsDrag.placement == .inside,"A child heading can target another parent without changing levels")
        check(contentsDrag.destination === parentRow && contentsDrag.markerRow === descendantRow && contentsDrag.markerAfter,"Parent insertion line follows its visible descendants")
        descendantRow.isHidden = true
        check(parentRow.draggingUpdated(parentDrop) == .move && contentsDrag.markerRow === parentRow && contentsDrag.markerIndent == 12,"A collapsed parent accepts an indented child drop")
        descendantRow.isHidden = false
        check(parentRow.performDragOperation(parentDrop),"Native child-to-parent drop executes")
        check(session.buffer.source.contains("Body\n\n== Child\n\n日本\n\n=== Nested\n\n#let custom = 42\n\n= Empty"),"Child drop retains its complete nested Typst source")
        check(contentsDrag.collapsed == Set(session.headings.filter { $0.1.text == "Child" }.map(\.0)),"Moving a collapsed section preserves its disclosure state and opens the destination parent")
        contentsDrag.finish(); session.undo(); check(session.buffer.source == hierarchySource,"Parent drop shares native document undo")
        for row in [childRow,parentRow,descendantRow] { row.removeFromSuperview() }
        // SwiftUI may release the old source row before AppKit ends its drag.
        var disappearingRow: ContentsRowView? = ContentsRowView()
        disappearingRow!.session = session; contentsDrag.source = disappearingRow
        disappearingRow = nil; contentsDrag.finish()
        check(contentsDrag.source == nil,"A released source row cannot leave a stale move active")
        // Table cells are real paragraphs in the document's native NSTextTable.
        check(EditorPreferences.installedEditorFamily(nil) == "System","Default editor font is the native macOS system face")
        check(EditorPreferences.installedEditorFamilies.contains(session.fontFamily),"Editor font selection is an installed family")
        check(EditorPreferences.installedEditorFamilies.contains(EditorPreferences.installedEditorFamily("Missing-font-XYZ")),"Missing saved font falls back to an installed family")
        let commands = CommandsSheet(session:session)
        check(commands.actions.contains { $0.0 == "Convert bibliography…" },"Cmd-K exposes bibliography storage conversion")
        check(NSApp.mainMenu?.items.first(where:{ $0.title == "File" })?.submenu?.items.contains(where:{ $0.title == "Convert Bibliography…" }) == true,"The native File menu exposes bibliography storage conversion")
        check(commands.actions.filter { $0.0.hasPrefix("New ") }.map { $0.0 } == ["New project","New document"],"Cmd-K offers an empty New Document and a separate New Project")
        check(commands.actions.allSatisfy { NSImage(systemSymbolName:commands.symbol($0.0),accessibilityDescription:nil) != nil },"Cmd-K commands have available native symbols")
        let foldingSource = (0..<20).map { "#let value\($0) = \($0)" }.joined(separator:"\n")+"\n\nAfter 日本😀"
        session.buffer.loadExternal(foldingSource); session.revision += 1; editor.refresh()
        let expandedHeight = editor.rectFor(session.buffer.projection.blocks.last!.display.location).minY
        editor.toggleCode(0)
        check(session.buffer.source == foldingSource && session.buffer.projection.blocks[0].collapsed,"Code folding leaves canonical source untouched")
        check(editor.codeButtons[0]?.accessibilityLabel() == "Expand code block","Collapsed code has an accessible disclosure control")
        check(editor.rectFor(session.buffer.projection.blocks.last!.display.location).minY < expandedHeight-100,"Collapsed code occupies one native line")
        let foldedRange = session.buffer.projection.blocks[0].display
        editor.setSelectedRange(NSRange(location:foldedRange.location+1,length:2))
        check(editor.selectedRange() == foldedRange,"Collapsed source selects as one lossless block")
        editor.setSelectedRange(foldedRange); editor.copy(nil)
        check(NSPasteboard.general.string(forType:.string) == session.buffer.source.bytes(session.buffer.projection.blocks[0].source),"Collapsed code copies its exact plain source")
        session.switchMode(.source); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(editor.string == foldingSource,"Source shows every character while Write is folded")
        session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        editor.toggleCode(0)
        check(editor.string == session.buffer.projection.text && editor.string.contains("value19"),"Expanding restores complete native code text")
        for backward in [true,false] {
            session.buffer.loadExternal(foldingSource); session.revision += 1; editor.refresh(); editor.toggleCode(0)
            let block = session.buffer.projection.blocks[0]
            editor.setSelectedRange(NSRange(location:backward ? NSMaxRange(block.display) : block.display.location,length:0)); editor.captureSelection()
            if backward { editor.deleteBackward(nil) } else { editor.deleteForward(nil) }
            check(!session.buffer.source.contains("value0") && session.buffer.source.contains("After 日本😀"),"Folded code boundary delete is atomic (backward=\(backward))")
            session.undo(); check(session.buffer.source == foldingSource,"Folded block deletion undo restores every source byte")
        }
        let boundaryTable = "Before\n\n#table(columns: 2, inset: 8pt, [日本], [], [Café], [])\n\nAfter"
        for backward in [false,true] {
            resetParagraphs(boundaryTable)
            let blocks = session.buffer.projection.blocks, table = blocks[1]
            let at = backward ? blocks[2].display.location : NSMaxRange(blocks[0].display)
            editor.setSelectedRange(NSRange(location:at,length:0)); editor.captureSelection()
            if backward { editor.deleteBackward(nil) } else { editor.deleteForward(nil) }
            check(editor.selectedRange() == table.display && session.buffer.source == boundaryTable,"Delete toward an adjacent table selects it without changing source")
            editor.copy(nil)
            check(NSPasteboard.general.string(forType:.string)?.contains("Café") == true,"Selected table retains structured clipboard content")
            if backward { editor.deleteBackward(nil) } else { editor.deleteForward(nil) }
            check(!session.buffer.source.contains("#table") && session.buffer.source.contains("Before") && session.buffer.source.contains("After"),"Second Delete removes the complete adjacent table")
            session.undo(); check(session.buffer.source == boundaryTable,"Table boundary deletion Undo restores cells, options and surrounding source")
        }
        let tableSource = "#table(columns: 2, [Idea], [Step], [One], [Two])\n\nAfter"
        session.buffer.loadExternal(tableSource)
        session.revision += 1; editor.lastRevision = -1; editor.refresh()
        RunLoop.main.run(until:Date().addingTimeInterval(0.15)); editor.ensureNativeLayout()
        func cellRange(_ index: Int) -> NSRange {
            let block = session.buffer.projection.blocks[0], local = block.cellRanges[index]
            return NSRange(location:block.display.location+local.location,length:local.length)
        }
        func textBlock(_ index: Int) -> NSTextTableBlock {
            let style = editor.textStorage!.attribute(.paragraphStyle,at:cellRange(index).location,effectiveRange:nil) as! NSParagraphStyle
            return style.textBlocks.first as! NSTextTableBlock
        }
        check(editor.textLayoutManager == nil && editor.layoutManager != nil,"Native text tables use explicit TextKit 1")
        check(textBlock(0).table === textBlock(3).table && textBlock(0).table.numberOfColumns == 2 && textBlock(3).startingRow == 1 && textBlock(3).startingColumn == 1,"NSTextTable owns cell rows and columns")
        let firstCell = editor.rectFor(cellRange(0).location), secondCell = editor.rectFor(cellRange(1).location)
        check(abs(firstCell.minY-secondCell.minY) < 1 && secondCell.minX > firstCell.maxX+50,"Native text table places adjacent cells in one row")
        check(editor.objectViews.isEmpty && editor.string.contains("Idea\nStep\nOne\nTwo"),"Table content is in the document text storage without overlay controls")
        let originalAppearance = controller.window?.appearance, originalSystemColors = session.systemColors
        session.systemColors = true
        for name in [NSAppearance.Name.aqua,.darkAqua] {
            controller.window?.appearance = NSAppearance(named:name)
            RunLoop.main.run(until:Date().addingTimeInterval(0.1)); editor.lastAppearance = ""; editor.refresh()
            var background: CGFloat = 0, foreground: CGFloat = 0
            editor.effectiveAppearance.performAsCurrentDrawingAppearance {
                background = editor.backgroundColor.usingColorSpace(.deviceRGB)!.brightnessComponent
                foreground = (editor.textStorage!.attribute(.foregroundColor,at:cellRange(0).location,effectiveRange:nil) as! NSColor).usingColorSpace(.deviceRGB)!.brightnessComponent
            }
            check(name == .darkAqua ? background < 0.25 && foreground > 0.7 : background > 0.9 && foreground < 0.3,"Native page and table text adapt to \(name.rawValue)")
            editor.focusTableCell(0,2)
            check(controller.window?.firstResponder === editor && editor.shouldDrawInsertionPoint,"Native table editing shares document focus and caret")
        }
        let originalPaper = session.paper, originalInk = session.ink
        session.systemColors = false; session.paper = .white; session.ink = .black
        controller.window?.appearance = NSAppearance(named:.darkAqua); editor.lastAppearance = ""; editor.refresh()
        editor.effectiveAppearance.performAsCurrentDrawingAppearance {
            check(editor.backgroundColor.usingColorSpace(.deviceRGB)!.brightnessComponent > 0.9 && (editor.textStorage!.attribute(.foregroundColor,at:cellRange(0).location,effectiveRange:nil) as! NSColor).usingColorSpace(.deviceRGB)!.brightnessComponent < 0.1,"Custom white page keeps black table text in a dark window")
        }
        session.paper = originalPaper; session.ink = originalInk
        controller.window?.appearance = originalAppearance; session.systemColors = originalSystemColors
        editor.lastAppearance = ""; editor.refresh()
        editor.focusTableCell(0,2); editor.insertText("Café 👋",replacementRange:editor.selectedRange())
        check(session.buffer.source.contains("[Café 👋]"),"Native table typing preserves source spans")
        editor.insertTab(nil)
        check(editor.selectedRange() == cellRange(3),"Native table Tab advances cell selection")
        editor.insertBacktab(nil)
        check(editor.selectedRange() == cellRange(2),"Native table Shift-Tab selects preceding cell")
        session.undo(); check(session.buffer.source == tableSource,"Table Undo restores exact source")
        check(editor.selectedRange() == cellRange(2),"Table Undo restores cell selection in the document")
        session.undo(true); check(editor.string.contains("Café 👋"),"Table Redo restores native text and source")
        editor.focusTableCell(0,2); editor.formatNative(false)
        check(session.buffer.source.contains("[*Café 👋*]"),"Native table formatting updates Typst markup")
        let font = editor.textStorage!.attribute(.font,at:cellRange(2).location,effectiveRange:nil) as! NSFont
        check(NSFontManager.shared.traits(of:font).contains(.boldFontMask),"Native table formatting uses a real bold face")
        editor.insertText("Replacement",replacementRange:editor.selectedRange())
        check(session.buffer.projection.blocks[0].cellProjections[2].text == "Replacement" && session.buffer.projection.blocks[0].cellProjections[2].blocks.flatMap(\.inlines).flatMap(\.runs).allSatisfy { $0.style.bold } && !session.buffer.parsed.erroneous,"Replacing a formatted cell selection retains its typing style")
        session.undo()
        editor.focusTableCell(0,2)
        editor.copy(nil)
        check(NSPasteboard.general.string(forType:.string) == "Café 👋","Native table copy retains visible Unicode text")
        editor.focusTableCell(0,3); editor.paste(nil)
        check(session.buffer.source.contains("[*Café 👋*], [*Café 👋*]"),"Native table paste preserves inline formatting")
        editor.focusTableCell(0,3); editor.setSelectedRange(NSRange(location:NSMaxRange(editor.selectedRange()),length:0)); editor.captureSelection()
        editor.insertNewline(nil); editor.insertText("Second paragraph",replacementRange:editor.selectedRange())
        check(session.buffer.source.contains("Café 👋*\n\nSecond paragraph]"),"Table Return creates a paragraph within the cell")
        check(textBlock(3).table === textBlock(2).table,"Table Return retains the native table structure")
        let start = cellRange(3).location
        editor.setSelectedRange(NSRange(location:NSMaxRange(cellRange(3)),length:0)); editor.captureSelection()
        editor.setMarkedText("に",selectedRange:NSRange(location:1,length:0),replacementRange:editor.selectedRange())
        editor.insertText("日本",replacementRange:NSRange(location:NSNotFound,length:0))
        check(session.buffer.source.contains("Second paragraph日本]"),"Native table composition commits to the correct cell")
        editor.ensureNativeLayout()
        check(editor.rectFor(NSMaxRange(cellRange(3))).minY > editor.rectFor(start).minY+10,"Native table grows with multiline cell contents")
        editor.focusTableCell(0,3); editor.insertTab(nil)
        check(session.buffer.projection.blocks[0].tableCells.count == 6,"Final table Tab adds row")
        check(editor.selectedRange() == cellRange(4) && controller.window?.firstResponder === editor,"New table row receives native document focus")
        check(!session.buffer.parsed.erroneous,"Added table row is valid Typst syntax")
        let tableBeforeDimensions = session.buffer.source
        let columnAction = editor.tableMenu(block:0,cell:1,column:true).items[1] as! TableMenuItem
        editor.changeTable(columnAction)
        check(session.buffer.projection.blocks[0].columns == 3 && controller.window?.firstResponder === editor,"Column menu changes dimensions inline and retains focus")
        session.undo(); check(session.buffer.source == tableBeforeDimensions,"Inline table dimensions share exact-source Undo")
        for column in [false,true] {
            for operation in ["before","after","delete"] {
                session.buffer.loadExternal(tableSource); session.revision += 1; editor.refresh(); editor.focusTableCell(0,1)
                let item = editor.tableMenu(block:0,cell:1,column:column).items.compactMap { $0 as? TableMenuItem }.first { $0.operation == operation }!
                editor.changeTable(item)
                let sourceAfter = session.buffer.source, selectionAfter = session.buffer.selection, nativeAfter = editor.selectedRange()
                session.undo(); session.undo(true)
                check(session.buffer.source == sourceAfter && session.buffer.selection == selectionAfter && editor.selectedRange() == nativeAfter,"Table dimension Redo restores focused cell (column=\(column), operation=\(operation))")
            }
        }
        session.buffer.loadExternal(tableBeforeDimensions); session.revision += 1; editor.refresh()
        editor.tableControlCell = (0,2); editor.positionTableControls()
        check(editor.tableButtons.count == 2 && editor.tableButtons.allSatisfy { !$0.isHidden },"Native row and column controls are visible beside table")
        let rowButton = editor.tableButtons[0], columnButton = editor.tableButtons[1]
        let rowBounds = editor.tableCellRect(block:0,cell:2)!, columnBounds = editor.tableCellRect(block:0,cell:0)!
        check(editor.tableButtons.allSatisfy { $0.frame.width >= 28 && $0.frame.height >= 28 && $0.isBordered },"Table action controls have visible native buttons and generous targets")
        check(abs(rowButton.frame.midY-rowBounds.midY) < 1 && rowButton.frame.maxX < rowBounds.minX && abs(columnButton.frame.midX-columnBounds.midX) < 1 && columnButton.frame.maxY < columnBounds.minY,"Table controls align to cell borders without covering content")
        check(editor.tableButtons.allSatisfy { ($0.cell as? NSPopUpButtonCell)?.arrowPosition == .noArrow },"Table action icons do not have crowded dropdown arrows")
        check(editor.tableButtons.allSatisfy { button in editor.hitTest(editor.convert(NSPoint(x:button.frame.midX,y:button.frame.midY),to:editor.superview)) === button },"Mouse hits reach the native table buttons instead of the text view")
        check(editor.tableButtons.allSatisfy { button in editor.accessibilityChildren()?.contains { ($0 as? NSView) === button } == true },"Native table actions are exposed to accessibility tools")
        let tableHandle = editor.tableBlockHandleRect(0)!
        check(!tableHandle.intersects(rowButton.frame) && !tableHandle.intersects(columnButton.frame),"Table block grip is separate from row and column action buttons")
        let tableHandlePoint = NSPoint(x:tableHandle.midX,y:tableHandle.midY)
        editor.mouseEntered(with:pointer(.mouseMoved,tableHandlePoint))
        check(editor.hoverBlock == 0 && NSCursor.current == .openHand,"Table block grip remains reachable with an open-hand cursor")
        editor.mouseDown(with:pointer(.leftMouseDown,tableHandlePoint))
        check(editor.grabbed == 0 && NSCursor.current == .closedHand,"Separate table grip starts a block drag")
        let tableDragPoint = NSPoint(x:tableHandlePoint.x+5,y:tableHandlePoint.y)
        editor.mouseDragged(with:pointer(.leftMouseDragged,tableDragPoint)); editor.mouseUp(with:pointer(.leftMouseUp,tableDragPoint))
        let outsideTable = session.buffer.projection.blocks.last!.display.location
        editor.setSelectedRange(NSRange(location:outsideTable,length:0)); editor.captureSelection()
        editor.tableControlCell = (0,2); editor.positionTableControls()
        let rowFrame = rowButton.frame, columnFrame = columnButton.frame
        let pointerSelection = editor.selectedRange(), pointerSource = session.buffer.source
        for x in stride(from:rowBounds.minX+4,through:rowFrame.midX,by:-2) {
            editor.mouseMoved(with:pointer(.mouseMoved,NSPoint(x:x,y:rowFrame.midY)))
            check(!rowButton.isHidden && rowButton.frame == rowFrame && editor.tableControlCell?.1 == 2,"Row control stays reachable across the table gutter")
        }
        for y in stride(from:columnBounds.minY+4,through:columnFrame.midY,by:-2) {
            editor.mouseMoved(with:pointer(.mouseMoved,NSPoint(x:columnFrame.midX,y:y)))
            check(!columnButton.isHidden && columnButton.frame == columnFrame && editor.tableControlCell.map { $0.1%2 == 0 } == true,"Column control stays reachable across the table gutter")
        }
        check(NSCursor.current == .arrow && editor.selectedRange() == pointerSelection && session.buffer.source == pointerSource,"Approaching table controls uses an arrow and preserves document selection")
        editor.tableControlCell = (0,2); editor.positionTableControls()
        let trackedMenu = rowButton.menu!
        rowButton.menuWillOpen(trackedMenu)
        editor.mouseMoved(with:pointer(.mouseMoved,NSPoint(x:editor.rectFor(cellRange(3).location).midX,y:editor.rectFor(cellRange(3).location).midY)))
        editor.positionTableControls()
        check(rowButton.menu === trackedMenu && rowButton.frame == rowFrame && editor.tableControlCell?.1 == 2,"Open table menus retain their target and menu while the pointer moves")
        rowButton.menuDidClose(trackedMenu)
        editor.mouseMoved(with:pointer(.mouseMoved,NSPoint(x:rowBounds.minX,y:editor.rectFor(outsideTable).maxY+100)))
        check(editor.tableButtons.allSatisfy(\.isHidden),"Leaving an unselected table hides its controls")
        editor.focusTableCell(0,4); editor.insertText("/",replacementRange:editor.selectedRange())
        check(Set(editor.slashMatches.map(\.kind)) == Set(["paragraph","link","footnote","citation","label","reference"]),"Cell slash menu offers only supported paragraph and inline actions")
        editor.slashQuery = "table"
        check(editor.slashMatches.isEmpty,"Cell slash filtering cannot reveal unsupported table insertion")
        editor.slashQuery = ""; editor.slashIndex = editor.slashMatches.firstIndex { $0.kind == "paragraph" }!; editor.chooseSlash()
        check(session.buffer.source.bytes(session.buffer.projection.blocks[0].tableCells[4]).isEmpty,"Cell Paragraph action removes its slash without changing table structure")
        for character in "/link" { editor.insertText(String(character),replacementRange:editor.selectedRange()) }
        editor.chooseSlash()
        check(session.sheet == .insertion && session.insertionKind == "link" && session.insertionAnchor.span.start == session.buffer.projection.blocks[0].tableCells[4].start,"Cell Link action opens insertion at the correct UTF-8 cell span")
        session.insertSource("#link(\"https://typst.app\")[Typst]")
        check(session.buffer.source.contains("[#link(\"https://typst.app\")[Typst]]") && !session.buffer.parsed.erroneous,"Supported cell slash insertion preserves valid table syntax")
        session.switchMode(.source); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        editor.selectAll(nil); editor.copy(nil)
        check(NSPasteboard.general.string(forType:.string) == session.buffer.source,"Source copies exact source after native table editing")
        session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:32,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let pixels = bitmap.bitmapData!
        for x in 0..<64 { for y in 0..<32 { let at = y*bitmap.bytesPerRow+x*4; pixels[at] = x < 32 ? 40 : 240; pixels[at+1] = x < 32 ? 100 : 140; pixels[at+2] = x < 32 ? 200 : 30; pixels[at+3] = 255 } }
        session.assets["assets/test.png"] = bitmap.representation(using:.png,properties:[:])!
        session.buffer.loadExternal("#figure(image(\(jsonString("assets/test.png")), width: 85%), caption: [A native caption])\n\nAfter")
        session.revision += 1; editor.refresh(); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(editor.objectViews[0] is FigureBlockView && loadImage("assets/test.png",session:session) != nil,"Figure renders through native AppKit image view")
        check(editor.textLayoutManager == nil,"TextKit 1 retained with native figure")
        let figureSource = session.buffer.source
        session.buffer.loadExternal(figureSource+"\n\n"+(0..<60).map { "Paragraph \($0) after the figure" }.joined(separator:"\n\n"))
        session.revision += 1; editor.refresh(); editor.scroll(.zero); editor.ensureNativeLayout(); editor.positionObjects()
        let figureOrigin = editor.objectViews[0]!.frame.origin
        editor.scroll(NSPoint(x:0,y:180)); editor.ensureNativeLayout(); editor.positionObjects()
        check(editor.objectViews[0]?.frame.origin == figureOrigin && figureOrigin.y < editor.visibleRect.minY,"Partially scrolled figure keeps its document position instead of sticking to the viewport top")
        editor.scroll(NSPoint(x:0,y:editor.blockRect(30).minY)); editor.ensureNativeLayout(); editor.positionObjects()
        check(editor.objectViews[0] == nil && editor.blockRect(0).maxY < editor.visibleRect.minY,"Fully scrolled figure leaves the viewport and releases its overlay")
        editor.scroll(.zero); editor.ensureNativeLayout(); editor.positionObjects()
        check(editor.objectViews[0]?.frame.origin == figureOrigin,"Scrolling back restores the figure at its original document position")
        session.buffer.loadExternal(figureSource); session.revision += 1; editor.refresh()
        session.switchMode(.source); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        let source = session.editor!
        source.setSelectedRange(NSRange(location:source.string.utf16.count,length:0)); source.insertText("(",replacementRange:source.selectedRange())
        check(source.string.hasSuffix("("),"Source preserves literal delimiters like Go")
        source.deleteBackward(nil); check(!source.string.hasSuffix("("),"Source uses native Backspace")
        source.insertText("\n  code",replacementRange:source.selectedRange()); source.insertNewline(nil)
        check(source.string.hasSuffix("\n  code\n  "),"Source Return retains leading indentation")
        let styledSource = "#strong[Bold] #emph[Italic]\n\n= Heading"
        session.buffer.loadExternal(styledSource); session.revision += 1; source.refresh()
        func sourceFont(_ text: String) -> NSFont {
            source.textStorage!.attribute(.font,at:(source.string as NSString).range(of:text).location,effectiveRange:nil) as! NSFont
        }
        check(NSFontManager.shared.traits(of:sourceFont("Bold")).contains(.boldFontMask) && NSFontManager.shared.traits(of:sourceFont("Italic")).contains(.italicFontMask),"Source renders strong/emph functions with actual font faces")
        check(sourceFont("Heading").pointSize > sourceFont("Italic").pointSize && source.string == styledSource,"Source headings grow while retaining every character")
        session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        session.buffer.loadExternal("= Native PDF\n\nHello *Typst*.\n\n#table(columns: 2, [A], [B])\n\n#footnote[Native footnote]\n\n#pagebreak()\n\nSecond page.\n")
        session.revision += 1; session.compile()
        let deadline = Date().addingTimeInterval(25)
        while session.compiling && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        check(session.pdf != nil,"Official Typst compiler produces native PDF")
        let sharedFile = try! SharedPDF(data:session.pdfData!,name:session.title)
        check(sharedFile.url.pathExtension == "pdf" && sharedFile.url.lastPathComponent == session.title+".pdf","Share prepares a named PDF file without Typst source")
        check((try? Data(contentsOf:sharedFile.url)) == session.pdfData && PDFDocument(url:sharedFile.url)?.string?.contains("Native PDF") == true,"Native sharing supplies the current compiler PDF")
        let clipboardPDF = try! SharedPDF(data:session.pdfData!,name:"Clipboard PDF").url
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([clipboardPDF as NSURL])
        for index in 0..<12 { _ = try! SharedPDF(data:session.pdfData!,name:"Cache \(index)") }
        let shareCache = AppController.dataDirectory.appendingPathComponent("shared-pdfs")
        let cachedCount = (try? FileManager.default.contentsOfDirectory(atPath:shareCache.path).count) ?? 100
        check(FileManager.default.fileExists(atPath:clipboardPDF.path) && cachedCount <= 10,"Share cache stays bounded while preserving the PDF copied to the native clipboard (\(cachedCount) cached, clipboard exists: \(FileManager.default.fileExists(atPath:clipboardPDF.path)))")
        check(!session.sourceMap.isEmpty,"Preview carries source navigation map")
        session.switchMode(.preview); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        guard let pdfView = session.pdfView, let secondPage = session.pdf?.page(at:1) else { fatalError("Missing two-page preview") }
        // PDFKit sends this same notification for wheel/trackpad page changes.
        // Navigate directly instead of routing through the page-counter action.
        pdfView.go(to:secondPage); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(session.previewPage == 2,"Preview page counter follows native PDF navigation")
        NativeGoAcceptance.preview(controller:controller)
        let zoom = controller.zoomItem!
        check(!zoom.isHidden,"PDF zoom controls appear in Preview")
        zoom.selectedIndex = 1; controller.zoomPreview(zoom)
        check(pdfView.scaleFactor == 1 && !pdfView.autoScales,"Actual Size uses PDFKit's 100-percent scale")
        zoom.selectedIndex = 2; controller.zoomPreview(zoom)
        check(pdfView.scaleFactor > 1,"Zoom In increases native PDF scale")
        zoom.selectedIndex = 0; controller.zoomPreview(zoom)
        check(pdfView.scaleFactor <= 1.001,"Zoom Out reverses native PDF zoom")
        NativeSidebarAcceptance.preview(controller:controller)
        session.searchQuery = "Second page"; session.find()
        check(pdfView.currentSelection?.string?.contains("Second page") == true,"Toolbar Find selects text in PDF Preview")
        session.searchQuery = ""
        session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        let good = session.pdf
        session.buffer.loadExternal("#unknown-function()")
        session.revision += 1; session.compile()
        let failureDeadline = Date().addingTimeInterval(10)
        while session.compiling && Date() < failureDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        check(session.pdf === good && session.error != nil,"Compilation errors preserve last successful PDF")
        var failedShare: Result<Data,any Error>?
        session.requestPDF { failedShare = $0 }
        let failedShareDeadline = Date().addingTimeInterval(10)
        while failedShare == nil && Date() < failedShareDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        if case .failure? = failedShare { check(session.pdf === good,"Sharing invalid source reports an error instead of sharing the previous PDF") }
        else { fatalError("Invalid source was shared as a PDF") }
        session.buffer.loadExternal("= Share snapshot\n\nPDF sharing revision check."); session.revision += 1
        var staleShare: Result<Data,any Error>?
        session.requestPDF { staleShare = $0 }; session.revision += 1
        let staleShareDeadline = Date().addingTimeInterval(10)
        while staleShare == nil && Date() < staleShareDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        if case .failure? = staleShare { check(true,"Changing source during PDF preparation rejects a stale share") }
        else { fatalError("Stale PDF revision was shared") }
        // A share requested during an older compilation must wait for its own
        // revision, provided no further edit occurs after the request.
        session.compile(); session.buffer.loadExternal("= Latest share\n\nNewest revision."); session.revision += 1
        var latestShare: Result<Data,any Error>?
        session.requestPDF { latestShare = $0 }
        let latestShareDeadline = Date().addingTimeInterval(10)
        while latestShare == nil && Date() < latestShareDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        if case let .success(data)? = latestShare { check(PDFDocument(data:data)?.string?.contains("Latest share") == true,"Share waits for its current revision behind an older compilation") }
        else { fatalError("Current PDF share did not finish behind older compilation") }
        session.buffer.loadExternal("#figure(image(\"assets/test.png\"), caption: [A caption])")
        session.revision += 1
        let exported = FileManager.default.temporaryDirectory.appendingPathComponent("blank-export-"+UUID().uuidString+".pdf")
        session.compile(); session.compile(export:exported)
        let exportDeadline = Date().addingTimeInterval(10)
        while session.compiling && Date() < exportDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        check((try? Data(contentsOf:exported).starts(with:Data("%PDF-".utf8))) == true,"PDF export queued during compilation includes imported figure and caption")
        try? FileManager.default.removeItem(at:exported)
        // Exercise the same Tutorial action used by Help, Cmd-K and --tutorial.
        let application = AppController.shared!
        application.tutorial(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        let tutorialWindow = application.controllers.last!
        check(tutorialWindow.session.sidebar && tutorialWindow.sidebarItem?.toolTip?.hasPrefix("Hide") == true,"Tutorial opens with Contents pinned for discovery")
        check(tutorialWindow.session.buffer.source == tutorial && tutorialWindow.session.headings.contains { $0.1.level == 3 },"Tutorial is a fresh editable copy with nested headings")
        if let root = tutorialWindow.window?.contentView {
            func rows(_ view: NSView) -> [ContentsRowView] { (view as? ContentsRowView).map { [$0] } ?? view.subviews.flatMap(rows) }
            let visibleRows = rows(root).filter { !$0.visibleRect.isEmpty }
            check(!visibleRows.isEmpty && visibleRows.allSatisfy { row in
                root.hitTest(row.convert(NSPoint(x:row.bounds.midX,y:row.bounds.midY),to:root.superview)) === row
            },"Sidebar mouse hits reach native navigation and drag rows")
        }
        tutorialWindow.window?.close()
        print("Native acceptance completed")
        FileAcceptance.run()
        NativeDocumentAcceptance.run()
        session.saveWork?.cancel(); controller.window?.close()
    }
}

@MainActor final class ContentsTestDrag: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name:NSPasteboard.Name("blank-contents-acceptance"))
    var draggingSource: Any?
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight = .none
    init(source: ContentsRowView,window: NSWindow) { draggingSource = source; draggingDestinationWindow = window }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions,for view: NSView?,classes classArray: [AnyClass],searchOptions: [NSPasteboard.ReadingOptionKey:Any],using block: (NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>)->Void) {}
    func resetSpringLoading() {}
}
