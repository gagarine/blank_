import AppKit
import PDFKit
import BlankCore

@MainActor enum NativeAcceptance {
    static func run() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        setbuf(stdout,nil)
        let originalClipboard = NSPasteboard.general.pasteboardItems?.map { item in Dictionary(uniqueKeysWithValues:item.types.compactMap { type in item.data(forType:type).map { (type,$0) } }) } ?? []
        defer {
            NSPasteboard.general.clearContents()
            let items = originalClipboard.map { contents -> NSPasteboardItem in let item = NSPasteboardItem(); for (type,data) in contents { item.setData(data,forType:type) }; return item }
            NSPasteboard.general.writeObjects(items)
        }
        let session = DocumentSession()
        let controller = DocumentWindow(session:session); controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps:true)
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        guard let view = session.editor else { fatalError("No native editor") }
        func check(_ condition: @autoclosure () -> Bool,_ label: String) { if !condition() { fatalError("FAIL: \(label) | source=\(session.buffer.source) | native=\(view.string)") }; print("PASS: \(label)") }
        check(view.textLayoutManager != nil,"TextKit 2 active at creation")
        check(controller.window?.firstResponder === view,"Empty editor is focused")
        check(view.string.isEmpty,"Launch has no welcome screen")
        check(controller.window?.styleMask.contains(.fullSizeContentView) == true && controller.window?.titlebarAppearsTransparent == true,"Document extends beneath native transparent toolbar")
        for scalar in "Hello café 👩🏽‍💻".unicodeScalars { view.insertText(String(scalar),replacementRange:view.selectedRange()) }
        check(session.buffer.projection.text == "Hello café 👩🏽‍💻","Native typing and Unicode")
        view.textLayoutManager?.ensureLayout(for:view.visibleRect)
        let firstLineEnd = view.rectFor(view.selectedRange().location)
        view.insertNewline(nil)
        view.textLayoutManager?.ensureLayout(for:view.visibleRect)
        let emptyParagraph = view.rectFor(view.selectedRange().location)
        check(emptyParagraph.minY-firstLineEnd.minY >= firstLineEnd.height+12,"Return shows paragraph spacing before typing")
        check(controller.window?.firstResponder === view && view.shouldDrawInsertionPoint,"Return keeps focus and a native insertion point")
        view.insertText("Second paragraph",replacementRange:view.selectedRange())
        check(session.buffer.projection.blocks.count == 2,"Return splits paragraph")
        view.textLayoutManager?.ensureLayout(for:view.visibleRect)
        let paragraphEnd = view.rectFor(view.selectedRange().location)
        view.insertLineBreak(nil)
        view.textLayoutManager?.ensureLayout(for:view.visibleRect)
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
        check(session.editor?.textLayoutManager != nil,"TextKit 2 retained after switching")
        check(session.editor?.isAutomaticQuoteSubstitutionEnabled == session.editor?.inputDefaults?.quotes,"Write restores native input preferences after Source")
        session.undo(); check(!session.buffer.source.contains("*Hello*"),"Undo shared across views")
        session.undo(true); check(session.buffer.source.contains("*Hello*"),"Redo shared across views")
        let editor = session.editor!
        editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0)); editor.captureSelection()
        editor.setMarkedText("に",selectedRange:NSRange(location:1,length:0),replacementRange:editor.selectedRange())
        editor.setMarkedText("日本",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        editor.insertText("日本",replacementRange:NSRange(location:NSNotFound,length:0))
        check(session.buffer.projection.text.hasSuffix("日本"),"Native marked-text composition commits once")
        check(editor.textLayoutManager != nil,"TextKit 2 retained through composition")
        editor.formatNative(false)
        editor.insertText("A",replacementRange:editor.selectedRange()); editor.insertText("B",replacementRange:editor.selectedRange())
        check(session.buffer.projection.text.hasSuffix("日本AB") && !session.buffer.parsed.erroneous,"Bold typing remains valid across keystrokes")
        editor.formatNative(false); editor.insertText("C",replacementRange:editor.selectedRange())
        check(!session.buffer.projection.blocks.last!.inlines.flatMap(\.runs).last!.style.bold && !session.buffer.parsed.erroneous,"Bold typing can be turned off inside a word")
        editor.insertionBold = nil
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
        resetParagraphs("Left selected right")
        editor.setSelectedRange(NSRange(location:5,length:8)); editor.captureSelection(); editor.insertNewline(nil)
        check(session.buffer.projection.blocks.map(\.text) == ["Left","right"],"Return replaces selection and splits its paragraph")
        session.undo(); check(session.buffer.source == "Left selected right","Selected Return is one undo transaction")
        session.buffer.loadExternal("Slash target"); session.revision += 1; editor.refresh()
        editor.setSelectedRange(NSRange(location:0,length:0)); editor.captureSelection()
        for scalar in "/heading".unicodeScalars { editor.insertText(String(scalar),replacementRange:editor.selectedRange()) }
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(editor.slashPopover?.isShown == true && (editor.slashPopover?.contentViewController?.view.bounds.height ?? 0) >= 140,"Slash popover retains visible filtered rows")
        if let content = editor.slashPopover?.contentViewController?.view, let popoverWindow = content.window, let window = editor.window {
            let menuRect = popoverWindow.convertToScreen(content.convert(content.bounds,to:nil))
            let caret = window.convertToScreen(editor.convert(editor.rectFor(0),to:nil))
            check(!menuRect.contains(NSPoint(x:caret.midX,y:caret.midY)),"Slash popover does not obscure the native caret")
        } else { fatalError("Missing native popover window") }
        if ProcessInfo.processInfo.environment["BLANK_GEOMETRY"] != nil {
            var actual = NSRange()
            print("Geometry",editor.frame,editor.visibleRect,editor.textContainerOrigin,editor.rectFor(0),editor.firstRect(forCharacterRange:NSRange(location:0,length:1),actualRange:&actual),editor.slashPopover?.contentViewController?.view.window?.frame as Any,controller.window?.frame as Any)
            if let manager = editor.textLayoutManager, let start = manager.textContentManager?.documentRange.location, let fragment = manager.textLayoutFragment(for:start) { print("Fragment",fragment.layoutFragmentFrame,fragment.textLineFragments.map(\.typographicBounds)) }
        }
        editor.slashIndex = 1; editor.chooseSlash()
        check(session.buffer.source == "== Slash target" && editor.slashPopover == nil,"Slash choice preserves content and dismisses menu")
        session.undo(); check(session.buffer.source == "/headingSlash target","Slash conversion is one undo transaction")
        session.buffer.loadExternal("First block\n\nSecond block\n\nThird block")
        session.revision += 1; editor.refresh(); editor.textLayoutManager?.ensureLayout(for:editor.visibleRect)
        check(controller.window?.acceptsMouseMovedEvents == true,"Document window delivers handle hover events")
        func pointer(_ type: NSEvent.EventType,_ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:editor.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0 : 1)!
        }
        let handle = NSPoint(x:editor.textContainerInset.width-23,y:editor.blockRect(0).minY+12)
        editor.mouseEntered(with:pointer(.mouseMoved,handle))
        check(editor.hoverBlock == 0 && NSCursor.current == NSCursor.openHand,"Entering a handle shows an open hand")
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
        session.sidebarHover = true; controller.toggleContents(nil)
        check(session.sidebar && !session.sidebarHover && controller.sidebarItem?.toolTip?.hasPrefix("Hide") == true,"Pinning contents clears transient hover and updates toolbar")
        session.sidebarHover = true; session.toggleSidebar()
        check(!session.sidebar && !session.sidebarHover && controller.sidebarItem?.toolTip?.hasPrefix("Show") == true,"Unpinning contents restores transient behavior")
        // Tables use view-backed TextKit 2 attachments and native field editors.
        session.buffer.loadExternal("#table(columns: 2, [Idea], [Step], [One], [Two])\n\nAfter")
        session.revision += 1; editor.lastRevision = -1; editor.refresh()
        RunLoop.main.run(until:Date().addingTimeInterval(0.15))
        check(editor.textLayoutManager != nil,"TextKit 2 retained with table attachments")
        editor.scrollRangeToVisible(NSRange(location:0,length:1))
        editor.needsDisplay = true; editor.displayIfNeeded()
        RunLoop.main.run(until:Date().addingTimeInterval(0.15))
        guard let table = editor.tableViews[0]?.value else {
            print("Native object debug:",editor.string.debugDescription,editor.textStorage?.attributes(at:0,effectiveRange:nil) ?? [:],editor.frame,editor.visibleRect)
            fatalError("No native table view")
        }
        check(table.fields.count == 4,"Native table cells created")
        check(table.window === controller.window,"Native table controls mounted in document")
        let originalAppearance = controller.window?.appearance
        let originalSystemColors = session.systemColors
        session.systemColors = true
        for name in [NSAppearance.Name.aqua,.darkAqua] {
            controller.window?.appearance = NSAppearance(named:name)
            RunLoop.main.run(until:Date().addingTimeInterval(0.1)); editor.lastAppearance = ""; editor.refresh()
            let themedTable = editor.tableViews[0]!.value!
            var background: CGFloat = 0, foreground: CGFloat = 0
            editor.effectiveAppearance.performAsCurrentDrawingAppearance {
                background = editor.backgroundColor.usingColorSpace(.deviceRGB)!.brightnessComponent
                foreground = themedTable.fields[0].textColor!.usingColorSpace(.deviceRGB)!.brightnessComponent
            }
            check(name == .darkAqua ? background < 0.25 && foreground > 0.7 : background > 0.9 && foreground < 0.3,"Native page and table text adapt to \(name.rawValue)")
            controller.window?.makeFirstResponder(themedTable.fields[0])
            if let cellEditor = themedTable.fields[0].currentEditor() as? NSTextView {
                var editingColor: CGFloat = 0
                editor.effectiveAppearance.performAsCurrentDrawingAppearance { editingColor = cellEditor.textColor!.usingColorSpace(.deviceRGB)!.brightnessComponent }
                check(abs(editingColor-foreground) < 0.01,"Active table cell retains readable \(name.rawValue) text")
            } else { fatalError("Missing themed table field editor") }
            editor.objectEditing = false; controller.window?.makeFirstResponder(editor)
        }
        let originalPaper = session.paper, originalInk = session.ink
        session.systemColors = false; session.paper = .white; session.ink = .black
        controller.window?.appearance = NSAppearance(named:.darkAqua)
        editor.lastAppearance = ""; editor.refresh()
        editor.effectiveAppearance.performAsCurrentDrawingAppearance {
            check(editor.backgroundColor.usingColorSpace(.deviceRGB)!.brightnessComponent > 0.9 && editor.tableViews[0]!.value!.fields[0].textColor!.usingColorSpace(.deviceRGB)!.brightnessComponent < 0.1,"Custom white page keeps black table text in a dark window")
        }
        session.paper = originalPaper; session.ink = originalInk
        controller.window?.appearance = originalAppearance; session.systemColors = originalSystemColors
        editor.lastAppearance = ""; editor.refresh(); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        let activeTable = editor.tableViews[0]!.value!
        controller.window?.makeFirstResponder(activeTable.fields[2])
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        if let cellEditor = activeTable.fields[2].currentEditor() as? NSTextView {
            cellEditor.selectAll(nil); cellEditor.insertText("Café 👋",replacementRange:cellEditor.selectedRange())
        } else { fatalError("No native cell editor") }
        check(session.buffer.source.contains("[Café 👋]"),"Native table typing preserves source spans")
        session.undo(); RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        check(session.buffer.source.contains("[One]") && editor.tableViews[0]?.value?.fields[2].currentEditor() != nil,"Table Undo restores source and native cell focus")
        session.undo(true); RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        check(session.buffer.source.contains("[Café 👋]") && editor.tableViews[0]?.value?.fields[2].stringValue == "Café 👋","Table Redo restores native text and source")
        editor.tableViews[0]?.value?.addRowAndFocus(); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(session.buffer.projection.blocks[0].tableCells.count == 6,"Final table Tab adds row")
        check(!session.buffer.parsed.erroneous,"Added table row is valid Typst syntax")
        editor.objectEditing = false; controller.window?.makeFirstResponder(editor)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:32,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let pixels = bitmap.bitmapData!
        for x in 0..<64 { for y in 0..<32 { let at = y*bitmap.bytesPerRow+x*4; pixels[at] = x < 32 ? 40 : 240; pixels[at+1] = x < 32 ? 100 : 140; pixels[at+2] = x < 32 ? 200 : 30; pixels[at+3] = 255 } }
        session.assets["assets/test.png"] = bitmap.representation(using:.png,properties:[:])!
        session.buffer.loadExternal("#figure(image(\"assets/test.png\", width: 85%), caption: [A native caption])\n\nAfter")
        session.revision += 1; editor.refresh(); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(editor.objectViews[0] is FigureBlockView && loadImage("assets/test.png",session:session) != nil,"Figure renders through native AppKit image view")
        check(editor.textLayoutManager != nil,"TextKit 2 retained with native figure")
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
        check(!session.sourceMap.isEmpty,"Preview carries source navigation map")
        session.switchMode(.preview); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        guard let pdfView = session.pdfView, let secondPage = session.pdf?.page(at:1) else { fatalError("Missing two-page preview") }
        // PDFKit sends this same notification for wheel/trackpad page changes.
        // Navigate directly instead of routing through the page-counter action.
        pdfView.go(to:secondPage); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(session.previewPage == 2,"Preview page counter follows native PDF navigation")
        session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        let good = session.pdf
        session.buffer.loadExternal("#unknown-function()")
        session.revision += 1; session.compile()
        let failureDeadline = Date().addingTimeInterval(10)
        while session.compiling && Date() < failureDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        check(session.pdf === good && session.error != nil,"Compilation errors preserve last successful PDF")
        session.buffer.loadExternal("#figure(image(\"assets/test.png\"), caption: [A caption])")
        session.revision += 1
        let exported = FileManager.default.temporaryDirectory.appendingPathComponent("blank-export-"+UUID().uuidString+".pdf")
        session.compile(); session.compile(export:exported)
        let exportDeadline = Date().addingTimeInterval(10)
        while session.compiling && Date() < exportDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        check((try? Data(contentsOf:exported).starts(with:Data("%PDF-".utf8))) == true,"PDF export queued during compilation includes imported figure and caption")
        try? FileManager.default.removeItem(at:exported)
        print("Native acceptance completed")
        FileAcceptance.run()
        session.saveWork?.cancel(); controller.window?.close()
    }
}
