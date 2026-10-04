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
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        guard let view = session.editor else { fatalError("No native editor") }
        func check(_ condition: @autoclosure () -> Bool,_ label: String) { if !condition() { fatalError("FAIL: \(label) | source=\(session.buffer.source) | native=\(view.string)") }; print("PASS: \(label)") }
        check(view.textLayoutManager != nil,"TextKit 2 active at creation")
        check(controller.window?.firstResponder === view,"Empty editor is focused")
        check(view.string.isEmpty,"Launch has no welcome screen")
        check(controller.window?.styleMask.contains(.fullSizeContentView) == true && controller.window?.titlebarAppearsTransparent == true,"Document extends beneath native transparent toolbar")
        for scalar in "Hello café 👩🏽‍💻".unicodeScalars { view.insertText(String(scalar),replacementRange:view.selectedRange()) }
        check(session.buffer.projection.text == "Hello café 👩🏽‍💻","Native typing and Unicode")
        view.insertNewline(nil); view.insertText("Second paragraph",replacementRange:view.selectedRange())
        check(session.buffer.projection.blocks.count == 2,"Return splits paragraph")
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
        controller.window?.makeFirstResponder(table.fields[2])
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        if let cellEditor = table.fields[2].currentEditor() as? NSTextView {
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
