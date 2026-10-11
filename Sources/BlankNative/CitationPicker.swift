import AppKit
import SwiftUI

struct CitationLibraryPicker: NSViewRepresentable {
    var libraries: [CitationLibrary]
    @Binding var selection: String
    var keyboard: CitationKeyboard
    func makeNSView(context: Context) -> CitationLibraryPopUp {
        let picker = CitationLibraryPopUp(frame:.zero,pullsDown:false)
        picker.target = picker; picker.action = #selector(CitationLibraryPopUp.choose(_:))
        picker.setAccessibilityLabel("Zotero library")
        return picker
    }
    func updateNSView(_ picker: CitationLibraryPopUp,context: Context) {
        keyboard.library = picker
        picker.changed = { selection = $0 }
        let values = libraries.map { $0.id+"\n"+$0.name }
        if picker.values != values {
            picker.values = values; picker.removeAllItems()
            for library in libraries {
                let item = NSMenuItem(title:library.name,action:nil,keyEquivalent:"")
                item.representedObject = library.id; picker.menu?.addItem(item)
            }
        }
        if let index = picker.itemArray.firstIndex(where:{ $0.representedObject as? String == selection }) { picker.selectItem(at:index) }
    }
}
final class CitationLibraryPopUp: NSPopUpButton {
    override var acceptsFirstResponder: Bool { true }
    var values: [String] = []
    var changed: (String) -> Void = { _ in }
    @objc func choose(_ sender: Any?) { if let id = selectedItem?.representedObject as? String { changed(id) } }
}

struct CitationLibraryReload: NSViewRepresentable {
    var loading: Bool
    var action: () -> Void
    func makeNSView(context: Context) -> CitationLibraryReloadButton {
        let button = CitationLibraryReloadButton()
        button.image = NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"Reload Zotero libraries")
        button.imagePosition = .imageOnly; button.bezelStyle = .rounded
        button.setAccessibilityLabel("Reload Zotero libraries"); button.toolTip = "Reload Zotero libraries"
        button.target = button; button.action = #selector(CitationLibraryReloadButton.reload(_:))
        return button
    }
    func updateNSView(_ button: CitationLibraryReloadButton,context: Context) { button.reload = action; button.isEnabled = !loading }
}
final class CitationLibraryReloadButton: NSButton {
    var reload: () -> Void = {}
    @objc func reload(_ sender: Any?) { reload() }
}

@MainActor final class CitationKeyboard: ObservableObject {
    weak var table: CitationResultTable?
    weak var library: CitationLibraryPopUp?
    var highlightedReference: ZoteroReference? { table?.highlightedReference }
    func move(_ delta: Int) { table?.moveHighlight(delta) }
    func focusLibrary() -> Bool { guard let library, let window = library.window else { return false }; return window.makeFirstResponder(library) }
}

struct CitationQueryField: NSViewRepresentable {
    @Binding var text: String
    var move: (Int) -> Void
    var submit: () -> Void
    var cancel: () -> Void
    var focusLibrary: () -> Bool
    func makeNSView(context: Context) -> CitationQueryTextField {
        let field = CitationQueryTextField()
        field.placeholderString = "Title, author or year"
        field.setAccessibilityLabel("Citation search")
        field.bezelStyle = .roundedBezel; field.font = .systemFont(ofSize:13); field.delegate = field
        return field
    }
    func updateNSView(_ field: CitationQueryTextField,context: Context) {
        field.changed = { text = $0 }; field.move = move; field.submit = submit; field.cancel = cancel
        field.focusLibrary = focusLibrary
        field.syncText(text)
        field.focusWhenAttached()
    }
}
final class CitationQueryTextField: NSTextField, NSTextFieldDelegate {
    var changed: (String) -> Void = { _ in }
    var move: (Int) -> Void = { _ in }
    var submit: () -> Void = {}
    var cancel: () -> Void = {}
    var focusLibrary: () -> Bool = { false }
    private var didFocus = false
    func syncText(_ text: String) {
        // Loading/result updates must leave the native candidate composition alone.
        guard (currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if stringValue != text { stringValue = text }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusWhenAttached() }
    func focusWhenAttached() {
        guard !didFocus, let window else { return }
        DispatchQueue.main.async { [weak self,weak window] in
            guard let self, !self.didFocus, let window, self.window === window,
                  window.makeFirstResponder(self) else { return }
            self.didFocus = true
        }
    }
    func controlTextDidChange(_ notification: Notification) { changed(stringValue) }
    func control(_ control: NSControl,textView: NSTextView,doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): submit()
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        case #selector(NSResponder.insertTab(_:)): return focusLibrary()
        default: return false
        }
        return true
    }
}

struct CitationResults: NSViewRepresentable {
    var references: [ZoteroReference]
    var cited: Set<String>
    @Binding var chosen: [String:ZoteroReference]
    var keyboard: CitationKeyboard
    var submit: () -> Void
    var cancel: () -> Void
    func makeNSView(context: Context) -> NSScrollView {
        let table = CitationResultTable()
        let column = NSTableColumn(identifier:.init("reference")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 48; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.dataSource = table; table.delegate = table
        table.setAccessibilityLabel("Citation results")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView,context: Context) {
        let table = scroll.documentView as! CitationResultTable
        keyboard.table = table; table.submit = submit; table.cancel = cancel
        table.toggle = { ref in if chosen[ref.id] == nil { chosen[ref.id] = ref } else { chosen.removeValue(forKey:ref.id) } }
        let highlightedReference = table.highlightedReference?.id
        table.references = references; table.cited = cited; table.chosen = Set(chosen.keys)
        table.reloadData()
        if let highlightedReference, let row = references.firstIndex(where:{ $0.id == highlightedReference }) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
        else { table.deselectAll(nil) }
    }
}
final class CitationResultTable: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    var references: [ZoteroReference] = []
    var cited = Set<String>(), chosen = Set<String>()
    var toggle: (ZoteroReference) -> Void = { _ in }
    var submit: () -> Void = {}, cancel: () -> Void = {}
    var highlightedReference: ZoteroReference? { references.indices.contains(selectedRow) ? references[selectedRow] : nil }
    func numberOfRows(in tableView: NSTableView) -> Int { references.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let ref = references[row]
        let check = NSButton(checkboxWithTitle:"",target:self,action:#selector(toggleRow(_:)))
        check.tag = row; check.state = chosen.contains(ref.id) ? .on : .off
        check.setAccessibilityLabel("Select "+ref.title)
        let title = NSTextField(labelWithString:ref.title+(cited.contains(ref.citeKey) ? " — Already cited" : ""))
        title.font = .systemFont(ofSize:12); title.lineBreakMode = .byTruncatingTail
        let details = NSTextField(labelWithString:[ref.author,ref.year].filter { !$0.isEmpty }.joined(separator:" · "))
        details.font = .systemFont(ofSize:10); details.textColor = .secondaryLabelColor
        let labels = NSStackView(views:[title,details]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        let cell = NSStackView(views:[check,labels]); cell.spacing = 8; cell.edgeInsets = .init(top:4,left:4,bottom:4,right:4)
        return cell
    }
    @objc func toggleRow(_ sender: NSButton) {
        guard references.indices.contains(sender.tag) else { return }
        toggle(references[sender.tag])
    }
    func moveHighlight(_ delta: Int) {
        guard !references.isEmpty else { return }
        let row = selectedRow < 0 ? (delta > 0 ? 0 : references.count-1) : max(0,min(references.count-1,selectedRow+delta))
        window?.makeFirstResponder(self); selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); scrollRowToVisible(row)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36,76: submit()
        case 53: cancel()
        case 49: if let highlightedReference { toggle(highlightedReference) }
        default: super.keyDown(with:event)
        }
    }
}
