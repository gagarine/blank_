import AppKit
import BlankCore

@MainActor enum NativeSelectionStyleAcceptance {
    static func showFixture(controller: DocumentWindow) {
        let session = controller.session
        session.buffer.loadExternal("= Selection styles\n\nSelect café 日本 and change its inline style.\n\nA paragraph for whole-block conversion.\n\n```typ\n#let answer = 42\n```\n\n#table(columns: 2, [Native cell], [Other cell])")
        session.revision += 1; session.editor?.refresh()
        guard let editor = session.editor else { return }
        controller.window?.makeFirstResponder(editor)
        editor.setSelectedRange((editor.string as NSString).range(of:"café 日本")); editor.captureSelection(); editor.scrollRangeToVisible(editor.selectedRange()); editor.ensureNativeLayout()
        editor.updateSelectionPanel(requireKeyWindow:false)
    }

    static func run(controller: DocumentWindow) {
        let session = controller.session, editor = session.editor!
        func check(_ value: @autoclosure () -> Bool,_ label: String) {
            guard value() else { fatalError("FAIL: \(label) | \(session.buffer.source) | \(editor.selectedRange())") }; print("PASS: \(label)")
        }
        func load(_ source: String) {
            session.buffer.loadExternal(""); session.buffer.loadExternal(source); session.revision += 1; editor.clearInsertionStyle(); editor.refresh()
            controller.window?.makeKeyAndOrderFront(nil); controller.window?.makeFirstResponder(editor); editor.scrollRangeToVisible(NSRange(location:0,length:0))
        }
        NSApp.activate(ignoringOtherApps:true); RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        let original = "Before café 👩🏽‍💻 after\n\n#let custom = 42"
        load(original)
        let range = (editor.string as NSString).range(of:"café 👩🏽‍💻")
        editor.setSelectedRange(range); editor.captureSelection(); editor.scrollRangeToVisible(range); editor.ensureNativeLayout(); editor.updateSelectionPanel(requireKeyWindow:false)
        let cpu = ResourceMetrics.cpuSeconds(), start = Date()
        for _ in 0..<10 { editor.updateSelectionPanel(requireKeyWindow:false) }
        print(String(format:"Selection panel: 10 small-document updates %.1f ms wall, %.1f ms CPU; acceptance-process RSS %.1f MiB",Date().timeIntervalSince(start)*1000,(ResourceMetrics.cpuSeconds()-cpu)*1000,ResourceMetrics.residentMiB()))
        check(editor.selectionPanel?.isVisible == true && controller.window?.firstResponder === editor,"Selection panel appears without stealing native text focus")
        if let content = editor.selectionPanel?.contentViewController?.view, let panelWindow = content.window {
            func controls(_ view: NSView) -> [SelectionButtonCursorView] { (view as? SelectionButtonCursorView).map { [$0] } ?? view.subviews.flatMap(controls) }
            let buttons = controls(content)
            check(!buttons.isEmpty,"Selection panel exposes native cursor regions for its controls")
            let source = session.buffer.source, selection = editor.selectedRange()
            for button in buttons where button.enabled {
                let rect = panelWindow.convertToScreen(button.convert(button.bounds,to:nil)), screen = NSPoint(x:rect.midX,y:rect.midY)
                let event = NSEvent.mouseEvent(with:.mouseMoved,location:controller.window!.convertPoint(fromScreen:screen),modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:1,clickCount:0,pressure:0)!
                NSCursor.iBeam.set(); editor.mouseMoved(with:event); check(NSCursor.current == .pointingHand,"Selection buttons own the pointing-hand cursor over underlying editor text")
                NSCursor.iBeam.set(); editor.cursorUpdate(with:event); check(NSCursor.current == .pointingHand,"Editor cursor updates respect selection-panel controls")
            }
            check(session.buffer.source == source && editor.selectedRange() == selection,"Selection-panel pointer tracking preserves source and selection")
        }
        editor.formatNative(.superscript); editor.selectionAttribute("color","#247cb7"); editor.selectionAttribute("highlight","#fff2a6"); editor.selectionAttribute("link","https://example.com")
        check(editor.selectedRange() == range && editor.string.hasPrefix("Before café 👩🏽‍💻 after"),"Panel actions preserve the selected Unicode text")
        check((editor.textStorage?.attribute(.baselineOffset,at:range.location,effectiveRange:nil) as? Double ?? 0) > 0 && editor.textStorage?.attribute(.backgroundColor,at:range.location,effectiveRange:nil) != nil,"Superscript and source-backed highlight render in native text")
        let styled = session.buffer.source
        for _ in 0..<4 { session.undo() }
        check(session.buffer.source == original,"Panel inline styles share source Undo")
        for _ in 0..<4 { session.undo(true) }
        check(session.buffer.source == styled,"Panel inline styles share source Redo")
        editor.selectionAlignment("center")
        check(session.buffer.projection.blocks[0].alignment == "center" && (editor.textStorage?.attribute(.paragraphStyle,at:range.location,effectiveRange:nil) as? NSParagraphStyle)?.alignment == .center,"Panel alignment applies to the complete native paragraph")
        editor.selectionAlignment(nil)
        check(session.buffer.projection.blocks[0].alignment == nil && session.buffer.source == styled && editor.selectedRange() == range,"Default alignment removes the Typst wrapper while preserving Unicode selection and inline styles")
        session.undo(); check(session.buffer.projection.blocks[0].alignment == "center","Default alignment shares source Undo")
        session.undo(true); check(session.buffer.source == styled,"Default alignment shares source Redo")
        editor.selectionAlignment("center")
        editor.selectionBlockStyle(SlashCommand.blockStyles.first { $0.kind == "heading" && $0.level == 2 }!)
        check(session.buffer.projection.blocks[0].kind == "heading" && session.buffer.projection.blocks[0].text == "Before café 👩🏽‍💻 after" && session.buffer.projection.blocks[0].alignment == "center","Panel Turn into converts the whole block and retains alignment")
        editor.setSelectedRange(NSRange(location:0,length:0)); editor.updateSelectionPanel(requireKeyWindow:false)
        check(editor.selectionPanel?.isVisible == false,"Selection panel hides for a caret")
        session.switchMode(.source); editor.updateSelectionPanel(requireKeyWindow:false); check(editor.selectionPanel?.isVisible == false,"Selection panel hides in Source")
        session.switchMode(.write)
        load("Before\n\n"+rawTypst("#let x = 2\n日本👩🏽‍💻",block:true)+"\n\nAfter")
        let block = session.buffer.projection.blocks[1], interior = (block.text as NSString).range(of:"日本👩🏽‍💻")
        editor.setSelectedRange(NSRange(location:block.display.location+interior.location,length:interior.length)); editor.captureSelection()
        let before = session.buffer.source
        for backward in [false,true] {
            let character = backward ? "\u{7f}" : "\u{f728}"
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:backward ? 51 : 117)!
            editor.keyDown(with:event)
            check(session.buffer.projection.blocks[1].kind == "raw" && session.buffer.projection.blocks[1].text == "#let x = 2\n" && session.buffer.source.hasSuffix("\n\nAfter"),"Native Delete edits displayed code literally with protected fences")
            session.undo(); check(session.buffer.source == before,"Displayed code Delete restores exact source and selection through Undo")
        }
        editor.setSelectedRange(NSRange(location:block.display.location+2,length:0)); editor.captureSelection(); editor.insertNewline(nil)
        check(session.buffer.projection.blocks[1].kind == "raw" && !session.buffer.parsed.erroneous,"Native Return stays inside a displayed code block")
        session.undo()
        load("#table(columns: 2, inset: 8pt, [日本], [Other])")
        editor.focusTableCell(0,0); editor.selectionAttribute("highlight","#fff2a6"); editor.formatNative(.subscripted)
        check(session.buffer.source.contains("inset: 8pt") && session.buffer.projection.blocks[0].cellProjections[0].blocks[0].inlines.flatMap(\.runs).allSatisfy { $0.style.subscripted && $0.style.highlight == "#fff2a6" },"Selection panel inline styles preserve native table options and cell editing")
        for alignment in ["center","justified"] {
            let wrapper = alignment == "center" ? "#align(center)[" : "#par(justify: true)["
            let original = "Before\n\n"+wrapper+"*日本👩🏽‍💻* after]\n\nAfter"
            load(original); let paragraph = session.buffer.projection.blocks[1]
            editor.setSelectedRange(NSRange(location:paragraph.display.location+2,length:0)); editor.captureSelection(); editor.insertNewline(nil)
            check(session.buffer.projection.blocks.count == 4 && session.buffer.projection.blocks[1].alignment == alignment && session.buffer.projection.blocks[2].alignment == alignment && editor.selectedRange().location == session.buffer.projection.blocks[2].display.location,"Native Return keeps aligned paragraphs editable and places the caret in the next block")
            session.undo(); check(session.buffer.source == original,"Aligned Return restores exact source and caret through Undo")
        }
        load("Before café after")
        let linkedWord = (editor.string as NSString).range(of:"café")
        editor.setSelectedRange(linkedWord); editor.captureSelection(); editor.selectionLink()
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        func descendants(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
        if let sheet = controller.window?.attachedSheet, let content = sheet.contentView {
            let controls = descendants(content)
            let field = controls.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "https://example.com" }
            check(field != nil,"Panel Link opens the native URL field")
            field?.stringValue = "https://example.com/café"
            controls.compactMap { $0 as? NSButton }.first { $0.title == "Apply" }?.performClick(nil)
            RunLoop.main.run(until:Date().addingTimeInterval(0.1))
            check(controller.window?.attachedSheet == nil && controller.window?.firstResponder === editor && editor.selectedRange() == linkedWord && session.buffer.source.contains("#link("),"Applying a panel link restores native editing focus and selection")
            session.undo(); check(session.buffer.source == "Before café after","Panel link application shares source Undo")
        } else { check(false,"Panel Link presents a native sheet") }
        load("Before café after")
        let word = (editor.string as NSString).range(of:"café")
        editor.setSelectedRange(word); editor.captureSelection(); editor.formatNative(.superscript); editor.selectionAttribute("color","#247cb7"); editor.selectionAttribute("highlight","#fff2a6")
        let composedBefore = session.buffer.source
        editor.setMarkedText("日本👩🏽‍💻",selectedRange:NSRange(location:2,length:0),replacementRange:editor.selectedRange()); editor.unmarkText()
        check(editor.string == "Before 日本👩🏽‍💻 after" && !session.buffer.parsed.erroneous && session.buffer.projection.blocks[0].inlines.flatMap(\.runs).contains { $0.style.superscript && $0.style.color == "#247cb7" && $0.style.highlight == "#fff2a6" },"Marked-text composition retains panel styles and surrounding source")
        session.undo(); check(session.buffer.source == composedBefore,"Styled composition shares exact-source Undo")
        load("Before `café` after")
        editor.setSelectedRange((editor.string as NSString).range(of:"café")); editor.captureSelection()
        let codeBefore = session.buffer.source
        editor.setMarkedText("日本`#",selectedRange:NSRange(location:2,length:0),replacementRange:editor.selectedRange()); editor.unmarkText()
        check(editor.string == "Before 日本`# after" && !session.buffer.parsed.erroneous,"Inline-code composition preserves literal backticks and syntax markers")
        session.undo(); check(session.buffer.source == codeBefore,"Inline-code composition restores exact source through Undo")
        load("Before #cite(<demo>) after")
        editor.setSelectedRange((editor.string as NSString).range(of:"Before")); editor.captureSelection(); editor.ensureNativeLayout(); editor.updateSelectionPanel(requireKeyWindow:false)
        check(editor.selectionPanel?.isVisible == true,"Selection panel styles prose beside an atomic citation")
        editor.setSelectedRange((editor.string as NSString).range(of:"Citation")); editor.captureSelection(); editor.updateSelectionPanel(requireKeyWindow:false)
        check(editor.selectionPanel?.isVisible == false,"Selection panel leaves atomic citation editing to its field editor")
        editor.setSelectedRange(NSRange(location:0,length:0)); editor.selectionPanel?.orderOut(nil)
        load("")
    }
}
