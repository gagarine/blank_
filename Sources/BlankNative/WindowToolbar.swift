import AppKit
import Combine
import PDFKit

extension NSToolbarItem.Identifier {
    static let blankSidebar = Self("blank.sidebar")
    static let blankModes = Self("blank.modes")
    static let blankShare = Self("blank.share")
    static let blankZoom = Self("blank.zoom")
    static let blankSidebarSeparator = Self("blank.sidebarSeparator")
    static let blankSearch = Self("blank.search")
}

@MainActor extension DocumentWindow {
    func installToolbar() {
        let toolbar = NSToolbar(identifier:"blank.document.native")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = true
        window?.toolbarStyle = .unified
        window?.toolbar = toolbar
        session.$mode.sink { [weak self] mode in
            self?.modeItem?.selectedIndex = EditorMode.allCases.firstIndex(of:mode) ?? 0
            self?.zoomItem?.isHidden = mode != .preview
        }.store(in:&toolbarSubscriptions)
        session.$searchQuery.removeDuplicates().sink { [weak self] query in
            if self?.searchItem?.searchField.stringValue != query { self?.searchItem?.searchField.stringValue = query }
        }.store(in:&toolbarSubscriptions)
        session.$searchVisible.sink { [weak self] visible in
            if !visible { self?.searchItem?.endSearchInteraction(); self?.searchWidth?.constant = 36 }
        }.store(in:&toolbarSubscriptions)
        session.$sidebar.sink { [weak self] shown in self?.sidebarItem?.toolTip = shown ? "Hide Contents · ⌘⇧L" : "Show Contents · ⌘⇧L" }.store(in:&toolbarSubscriptions)
    }
    @objc func chooseMode(_ sender: NSToolbarItemGroup) {
        guard EditorMode.allCases.indices.contains(sender.selectedIndex) else { return }
        session.switchMode(EditorMode.allCases[sender.selectedIndex])
    }
    @objc func toggleContents(_ sender: Any?) { session.toggleSidebar() }
    func focusNativeSearch() {
        guard session.searchVisible, session.sheet == nil else { return }
        // Cmd-F must also work if the user removed Search during customization.
        if let toolbar = window?.toolbar, !toolbar.items.contains(where:{ $0.itemIdentifier == .blankSearch }) { toolbar.insertItem(withItemIdentifier:.blankSearch,at:toolbar.items.count) }
        searchItem?.searchField.stringValue = session.searchQuery
        searchWidth?.constant = 220
        searchItem?.beginSearchInteraction()
        searchItem?.searchField.selectText(nil)
    }
    @objc func searchDocument(_ sender: NSSearchField) { session.searchQuery = sender.stringValue; session.find() }
    @objc func zoomPreview(_ sender: NSToolbarItemGroup) {
        guard session.mode == .preview, let view = session.pdfView, view.document != nil else { return }
        switch sender.selectedIndex {
        case 0: view.autoScales = false; view.zoomOut(nil)
        case 1: view.autoScales = false; view.scaleFactor = 1
        case 2: view.autoScales = false; view.zoomIn(nil)
        default: break
        }
    }
}
extension DocumentWindow: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.blankSidebar,.blankSidebarSeparator,.flexibleSpace,.blankModes,.flexibleSpace,.blankZoom,.space,.blankShare,.space,.blankSearch] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.blankSidebar,.blankSidebarSeparator,.blankModes,.blankZoom,.blankSearch,.blankShare,.space,.flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar,itemForItemIdentifier identifier: NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .blankSidebarSeparator {
            return NSTrackingSeparatorToolbarItem(identifier:identifier,splitView:splitController.splitView,dividerIndex:0)
        }
        if identifier == .blankShare {
            let item = NSToolbarItem(itemIdentifier:identifier)
            let button = NSButton(image:NSImage(systemSymbolName:"square.and.arrow.up",accessibilityDescription:"Share PDF")!,target:self,action:#selector(shareDocument(_:)))
            button.bezelStyle = .texturedRounded; button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Share PDF")
            item.view = button; item.target = self; item.action = #selector(shareDocument(_:))
            item.label = "Share PDF"; item.toolTip = "Share a PDF copy"; item.isBordered = true; item.visibilityPriority = .high
            if flag { shareButton = button }; return item
        }
        if identifier == .blankSearch {
            let item = NSSearchToolbarItem(itemIdentifier:identifier)
            item.label = "Find"; item.toolTip = "Find · ⌘F"; item.isBordered = true
            item.searchField.placeholderString = "Find in Document"
            item.searchField.delegate = self; item.searchField.target = self; item.searchField.action = #selector(searchDocument(_:))
            item.searchField.sendsWholeSearchString = true
            item.searchField.stringValue = session.searchQuery
            item.preferredWidthForSearchField = 220
            let width = item.searchField.widthAnchor.constraint(equalToConstant:session.searchVisible ? 220 : 36)
            width.priority = .defaultHigh; width.isActive = true; if flag { searchWidth = width }
            item.visibilityPriority = .high
            if flag { searchItem = item }; return item
        }
        if identifier == .blankZoom {
            let images = ["minus.magnifyingglass","1.magnifyingglass","plus.magnifyingglass"].map { NSImage(systemSymbolName:$0,accessibilityDescription:nil)! }
            let item = NSToolbarItemGroup(itemIdentifier:identifier,images:images,selectionMode:.momentary,labels:["Zoom Out","Actual Size","Zoom In"],target:self,action:#selector(zoomPreview(_:)))
            item.label = "PDF Zoom"; item.paletteLabel = "Zoom Out, Actual Size and Zoom In"; item.isBordered = true
            item.controlRepresentation = .expanded; item.isHidden = session.mode != .preview
            if flag { zoomItem = item }; return item
        }
        if identifier == .blankModes {
            let item = NSToolbarItemGroup(itemIdentifier:identifier,titles:EditorMode.allCases.map(\.rawValue),selectionMode:.selectOne,labels:nil,target:self,action:#selector(chooseMode(_:)))
            item.isBordered = true; item.label = "Editor View"; item.paletteLabel = "Write, Source and Preview"; item.controlRepresentation = .expanded
            item.selectedIndex = EditorMode.allCases.firstIndex(of:session.mode) ?? 0
            #if BLANK_MACOS27_SDK
            if #available(macOS 27, *) { item.role = .tabs }
            #endif
            item.visibilityPriority = .high; if flag { modeItem = item }; return item
        }
        let item = NSToolbarItem(itemIdentifier:identifier); item.target = self; item.isBordered = true
        switch identifier {
        case .blankSidebar:
            item.isNavigational = true; item.visibilityPriority = .high
            item.label = "Contents"; item.paletteLabel = "Table of Contents"; item.image = NSImage(systemSymbolName:"sidebar.left",accessibilityDescription:"Toggle Contents"); item.action = #selector(toggleContents(_:)); item.toolTip = "Show Contents · ⌘⇧L"; if flag { sidebarItem = item }
        default: return nil
        }
        // NSToolbar supplies Liquid Glass, adaptive grouping and hit geometry.
        // No custom backgrounds or additional glass layers are applied.
        return item
    }
}

extension DocumentWindow: NSSearchFieldDelegate {
    func searchFieldDidStartSearching(_ sender: NSSearchField) { session.editor?.finishComposition(); searchWidth?.constant = 220; session.searchVisible = true }
    func searchFieldDidEndSearching(_ sender: NSSearchField) { session.searchQuery = sender.stringValue; session.hideSearch() }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        session.searchQuery = field.stringValue
    }
    func control(_ control: NSControl,textView: NSTextView,doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { session.hideSearch(); return true }
        return false
    }
}
// AppKit invokes picker delegates on the UI thread; this SDK protocol lacks
// actor annotations. Enforce that contract when bridging into the main actor.
extension DocumentWindow: @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    @objc func shareDocument(_ source: Any?) {
        guard let sender = shareButton, sender.isEnabled else { return }
        session.editor?.finishComposition()
        sender.isEnabled = false
        let name = session.title
        session.requestPDF { [weak self,weak sender] result in
            sender?.isEnabled = true
            guard let self, let sender, self.window?.isVisible == true else { return }
            do {
                let file = try SharedPDF(data:result.get(),name:name)
                self.sharedPDF = file
                let picker = NSSharingServicePicker(items:[file.url])
                picker.delegate = self; self.sharePicker = picker
                if sender.window != nil { picker.show(relativeTo:sender.bounds,of:sender,preferredEdge:.minY) }
                else if let view = self.window?.contentView {
                    picker.show(relativeTo:NSRect(x:view.bounds.maxX-44,y:view.bounds.maxY-40,width:32,height:32),of:view,preferredEdge:.minY)
                }
            } catch { self.session.error = error.localizedDescription }
        }
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,delegateFor service: NSSharingService) -> (any NSSharingServiceDelegate)? { self }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,didChoose service: NSSharingService?) {
        if let service, let file = sharedPDF { activePDFShares[ObjectIdentifier(service)] = file }
        sharedPDF = nil; sharePicker = nil
    }
    func sharingService(_ sharingService: NSSharingService,didShareItems items: [Any]) { activePDFShares.removeValue(forKey:ObjectIdentifier(sharingService)) }
    func sharingService(_ sharingService: NSSharingService,didFailToShareItems items: [Any],error: any Error) {
        session.error = error.localizedDescription; activePDFShares.removeValue(forKey:ObjectIdentifier(sharingService))
    }
}
