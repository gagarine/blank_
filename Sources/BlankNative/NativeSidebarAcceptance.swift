import AppKit
import PDFKit
import BlankCore

@MainActor enum NativeSidebarAcceptance {
    static func run(controller: DocumentWindow) {
        let session = controller.session, editor = session.editor!
        func check(_ condition: @autoclosure () -> Bool,_ label: String) { guard condition() else { fatalError("FAIL: \(label) | sidebar=\(session.sidebar), visible=\(session.searchVisible), query=\(session.searchQuery), matches=\(session.searchController.matches.count)") }; print("PASS: \(label)") }
        let source = "= First\n\nCafé 👩🏽‍💻 alpha\n\n== Child\n\nsecond ALPHA\n\n#let literal = \"needle\"\n\n#table(columns: 2, [alpha], [keep])\n\n= Last\n\n"+(0..<65).map { "Paragraph \($0). "+String(repeating:"A long native editing sample. ",count:8) }.joined(separator:"\n\n")
        session.buffer.loadExternal(source); session.revision += 1; editor.refresh()
        toolbarCursor(controller:controller)
        guard let sidebar = controller.sidebarItem as? NSMenuToolbarItem else { fatalError("Sidebar must use the native split menu control") }
        controller.menuNeedsUpdate(sidebar.menu)
        check(sidebar.menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Show Sidebar","Thumbnails","Table of Contents","Contact Sheet"],"Sidebar exposes native view choices without unsupported annotation modes")
        let menuItem = sidebar.menu.items.first { $0.title == "Thumbnails" }!
        controller.chooseSidebar(menuItem); RunLoop.main.run(until:Date().addingTimeInterval(0.25))
        check(session.sidebar && session.sidebarMode == .thumbnails && session.editor === editor,"Choosing Thumbnails opens the sidebar without replacing the editor")
        resizeTarget(controller:controller)
        session.thumbnails.update()
        check(session.thumbnails.pages.count > 1 && session.thumbnails.image(0)?.tiffRepresentation != nil,"Write thumbnails render real native typography across multiple pages")
        let original = session.buffer.source
        session.thumbnails.navigate(1)
        check(editor.selectedRange().location > 0 && session.buffer.source == original,"Write thumbnail navigation changes position without editing source")
        session.switchMode(.source); RunLoop.main.run(until:Date().addingTimeInterval(0.1)); session.thumbnails.update()
        resizeTarget(controller:controller)
        check(session.thumbnails.pages.count > 1 && session.thumbnails.image(0)?.tiffRepresentation != nil && editor.string == source,"Source thumbnails use styled native layout and retain exact source characters")
        let appearance = editor.appearance, systemColors = session.systemColors
        editor.appearance = NSAppearance(named:.darkAqua); session.systemColors = true; editor.refresh(); session.thumbnails.update()
        let bitmap = session.thumbnails.image(0)?.tiffRepresentation.flatMap { NSBitmapImageRep(data:$0) }
        let background = bitmap?.colorAt(x:2,y:2)?.usingColorSpace(.deviceRGB)
        check(background != nil && background!.redComponent < 0.4 && background!.alphaComponent > 0.9,"Native thumbnails resolve system colors in the editor's dark appearance")
        editor.appearance = appearance; session.systemColors = systemColors; editor.refresh()
        contactSheet(controller:controller)
        check(!CommandsSheet(session:session).actions.contains { $0.0 == "Fullscreen" },"Cmd-K omits Full Screen while the standard macOS command remains available")
        session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        session.sidebar = false; session.showSearch()
        let field = controller.searchItem!.searchField
        field.stringValue = "alpha"; controller.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:field))
        wait(session)
        check(session.sidebar && session.searchController.matches.count == 3,"Typing in native Find opens the sidebar and searches prose and table cells without Return")
        let first = session.searchController.matches[0]
        check(editor.layoutManager?.temporaryAttribute(.backgroundColor,atCharacterIndex:first.range.location,effectiveRange:nil) as? NSColor != nil && session.buffer.source == source,"Yellow live-search highlights are temporary layout attributes, never source edits")
        let focus = controller.window?.firstResponder
        check(session.searchController.selected == 0,"Live Find initially reveals its first match")
        check(controller.control(field,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:))),"Return in Find dispatches next-result navigation")
        check(session.searchController.selected == 1,"The first Return advances beyond the already revealed match")
        let selected = editor.selectedRange()
        _ = controller.control(field,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:)))
        check(editor.selectedRange() != selected && controller.window?.firstResponder === focus,"Find Return advances matches while preserving search-field focus")
        session.searchQuery = "needle"; session.searchQuery = "café"; wait(session)
        check(session.searchController.matches.count == 1 && session.searchController.matches[0].snippet.contains("Café"),"Rapid live-query changes discard stale results and preserve Unicode snippets")
        session.caseSensitive = true; wait(session)
        check(session.searchController.matches.isEmpty,"Changing match-case recomputes live results")
        session.caseSensitive = false; session.searchQuery = ""; wait(session)
        check(session.searchController.matches.isEmpty && editor.layoutManager?.temporaryAttribute(.backgroundColor,atCharacterIndex:first.range.location,effectiveRange:nil) == nil,"Clearing Find removes every yellow highlight and sidebar result")
        session.hideSearch()
        check(!session.sidebar,"Closing Find restores the sidebar's previous visibility")
        session.searchQuery = "needle"; session.showSearch(); session.switchMode(.source); RunLoop.main.run(until:Date().addingTimeInterval(0.1)); wait(session)
        check(session.searchController.matches.count == 1,"Live Source search includes custom Typst code")
        session.searchQuery = ""; session.hideSearch()
        let entry = session.entry
        session.buffers[entry]?.loadExternal("#include \"child.typ\"\n\nParent projectword")
        session.buffers["child.typ"] = DocumentBuffer("= Child\n\nCafé projectword")
        session.revision += 1; editor.refresh()
        session.projectSearch = true; session.searchQuery = "projectword"; session.showSearch(); wait(session)
        check(session.searchController.matches.count == 2,"Live project search covers included files")
        session.searchController.navigate()
        check(session.active == "child.typ" && (editor.string as NSString).substring(with:editor.selectedRange()) == "projectword","Next live project match opens its included file and selects the exact text")
        check(session.searchController.matches.count == 2 && !session.searchController.searching,"Opening a search result keeps the full project result set")
        session.searchQuery = ""; session.hideSearch(); session.projectSearch = false; session.switchFile(entry); session.buffers.removeValue(forKey:"child.typ")
        session.searchQuery = ""; session.hideSearch(); session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        session.sidebarMode = .contents; session.sidebar = false; session.buffer.loadExternal(""); session.revision += 1; editor.refresh(); editor.setSelectedRange(NSRange(location:0,length:0)); editor.captureSelection()
        check(session.buffer.source.isEmpty && controller.window?.firstResponder === editor,"Sidebar tests leave a clean focused disposable document")
    }
    static func wait(_ session: DocumentSession) {
        let deadline = Date().addingTimeInterval(5)
        while session.searchController.searching && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        guard !session.searchController.searching else { fatalError("Search did not finish") }
    }
    static func toolbarCursor(controller: DocumentWindow) {
        let session = controller.session, originalMode = session.mode
        guard let window = controller.window, let editor = session.editor,
              let scroll = editor.enclosingScrollView else { fatalError("No native editor window") }
        for mode: EditorMode in [.write,.source] {
            session.switchMode(mode); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
            editor.ensureNativeLayout()
            let savedOrigin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to:NSPoint(x:0,y:240)); scroll.reflectScrolledClipView(scroll.contentView)
            let point = NSPoint(x:window.contentLayoutRect.midX,y:window.contentLayoutRect.maxY+12)
            guard editor.bounds.contains(editor.convert(point,from:nil)) else { fatalError("Cursor regression must include text scrolled beneath the toolbar") }
            let event = NSEvent.mouseEvent(with:.mouseMoved,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0)!
            for callback in [editor.mouseMoved(with:),editor.cursorUpdate(with:),editor.mouseExited(with:)] {
                editor.hoverBlock = 0; NSCursor.iBeam.set(); callback(event)
                guard NSCursor.current == .arrow && editor.hoverBlock == nil else { fatalError("Text tracking must leave the native toolbar's arrow cursor intact in \(mode)") }
            }
            let textPoint = NSPoint(x:window.contentLayoutRect.midX,y:window.contentLayoutRect.midY)
            let textEvent = NSEvent.enterExitEvent(with:.cursorUpdate,location:textPoint,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,trackingNumber:0,userData:nil)!
            NSCursor.arrow.set(); editor.cursorUpdate(with:textEvent)
            guard NSCursor.current == .iBeam else { fatalError("Uncovered native text must retain its editing cursor in \(mode)") }
            print("PASS: Native toolbar and text cursor ownership in \(mode)")
            scroll.contentView.scroll(to:savedOrigin); scroll.reflectScrolledClipView(scroll.contentView)
        }
        session.switchMode(originalMode); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        print("PASS: Scrolled Write and Source text cannot replace the native toolbar cursor")
    }
    static func resizeTarget(controller original: DocumentWindow) {
        // Start with an expanded pane so geometry checks don't depend on the
        // synchronous runner draining an in-flight collapse animation.
        let session = DocumentSession(); session.sidebar = true; session.mode = original.session.mode
        session.pdfData = original.session.pdfData; session.pdf = original.session.pdf
        let controller = DocumentWindow(session:session)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        defer { controller.window?.close(); original.window?.makeKeyAndOrderFront(nil) }
        let split = controller.splitController.splitView
        // Let native window constraints settle before positioning the divider;
        // observe each requested size after AppKit has completed its layout.
        RunLoop.main.run(until:Date().addingTimeInterval(0.25))
        split.layoutSubtreeIfNeeded()
        guard let sidebarPane = split.arrangedSubviews.first else { fatalError("No native sidebar pane") }
        for width: CGFloat in [240,280,220] {
            split.setPosition(width,ofDividerAt:0); split.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(1)
            while abs(sidebarPane.frame.width-width) >= 2 && Date() < deadline {
                RunLoop.main.run(until:Date().addingTimeInterval(0.02)); split.layoutSubtreeIfNeeded()
            }
            guard abs(sidebarPane.frame.width-width) < 2 else { fatalError("FAIL: Native sidebar width must follow resizing before testing the new hit area | requested=\(width), actual=\(sidebarPane.frame.width)") }
            let boundary = sidebarPane.frame.maxX+split.dividerThickness/2
            for offset: CGFloat in [-6,0,6] {
                let point = NSPoint(x:boundary+offset,y:split.bounds.midY)
                let root = controller.window!.contentView!
                guard root.hitTest(split.convert(point,to:root.superview)) === split else { fatalError("FAIL: Widened sidebar resize target must route both margins to the native split view after resizing | width=\(width), offset=\(offset)") }
                let event = NSEvent.mouseEvent(with:.mouseMoved,location:split.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0)!
                for _ in 0..<3 {
                    NSCursor.iBeam.set()
                    if let editor = session.editor { editor.mouseMoved(with:event); editor.cursorUpdate(with:event); editor.mouseExited(with:event) }
                    else { _ = controller.splitController.updateResizeCursor(for:event) }
                    guard NSCursor.current == .resizeLeftRight else { fatalError("FAIL: Editor tracking must not replace the sidebar resize cursor") }
                }
            }
            let outside = NSEvent.mouseEvent(with:.mouseMoved,location:split.convert(NSPoint(x:boundary+20,y:split.bounds.midY),to:nil),modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0)!
            guard !controller.splitController.updateResizeCursor(for:outside) else { fatalError("FAIL: Resize cursor must release outside its gutter") }
        }
        print("PASS: Native sidebar resize accepts both margins and retains its cursor through editor tracking in \(controller.session.mode)")
    }
    static func contactSheet(controller: DocumentWindow) {
        let session = controller.session, source = session.buffer.source, originalMode = session.mode
        let editor = session.editor, pdfScale = session.pdfView?.scaleFactor
        let item = NSMenuItem(); item.representedObject = SidebarMode.contactSheet.rawValue
        controller.chooseSidebar(item); RunLoop.main.run(until:Date().addingTimeInterval(0.4))
        func collections(_ view: NSView) -> [ContactPageCollection] { (view as? ContactPageCollection).map { [$0] } ?? view.subviews.flatMap(collections) }
        guard let collection = controller.window?.contentView.flatMap({ collections($0).first }), let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout else { fatalError("No native contact-sheet collection") }
        func check(_ condition: @autoclosure () -> Bool,_ label: String) { guard condition() else { fatalError("FAIL: \(label)") }; print("PASS: \(label)") }
        check(session.contactSheet && !session.sidebar && collection.bounds.width > controller.window!.frame.width-40,"Contact Sheet fills the document window with a native collection")
        check(collection.numberOfItems(inSection:0) > 0 && session.editor === editor,"Contact Sheet renders pages without replacing the underlying native editor")
        let zoom = controller.zoomItem!, width = layout.itemSize.width
        zoom.selectedIndex = 2; controller.zoomPreview(zoom); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(layout.itemSize.width > width && session.pdfView?.scaleFactor == pdfScale,"Contact-sheet zoom changes thumbnail size without changing PDF zoom")
        zoom.selectedIndex = 0; controller.zoomPreview(zoom); zoom.selectedIndex = 1; controller.zoomPreview(zoom); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(session.contactSheetSize == 190,"Actual Size restores the contact sheet's default thumbnail scale")
        let selected = IndexPath(item:min(1,collection.numberOfItems(inSection:0)-1),section:0)
        collection.selectItems(at:[selected],scrollPosition:.nearestHorizontalEdge)
        collection.delegate?.collectionView?(collection,didSelectItemsAt:[selected])
        check(session.contactSheet && session.buffer.source == source,"Selecting an overview page leaves the document and overview intact")
        let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        collection.keyDown(with:event); RunLoop.main.run(until:Date().addingTimeInterval(0.25))
        check(!session.contactSheet && session.buffer.source == source && session.mode == originalMode,"Return opens the selected page in the original view without editing source")
        check(controller.window?.firstResponder === (session.mode == .preview ? session.pdfView : session.editor),"Leaving Contact Sheet restores the native editor or PDF keyboard responder")
    }
    static func preview(controller: DocumentWindow) {
        let session = controller.session
        func check(_ condition: @autoclosure () -> Bool,_ label: String) { guard condition() else { fatalError("FAIL: \(label) | sidebar=\(session.sidebar), visible=\(session.searchVisible), query=\(session.searchQuery), matches=\(session.searchController.matches.count)") }; print("PASS: \(label)") }
        session.sidebar = false; session.showSearch(); session.searchQuery = "Native"; wait(session)
        check(session.sidebar && session.searchController.matches.count >= 2 && session.pdfView?.highlightedSelections?.allSatisfy { $0.color == NSColor.systemYellow } == true,"Live Preview search maps worker PDF ranges to yellow selections on the live document")
        RunLoop.main.run(until:Date().addingTimeInterval(0.25)); resizeTarget(controller:controller)
        check(session.searchController.groups.count <= session.pdf!.pageCount && session.searchController.groups.flatMap(\.matches).count == session.searchController.matches.count,"Preview sidebar groups every match by page without losing navigation targets")
        session.find()
        check(session.pdfView?.currentSelection?.string?.localizedCaseInsensitiveContains("native") == true,"Return-style Preview navigation selects a real PDF text result")
        check(session.thumbnails.pdfThumbnail(0,width:76)?.tiffRepresentation != nil,"Preview search thumbnails are generated from the compiled PDF")
        let item = NSMenuItem(); item.representedObject = PreviewDisplayMode.two.rawValue
        controller.choosePreviewDisplay(item); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(session.pdfView?.displayMode == .twoUp,"Sidebar display menu uses PDFKit's native two-page mode")
        item.representedObject = PreviewDisplayMode.continuous.rawValue; controller.choosePreviewDisplay(item)
        session.searchQuery = ""; session.hideSearch()
        check(session.pdfView?.highlightedSelections?.isEmpty != false,"Closing Preview search clears all search highlights")
        contactSheet(controller:controller)
    }
}
