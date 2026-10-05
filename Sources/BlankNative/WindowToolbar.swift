import AppKit
import Combine

extension NSToolbarItem.Identifier {
    static let blankSidebar = Self("blank.sidebar")
    static let blankModes = Self("blank.modes")
    static let blankExport = Self("blank.export")
    static let blankSearch = Self("blank.search")
}

@MainActor extension DocumentWindow {
    func installToolbar() {
        let toolbar = NSToolbar(identifier:"blank.document")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = true
        window?.toolbarStyle = .unified
        window?.toolbar = toolbar
        session.$mode.sink { [weak self] mode in self?.modeItem?.selectedIndex = EditorMode.allCases.firstIndex(of:mode) ?? 0 }.store(in:&toolbarSubscriptions)
        session.$sidebar.sink { [weak self] shown in self?.sidebarItem?.toolTip = shown ? "Hide Contents · ⌘⇧L" : "Show Contents · ⌘⇧L" }.store(in:&toolbarSubscriptions)
    }
    @objc func chooseMode(_ sender: NSToolbarItemGroup) {
        guard EditorMode.allCases.indices.contains(sender.selectedIndex) else { return }
        session.switchMode(EditorMode.allCases[sender.selectedIndex])
    }
    @objc func toggleContents(_ sender: Any?) { session.toggleSidebar() }
    @objc func exportDocument(_ sender: Any?) { session.exportPDF() }
    @objc func findDocument(_ sender: Any?) { session.showSearch() }
}
extension DocumentWindow: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.blankSidebar,.flexibleSpace,.blankModes,.flexibleSpace,.blankExport] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.blankSidebar,.blankModes,.blankSearch,.blankExport,.space,.flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar,itemForItemIdentifier identifier: NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .blankModes {
            let item = NSToolbarItemGroup(itemIdentifier:identifier,titles:EditorMode.allCases.map(\.rawValue),selectionMode:.selectOne,labels:nil,target:self,action:#selector(chooseMode(_:)))
            item.label = "Editor View"; item.paletteLabel = "Write, Source and Preview"; item.controlRepresentation = .expanded
            item.selectedIndex = EditorMode.allCases.firstIndex(of:session.mode) ?? 0
            #if BLANK_MACOS27_SDK
            if #available(macOS 27, *) { item.role = .tabs }
            #endif
            item.visibilityPriority = .high; modeItem = item; return item
        }
        let item = NSToolbarItem(itemIdentifier:identifier); item.target = self
        switch identifier {
        case .blankSidebar:
            item.isNavigational = true; item.visibilityPriority = .high
            item.label = "Contents"; item.paletteLabel = "Table of Contents"; item.image = NSImage(systemSymbolName:"sidebar.left",accessibilityDescription:"Toggle Contents"); item.action = #selector(toggleContents(_:)); item.toolTip = "Show Contents · ⌘⇧L"; sidebarItem = item
        case .blankExport:
            item.label = "Export PDF"; item.image = NSImage(systemSymbolName:"square.and.arrow.up",accessibilityDescription:"Export PDF"); item.action = #selector(exportDocument(_:)); item.toolTip = "Export PDF · ⌘⇧E"
        case .blankSearch:
            item.label = "Find"; item.image = NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:"Find in Document"); item.action = #selector(findDocument(_:)); item.toolTip = "Find · ⌘F"
        default: return nil
        }
        // NSToolbar supplies Liquid Glass, adaptive grouping and hit geometry.
        // No custom backgrounds or additional glass layers are applied.
        return item
    }
}
