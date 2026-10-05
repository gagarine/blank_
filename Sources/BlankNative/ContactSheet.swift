import AppKit
import SwiftUI

// The overview is a native collection: AppKit owns selection, arrow navigation,
// scrolling and focus. Only visible items request a bounded thumbnail raster.
struct ContactSheetView: NSViewRepresentable {
    @ObservedObject var session: DocumentSession
    @ObservedObject var thumbnails: DocumentThumbnails
    func makeCoordinator() -> Coordinator { Coordinator(session:session) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = true; scroll.borderType = .noBorder
        scroll.backgroundColor = .textBackgroundColor
        let collection = ContactPageCollection(frame:NSRect(origin:.zero,size:scroll.contentSize))
        collection.session = session; collection.autoresizingMask = [.width]
        collection.isSelectable = true; collection.allowsMultipleSelection = false; collection.allowsEmptySelection = false
        collection.backgroundColors = [.textBackgroundColor]
        let layout = NSCollectionViewFlowLayout(); layout.minimumInteritemSpacing = 24; layout.minimumLineSpacing = 24
        layout.sectionInset = NSEdgeInsets(top:24,left:24,bottom:24,right:24)
        collection.collectionViewLayout = layout
        collection.register(ContactPageItem.self,forItemWithIdentifier:NSUserInterfaceItemIdentifier("Page"))
        collection.dataSource = context.coordinator; collection.delegate = context.coordinator
        collection.setAccessibilityLabel("Contact Sheet")
        scroll.documentView = collection
        context.coordinator.collection = collection
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView,context: Context) {
        let coordinator = context.coordinator
        guard let collection = coordinator.collection, let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        // Wait for the underlying native editor's current-width layout after
        // collapsing the sidebar. It remains mounted, preserving input/history.
        if session.mode != .preview {
            DispatchQueue.main.async { [weak session] in if session?.contactSheet == true { session?.thumbnails.update() } }
        }
        let size = session.contactSheetSize
        let key = "\(session.mode):\(thumbnails.generation):\(session.compileRevision):\(coordinator.count):\(size)"
        if coordinator.key != key {
            coordinator.key = key
            layout.itemSize = NSSize(width:size+32,height:size*sqrt(2)+64)
            layout.invalidateLayout(); collection.reloadData()
        }
        if coordinator.count > 0 {
            let index = IndexPath(item:min(coordinator.count-1,session.contactSheetSelection),section:0)
            if collection.selectionIndexPaths != [index] {
                coordinator.synchronizing = true; collection.selectItems(at:[index],scrollPosition:[]); coordinator.synchronizing = false
            }
        }
    }
    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        weak var session: DocumentSession?
        weak var collection: ContactPageCollection?
        var key = ""
        var synchronizing = false
        init(session: DocumentSession) { self.session = session }
        var count: Int { guard let session else { return 0 }; return session.mode == .preview ? session.pdf?.pageCount ?? 0 : session.thumbnails.pages.count }
        func collectionView(_ collectionView: NSCollectionView,numberOfItemsInSection section: Int) -> Int { count }
        func collectionView(_ collectionView: NSCollectionView,itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier:NSUserInterfaceItemIdentifier("Page"),for:indexPath) as! ContactPageItem
            if let session {
                let width = session.contactSheetSize*2
                item.imageView?.image = session.mode == .preview ? session.thumbnails.pdfThumbnail(indexPath.item,width:width) : session.thumbnails.image(indexPath.item,width:width)
                item.textField?.stringValue = "\(indexPath.item+1)"
                item.view.setAccessibilityLabel("\(session.mode.rawValue) page \(indexPath.item+1)")
            }
            return item
        }
        func collectionView(_ collectionView: NSCollectionView,didSelectItemsAt indexPaths: Set<IndexPath>) {
            if !synchronizing, let page = indexPaths.first?.item, session?.contactSheetSelection != page { session?.contactSheetSelection = page }
        }
    }
}

final class ContactPageCollection: NSCollectionView {
    weak var session: DocumentSession?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session?.contactSheet == true, self.session?.searchVisible == false, self.session?.sheet == nil else { return }
            self.window?.makeFirstResponder(self)
        }
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with:event)
        if event.clickCount == 2, let page = selectionIndexPaths.first?.item { session?.openContactPage(page) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if let page = selectionIndexPaths.first?.item { session?.openContactPage(page) }; return
        }
        if event.keyCode == 53 {
            session?.closeContactSheet(); return
        }
        super.keyDown(with:event)
    }
}

final class ContactPageItem: NSCollectionViewItem {
    override func loadView() {
        let tile = ContactPageTile(); tile.owner = self; view = tile; view.wantsLayer = true; view.layer?.cornerRadius = 20
        let image = NSImageView(); image.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString:""); label.alignment = .center; label.font = .systemFont(ofSize:12)
        image.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(image); view.addSubview(label); imageView = image; textField = label
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo:view.topAnchor,constant:16),image.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),
            image.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),image.bottomAnchor.constraint(equalTo:label.topAnchor,constant:-16),
            label.centerXAnchor.constraint(equalTo:view.centerXAnchor),label.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-8),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant:22),label.heightAnchor.constraint(equalToConstant:22)
        ])
        label.wantsLayer = true; label.layer?.cornerRadius = 6; label.layer?.masksToBounds = true
    }
    override var isSelected: Bool { didSet { updateSelection() } }
    fileprivate func updateSelection() {
        guard isViewLoaded else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = isSelected ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor
            textField?.textColor = isSelected ? .white : .labelColor
            textField?.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
    }
}

final class ContactPageTile: NSView {
    weak var owner: ContactPageItem?
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); owner?.updateSelection() }
}
