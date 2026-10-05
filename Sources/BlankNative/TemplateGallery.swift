import AppKit
import SwiftUI
import PDFKit
import Combine
import BlankCore

@MainActor final class TemplateGalleryWindow: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    let library: TemplateLibrary
    var subscriptions = Set<AnyCancellable>()
    init(library: TemplateLibrary) {
        self.library = library
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1040,height:540),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:window)
        window.title = "Templates"; window.toolbarStyle = .unified; window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width:620,height:470); window.center(); window.isReleasedWhenClosed = false; window.delegate = self
        window.contentViewController = NSHostingController(rootView:TemplateGallery(library:library,owner:self))
        let toolbar = NSToolbar(identifier:"Templates"); toolbar.delegate = self; toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setContentSize(NSSize(width:1040,height:500))
        library.$selection.combineLatest(library.$generation).sink { [weak self] _,_ in
            DispatchQueue.main.async { self?.window?.toolbar?.validateVisibleItems() }
        }.store(in:&subscriptions)
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowDidBecomeKey(_ notification: Notification) { perform { try library.reload() } }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("add"),.init("preview"),.init("edit"),.init("actions"),.flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("add"),.flexibleSpace,.init("preview"),.init("edit"),.init("actions")] }
    func toolbar(_ toolbar: NSToolbar,itemForItemIdentifier id: NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func item(_ label: String,_ symbol: String,_ action: Selector) -> NSToolbarItem {
            let result = NSToolbarItem(itemIdentifier:id); result.label = label; result.toolTip = label
            result.image = NSImage(systemSymbolName:symbol,accessibilityDescription:label); result.target = self; result.action = action; result.isBordered = true
            return result
        }
        func menuItem(_ title: String,_ action: Selector) -> NSMenuItem {
            let result = NSMenuItem(title:title,action:action,keyEquivalent:""); result.target = self; return result
        }
        if id.rawValue == "add" {
            let result = NSMenuToolbarItem(itemIdentifier:id); result.label = "Add Template"; result.toolTip = "Add Template"
            result.image = NSImage(systemSymbolName:"plus",accessibilityDescription:"Add Template"); result.isBordered = true
            result.menu = NSMenu(); result.menu.addItem(menuItem("New Template…",#selector(newTemplate(_:)))); result.menu.addItem(menuItem("Add Document…",#selector(importTemplate(_:))))
            return result
        }
        if id.rawValue == "preview" { return item("Preview Template","eye",#selector(preview(_:))) }
        if id.rawValue == "edit" { return item("Edit Template","pencil",#selector(edit(_:))) }
        if id.rawValue == "actions" {
            let result = NSMenuToolbarItem(itemIdentifier:id); result.label = "Template Actions"; result.toolTip = "Template Actions"; result.isBordered = true
            result.image = NSImage(systemSymbolName:"ellipsis.circle",accessibilityDescription:"Template Actions")
            result.menu = NSMenu(); result.menu.addItem(menuItem("Duplicate",#selector(duplicate(_:)))); result.menu.addItem(.separator()); result.menu.addItem(menuItem("Move to Trash",#selector(trash(_:))))
            return result
        }
        return nil
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { item.itemIdentifier.rawValue == "add" || library.selected != nil }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(trash(_:)) { return library.selected.map { !library.isEditing($0) } ?? false }
        if [#selector(duplicate(_:)),#selector(edit(_:)),#selector(preview(_:))].contains(where:{ $0 == item.action }) { return library.selected != nil }
        return true
    }
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { window?.presentError(error) }
    }
    func namePrompt(title: String,name: String,submit: String,action: @escaping (String) throws -> Void) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = title; alert.addButton(withTitle:submit); alert.addButton(withTitle:"Cancel")
        let field = NSTextField(string:name); field.frame = NSRect(x:0,y:0,width:280,height:24); field.setAccessibilityLabel("Template name")
        alert.accessoryView = field
        alert.beginSheetModal(for:window) { [weak self] result in
            if result == .alertFirstButtonReturn { self?.perform { try action(field.stringValue) } }
        }
        window.attachedSheet?.makeFirstResponder(field); field.selectText(nil)
    }
    @objc func newTemplate(_ sender: Any?) {
        namePrompt(title:"New Template",name:"Untitled Template",submit:"Create") { [weak self] name in
            guard let self else { return }; let item = try library.add(DocumentSession(),name:name); try openEditor(item)
        }
    }
    @objc func importTemplate(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension:"typ")!]; panel.title = "Add a Template"; panel.prompt = "Add"
        panel.beginSheetModal(for:window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            perform {
                let session = DocumentSession(); try session.open(url)
                defer { session.watchers.forEach { $0.cancel() } }
                _ = try self.library.add(session,name:session.title)
            }
        }
    }
    func addDocument(_ session: DocumentSession) {
        namePrompt(title:"Save as Template",name:session.title,submit:"Add") { [weak self] name in _ = try self?.library.add(session,name:name) }
    }
    @objc func createDocument(_ sender: Any?) {
        guard let item = library.selected else { return }
        perform { let session = try library.newDocument(from:item); AppController.shared.show(session); window?.orderOut(nil) }
    }
    @objc func duplicate(_ sender: Any?) { if let item = library.selected { perform { _ = try library.duplicate(item) } } }
    @objc func edit(_ sender: Any?) { if let item = library.selected { perform { try openEditor(item) } } }
    func openEditor(_ item: DocumentTemplate) throws {
        if let controller = AppController.shared.controllers.first(where:{ $0.session.root?.standardizedFileURL == library.folder(item.id).standardizedFileURL }) {
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return
        }
        let session = DocumentSession(); try session.open(library.url(item))
        TemplateLibrary.prepareForWriting(session,selectTitle:false)
        AppController.shared.show(session)
    }
    @objc func preview(_ sender: Any?) {
        guard let item = library.selected else { return }
        perform {
            try library.saveOpenEditor(item)
            let current = library.templates.first { $0.id == item.id } ?? item
            library.requestPreview(current,full:true)
            NotificationCenter.default.post(name:.templatePreviewRequested,object:self,userInfo:["id":current.id])
        }
    }
    @objc func trash(_ sender: Any?) {
        guard let item = library.selected, let window else { return }
        guard !library.isEditing(item) else { perform { throw TemplateLibrary.failure("Close this template’s editor before moving it to the Trash.") }; return }
        let alert = NSAlert(); alert.messageText = "Move “\(item.name)” to the Trash?"; alert.informativeText = "Documents created from this template will not be affected. You can restore the template from the Trash."
        alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Move to Trash")
        alert.beginSheetModal(for:window) { [weak self] result in if result == .alertSecondButtonReturn { self?.perform { try self?.library.moveToTrash(item) } } }
    }
}

extension Notification.Name { static let templatePreviewRequested = Notification.Name("templatePreviewRequested") }
private struct TemplatePreviewSelection: Identifiable { let id: String }

struct TemplateGallery: View {
    @ObservedObject var library: TemplateLibrary
    let owner: TemplateGalleryWindow
    @NativeState private var preview: TemplatePreviewSelection?
    @NativeState private var createAfterPreview = false
    var body: some View {
        VStack(spacing:0) {
            TemplateCollection(library:library,owner:owner).frame(maxWidth:.infinity,maxHeight:.infinity)
            HStack {
                Text(library.templates.isEmpty ? "Add a template to get started." : "Choose a template for a new document.").foregroundStyle(.secondary)
                Spacer()
                Button("Create Document") { owner.createDocument(nil) }.keyboardShortcut(.defaultAction).disabled(library.selected == nil)
            }.padding(18)
        }.background(Color(nsColor:.windowBackgroundColor))
        .sheet(item:$preview,onDismiss:{
            if createAfterPreview { createAfterPreview = false; owner.createDocument(nil) }
        }) { choice in
            TemplatePreview(library:library,id:choice.id,create:{
                guard library.templates.contains(where:{ $0.id == choice.id }) else { return }
                library.selection = choice.id; createAfterPreview = true; preview = nil
            },dismiss:{ preview = nil })
        }
        .onReceive(NotificationCenter.default.publisher(for:.templatePreviewRequested)) { notification in
            guard (notification.object as? TemplateGalleryWindow) === owner, let id = notification.userInfo?["id"] as? String else { return }
            preview = TemplatePreviewSelection(id:id)
        }
    }
}
struct TemplatePreview: View {
    @ObservedObject var library: TemplateLibrary
    let id: String
    var create: () -> Void
    var dismiss: () -> Void
    var item: DocumentTemplate? { library.templates.first { $0.id == id } }
    var body: some View {
        VStack(spacing:16) {
            HStack { Text(item?.name ?? "Template Preview").font(.headline); Spacer(); Button("Done",action:dismiss).keyboardShortcut(.cancelAction) }
            if let item, let data = library.pdf(item) { TemplatePDFView(data:data).frame(maxWidth:.infinity,maxHeight:.infinity) }
            else if let error = library.renderErrors[id] { ContentUnavailableView("Preview Unavailable",systemImage:"exclamationmark.triangle",description:Text(error)).frame(maxWidth:.infinity,maxHeight:.infinity) }
            else { ProgressView("Preparing Preview…").frame(maxWidth:.infinity,maxHeight:.infinity) }
            HStack { Spacer(); Button("Create Document",action:create).keyboardShortcut(.defaultAction).disabled(item == nil) }
        }.padding(20).frame(width:580,height:640)
        .onAppear { if let item { library.requestPreview(item,full:true) } }
        .onChange(of:item?.version) { _,_ in if let item { library.requestPreview(item,full:true) } }
    }
}
struct TemplatePDFView: NSViewRepresentable {
    let data: Data
    final class Coordinator { var data: Data? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.backgroundColor = .windowBackgroundColor
        view.document = PDFDocument(data:data); context.coordinator.data = data; return view
    }
    func updateNSView(_ view: PDFView,context: Context) { if context.coordinator.data != data { context.coordinator.data = data; view.document = PDFDocument(data:data) } }
}

struct TemplateCollection: NSViewRepresentable {
    @ObservedObject var library: TemplateLibrary
    let owner: TemplateGalleryWindow
    func makeCoordinator() -> Coordinator { Coordinator(library:library,owner:owner) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let collection = TemplateGrid(frame:NSRect(origin:.zero,size:scroll.contentSize)); collection.owner = owner
        collection.isSelectable = true; collection.allowsMultipleSelection = false; collection.backgroundColors = [.windowBackgroundColor]
        let layout = NSCollectionViewFlowLayout(); layout.itemSize = NSSize(width:176,height:264); layout.minimumInteritemSpacing = 22; layout.minimumLineSpacing = 24
        layout.sectionInset = NSEdgeInsets(top:24,left:24,bottom:24,right:24); collection.collectionViewLayout = layout
        collection.register(TemplateTile.self,forItemWithIdentifier:.init("Template")); collection.dataSource = context.coordinator; collection.delegate = context.coordinator
        collection.autoresizingMask = [.width]; scroll.documentView = collection; context.coordinator.collection = collection
        collection.setAccessibilityLabel("Template library"); return scroll
    }
    func updateNSView(_ view: NSScrollView,context: Context) {
        let coordinator = context.coordinator
        if coordinator.generation != library.generation { coordinator.generation = library.generation; coordinator.collection?.reloadData() }
        if let index = library.templates.firstIndex(where:{ $0.id == library.selection }) {
            let path = IndexPath(item:index,section:0)
            if coordinator.collection?.selectionIndexPaths != [path] { coordinator.collection?.selectItems(at:[path],scrollPosition:[]) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let library: TemplateLibrary
        weak var owner: TemplateGalleryWindow?
        weak var collection: TemplateGrid?
        var generation = -1
        init(library: TemplateLibrary,owner: TemplateGalleryWindow) { self.library = library; self.owner = owner }
        func collectionView(_ collectionView: NSCollectionView,numberOfItemsInSection section: Int) -> Int { library.templates.count }
        func collectionView(_ collectionView: NSCollectionView,itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let tile = collectionView.makeItem(withIdentifier:.init("Template"),for:indexPath) as! TemplateTile
            let item = library.templates[indexPath.item]
            tile.imageView?.image = library.image(item) ?? NSImage(systemSymbolName:"doc",accessibilityDescription:"Preparing preview")
            tile.textField?.stringValue = item.name; tile.view.setAccessibilityLabel(item.name+" template")
            tile.view.toolTip = library.renderErrors[item.id] ?? item.name
            DispatchQueue.main.async { [weak self] in self?.library.requestPreview(item) }
            return tile
        }
        func collectionView(_ collectionView: NSCollectionView,didSelectItemsAt indexPaths: Set<IndexPath>) {
            if let index = indexPaths.first?.item, library.templates.indices.contains(index) { library.selection = library.templates[index].id }
        }
    }
}
final class TemplateGrid: NSCollectionView {
    weak var owner: TemplateGalleryWindow?
    override func mouseDown(with event: NSEvent) { super.mouseDown(with:event); if event.clickCount == 2, indexPathForItem(at:convert(event.locationInWindow,from:nil)) != nil { owner?.createDocument(nil) } }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36,76: owner?.createDocument(nil)
        case 49: owner?.preview(nil)
        case 51,117: owner?.trash(nil)
        default: super.keyDown(with:event)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let path = indexPathForItem(at:convert(event.locationInWindow,from:nil)), let owner, owner.library.templates.indices.contains(path.item) else { return nil }
        selectItems(at:[path],scrollPosition:[]); owner.library.selection = owner.library.templates[path.item].id
        let menu = NSMenu()
        for (title,action) in [("Create Document",#selector(TemplateGalleryWindow.createDocument(_:))),("Preview",#selector(TemplateGalleryWindow.preview(_:))),("Edit",#selector(TemplateGalleryWindow.edit(_:))),("Duplicate",#selector(TemplateGalleryWindow.duplicate(_:))),("Move to Trash",#selector(TemplateGalleryWindow.trash(_:)))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = owner; menu.addItem(item)
        }
        return menu
    }
}
final class TemplateTile: NSCollectionViewItem {
    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.layer?.cornerRadius = 10
        let image = NSImageView(); image.imageScaling = .scaleProportionallyUpOrDown; image.wantsLayer = true
        image.layer?.borderWidth = 0.5; image.layer?.borderColor = NSColor.separatorColor.cgColor
        image.layer?.shadowOpacity = 0.12; image.layer?.shadowRadius = 3; image.layer?.shadowOffset = NSSize(width:0,height:-1)
        let text = NSTextField(labelWithString:""); text.font = .systemFont(ofSize:13); text.alignment = .center; text.lineBreakMode = .byTruncatingTail
        for child in [image,text] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        imageView = image; textField = text
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo:view.topAnchor,constant:12),image.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),image.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),image.heightAnchor.constraint(equalToConstant:214),
            text.topAnchor.constraint(equalTo:image.bottomAnchor,constant:10),text.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:8),text.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-8),text.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-10)
        ])
    }
    override var isSelected: Bool { didSet { view.layer?.backgroundColor = (isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16) : .clear).cgColor } }
}
