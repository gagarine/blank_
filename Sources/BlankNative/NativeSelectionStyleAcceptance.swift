import AppKit
import BlankCore

@MainActor enum NativeSelectionStyleAcceptance {
    static func showFixture(controller: DocumentWindow) {
        let session = controller.session
        session.buffer.loadExternal("= Selection styles\n\nSelect #link(\"https://example.com\")[café 日本] and change its inline style.\n\nA paragraph for whole-block conversion.\n\n```typ\n#let answer = 42\n```\n\n#table(columns: 2, [Native cell], [Other cell])")
        session.revision += 1; session.editor?.refresh()
        guard let editor = session.editor else { return }
        controller.window?.makeFirstResponder(editor)
        editor.setSelectedRange((editor.string as NSString).range(of:"café 日本")); editor.captureSelection(); editor.scrollRangeToVisible(editor.selectedRange()); editor.ensureNativeLayout()
        editor.updateSelectionPanel(requireKeyWindow:false)
        if CommandLine.arguments.contains("--link-hover-ui-test") {
            let range = editor.selectedRange(); editor.setSelectedRange(NSRange(location:range.location,length:0)); editor.captureSelection(); editor.updateSelectionPanel(requireKeyWindow:false)
            let rect = editor.documentGlyphRect(NSRange(location:range.location,length:1))
            editor.updateLinkHover(at:NSPoint(x:rect.midX,y:rect.midY),delay:0)
        }
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
        func panelButtons(_ panel: SelectionStylePanel?) -> [SelectionButtonCursorView] {
            func descendants(_ view: NSView) -> [SelectionButtonCursorView] { (view as? SelectionButtonCursorView).map { [$0] } ?? view.subviews.flatMap(descendants) }
            guard let root = panel?.contentViewController?.view else { return [] }
            func rect(_ view: NSView) -> NSRect { view.window!.convertToScreen(view.convert(view.bounds,to:nil)) }
            return descendants(root).sorted { a,b in
                let x = rect(a), y = rect(b)
                return abs(x.midY-y.midY) > 1 ? x.midY > y.midY : x.midX < y.midX
            }
        }
        func clickPadding(_ button: SelectionButtonCursorView,trailing: Bool = false) {
            guard let window = button.window else { check(false,"Formatting control has a native window"); return }
            let point = button.convert(NSPoint(x:trailing ? button.bounds.maxX-3 : button.bounds.minX+3,y:button.bounds.midY),to:nil)
            func event(_ type: NSEvent.EventType) -> NSEvent { NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)! }
            let down = event(.leftMouseDown)
            NSApp.postEvent(event(.leftMouseUp),atStart:true); window.sendEvent(down)
            if let up = NSApp.nextEvent(matching:.leftMouseUp,until:Date(),inMode:.default,dequeue:true) { window.sendEvent(up) }
            RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        }
        let mainContent = editor.selectionPanel?.contentViewController?.view, mainFrame = editor.selectionPanel?.contentViewController?.view.window?.frame
        let toolbarButtons = panelButtons(editor.selectionPanel)
        check(toolbarButtons.count == 9,"Selection toolbar exposes all supported controls")
        clickPadding(toolbarButtons[0],trailing:true)
        check(editor.selectionPanel?.child?.isShown == true && editor.selectionPanel?.isShown == true && editor.selectionPanel?.contentViewController?.view === mainContent && mainContent?.window?.frame == mainFrame,"Block-style button padding opens a secondary panel without replacing or moving the inline toolbar")
        check(AppController.shared.current === session,"Formatting popover focus retains the document's menu context")
        clickPadding(toolbarButtons[7])
        check(editor.selectionPanel?.child?.isShown == true && panelButtons(editor.selectionPanel?.child).count == 20 && editor.selectionPanel?.contentViewController?.view === mainContent,"Color-button padding opens both palettes beside the persistent toolbar")
        let colorButtons = panelButtons(editor.selectionPanel?.child)
        for button in colorButtons {
            let screen = button.window!.convertPoint(toScreen:button.convert(NSPoint(x:button.bounds.minX+3,y:button.bounds.midY),to:nil))
            let event = NSEvent.mouseEvent(with:.mouseMoved,location:controller.window!.convertPoint(fromScreen:screen),modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:1,clickCount:0,pressure:0)!
            NSCursor.iBeam.set(); editor.cursorUpdate(with:event)
            check(NSCursor.current == .pointingHand,"Secondary-panel button padding owns the pointing-hand cursor over editor text")
        }
        clickPadding(colorButtons[6])
        check(session.buffer.source.contains("#text(fill: rgb(\"#247cb7\"))[") && editor.selectedRange() == range && editor.selectionPanel?.isShown == true,"Clicking outside a color swatch applies its color while preserving selection and the toolbar")
        session.undo(); check(session.buffer.source == original,"Padded color-button actions retain shared source Undo")
        editor.updateSelectionPanel(requireKeyWindow:false)
        let currentButtons = panelButtons(editor.selectionPanel)
        clickPadding(currentButtons[8],trailing:true)
        check(editor.selectionPanel?.child?.isShown == true && editor.selectionPanel?.isShown == true,"More-button padding opens alignment options beside the toolbar")
        let moreButtons = panelButtons(editor.selectionPanel?.child)
        check(moreButtons.count == 7,"More styles exposes inline marks and supported alignment choices")
        clickPadding(moreButtons[4],trailing:true)
        check(session.buffer.projection.blocks[0].alignment == "center" && editor.selectedRange() == range && editor.selectionPanel?.isShown == true,"Trailing alignment-row padding applies the whole-block alignment and keeps the toolbar")
        session.undo(); check(session.buffer.source == original,"Padded alignment-row actions retain exact-source Undo")
        editor.updateSelectionPanel(requireKeyWindow:false)
        clickPadding(panelButtons(editor.selectionPanel)[7])
        let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
        editor.keyDown(with:escape); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(editor.selectionPanel?.child?.isShown != true && editor.selectionPanel?.isShown == true,"Escape dismisses formatting options while preserving the main toolbar")
        clickPadding(panelButtons(editor.selectionPanel)[7])
        check(editor.selectionPanel?.child?.isShown == true,"A secondary panel reopens with one click after Escape")
        clickPadding(panelButtons(editor.selectionPanel)[7],trailing:true)
        check(editor.selectionPanel?.child?.isShown != true && editor.selectionPanel?.isShown == true && controller.window?.firstResponder === editor,"The active toolbar button dismisses only the secondary panel and retains editing focus")
        editor.formatNative(.superscript); editor.selectionAttribute("color","#247cb7"); editor.selectionAttribute("highlight","#fff2a6"); editor.selectionAttribute("link","https://example.com")
        check(editor.textStorage?.attribute(.link,at:range.location,effectiveRange:nil) == nil && !editor.isAutomaticLinkDetectionEnabled,"Write links remain selectable text instead of AppKit click targets")
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
        let linkedSource = "Before #link(\"https://example.com\")[*café 日本👩🏽‍💻*]#link(\"https://example.com\")[ next] after\n\n// keep this comment\n#let custom = 42"
        load(linkedSource)
        let linkedText = (editor.string as NSString).range(of:"café 日本👩🏽‍💻")
        editor.setSelectedRange(NSRange(location:linkedText.location+2,length:0)); editor.captureSelection(); editor.ensureNativeLayout()
        let caret = editor.selectedRange(), hit = editor.documentGlyphRect(NSRange(location:linkedText.location+1,length:1))
        let point = NSPoint(x:hit.midX,y:hit.midY)
        let hoverCPU = ResourceMetrics.cpuSeconds(), hoverStart = Date()
        for _ in 0..<100 { _ = editor.linkTarget(at:point) }
        print(String(format:"Link hover: 100 small-document hit checks %.1f ms wall, %.1f ms CPU; acceptance-process RSS %.1f MiB",Date().timeIntervalSince(hoverStart)*1000,(ResourceMetrics.cpuSeconds()-hoverCPU)*1000,ResourceMetrics.residentMiB()))
        if let target = editor.linkTarget(at:point) {
            check(target.range == linkedText,"Link hover identifies the complete styled Unicode link independently of an adjacent identical URL")
            let hoverEvent = NSEvent.mouseEvent(with:.mouseMoved,location:editor.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:1,clickCount:0,pressure:0)!
            editor.mouseMoved(with:hoverEvent)
            check(editor.linkPanel?.isShown != true,"Brief pointer movement over a link does not immediately show a panel")
            RunLoop.main.run(until:Date().addingTimeInterval(0.4))
            check(editor.linkPanel?.isShown == true && editor.selectedRange() == caret && controller.window?.firstResponder === editor,"Link hover presents native actions without moving the caret or taking editing focus")
            if let content = editor.linkPanel?.contentViewController?.view, let panelWindow = content.window {
                func buttons(_ view: NSView) -> [SelectionButtonCursorView] { (view as? SelectionButtonCursorView).map { [$0] } ?? view.subviews.flatMap(buttons) }
                check(buttons(content).count == 2,"Link hover exposes Open Link and Remove Link controls")
                for button in buttons(content) {
                    let rect = panelWindow.convertToScreen(button.convert(button.bounds,to:nil)), screen = NSPoint(x:rect.midX,y:rect.midY)
                    let event = NSEvent.mouseEvent(with:.mouseMoved,location:controller.window!.convertPoint(fromScreen:screen),modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:1,clickCount:0,pressure:0)!
                    NSCursor.iBeam.set(); editor.cursorUpdate(with:event)
                    check(NSCursor.current == .pointingHand,"Link hover actions retain pointing-hand cursors above editor text")
                }
            }
            editor.removeHoveredLink(target)
            let removed = "Before *café 日本👩🏽‍💻*#link(\"https://example.com\")[ next] after\n\n// keep this comment\n#let custom = 42"
            check(session.buffer.source == removed && editor.selectedRange() == caret && editor.linkPanel?.isShown != true,"Hover Remove Link preserves exact styled body, adjacent link, comments and native caret")
            session.undo(); check(session.buffer.source == linkedSource && editor.selectedRange() == caret,"Hover link removal shares exact-source Undo and Unicode caret restoration")
            session.undo(true); check(session.buffer.source == removed && editor.selectedRange() == caret,"Hover link removal shares exact-source Redo and Unicode caret restoration")
            let afterRemoval = session.buffer.source
            editor.removeHoveredLink(target); check(session.buffer.source == afterRemoval,"Stale link hover actions cannot modify a newer document revision")
        } else { check(false,"Styled link exposes a glyph hover target") }
        load(linkedSource); editor.setSelectedRange(caret); editor.captureSelection(); editor.ensureNativeLayout()
        let pendingHit = editor.documentGlyphRect(NSRange(location:linkedText.location+1,length:1))
        editor.updateLinkHover(at:NSPoint(x:pendingHit.midX,y:pendingHit.midY),delay:0.05); editor.dismissLinkHover()
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(editor.linkPanel?.isShown != true && editor.hoveredLink == nil,"Leaving a link cancels its pending hover presentation")
        editor.updateLinkHover(at:NSPoint(x:pendingHit.midX,y:pendingHit.midY),delay:0)
        session.switchMode(.source)
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(editor.linkPanel?.isShown != true,"Switching to Source dismisses link hover actions")
        session.switchMode(.write)
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        for backward in [false,true] {
            load(linkedSource); editor.setSelectedRange((editor.string as NSString).range(of:"日本👩🏽‍💻")); editor.captureSelection()
            let character = backward ? "\u{7f}" : "\u{f728}"
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:backward ? 51 : 117)!
            editor.keyDown(with:event)
            check(session.buffer.source.contains("#link(\"https://example.com\")[*café *]") && session.buffer.source.hasSuffix("// keep this comment\n#let custom = 42"),"Native Delete edits selected linked Unicode text without following its destination")
            session.undo(); check(session.buffer.source == linkedSource,"Linked native Delete restores exact source through Undo")
        }
        load("#table(columns: 2, inset: 8pt, [Before #link(\"https://example.com\")[*日本*] after], [Other])")
        let tableSource = session.buffer.source, tableWord = (editor.string as NSString).range(of:"日本")
        editor.setSelectedRange(NSRange(location:tableWord.location+1,length:0)); editor.captureSelection(); editor.ensureNativeLayout()
        let tableHit = editor.documentGlyphRect(NSRange(location:tableWord.location,length:1))
        if let target = editor.linkTarget(at:NSPoint(x:tableHit.midX,y:tableHit.midY)) {
            check(target.range == tableWord && editor.textStorage?.attribute(.link,at:tableWord.location,effectiveRange:nil) == nil,"Native table links expose hover actions while remaining ordinary editable text")
            editor.removeHoveredLink(target)
            check(session.buffer.source == "#table(columns: 2, inset: 8pt, [Before *日本* after], [Other])","Hover Remove Link preserves native table options and surrounding cell source")
            session.undo(); check(session.buffer.source == tableSource,"Native table link removal restores exact source through shared Undo")
        } else { check(false,"Native table link exposes a glyph hover target") }
        load("Before #link(\"https://example.com\")[*café*]*日本* after")
        let adjacentText = editor.string, adjacentSource = session.buffer.source
        editor.setSelectedRange(NSRange(location:7,length:0)); editor.captureSelection(); editor.ensureNativeLayout()
        let adjacentHit = editor.documentGlyphRect(NSRange(location:7,length:1))
        if let target = editor.linkTarget(at:NSPoint(x:adjacentHit.midX,y:adjacentHit.midY)) {
            editor.removeHoveredLink(target)
            check(editor.string == adjacentText && !session.buffer.parsed.erroneous && session.buffer.projection.blocks[0].inlines.flatMap(\.runs).filter { $0.text.contains("café") || $0.text.contains("日本") }.allSatisfy { $0.style.bold },"Hover removal preserves adjacent inline formatting boundaries")
            session.undo(); check(session.buffer.source == adjacentSource,"Adjacent-mark link removal has exact-source Undo")
        } else { check(false,"Adjacent-mark link exposes a hover target") }
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
