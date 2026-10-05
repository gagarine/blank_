import AppKit
import PDFKit
import BlankCore

// Text thumbnails use a separate native layout over the editor's attributed
// snapshot. Rendering is demand-driven and never changes source or selections.
@MainActor final class DocumentThumbnails: NSObject, ObservableObject {
    weak var session: DocumentSession?
    @Published private(set) var pages: [Int] = [0]
    @Published private(set) var generation = 0
    @Published private(set) var currentPage = 0
    private var storage: NSTextStorage?
    private var layout: NSLayoutManager?
    private var containers: [NSTextContainer] = []
    private var ranges: [NSRange] = []
    private var labels: [(Int,String)] = []
    private var pageSize = NSSize(width:808,height:1142)
    private var key = ""
    private weak var observedClip: NSClipView?
    private weak var observedEditor: NativeTextView?
    private var resizeWork: DispatchWorkItem?
    private let cache: NSCache<NSString,NSImage> = {
        let cache = NSCache<NSString,NSImage>(); cache.countLimit = 32; cache.totalCostLimit = 16*1024*1024; return cache
    }()
    init(session: DocumentSession) { self.session = session; super.init() }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func scrolled(_ notification: Notification) {
        guard let session, session.sidebar, session.sidebarMode != .contents, session.mode != .preview,
              let editor = session.editor, !ranges.isEmpty else { return }
        let point = NSPoint(x:editor.textContainerInset.width+2,y:editor.visibleRect.minY+(editor.enclosingScrollView?.contentInsets.top ?? 0)+8)
        let offset = editor.characterIndexForInsertion(at:point)
        let page = ranges.firstIndex { $0.contains(offset) } ?? max(0,pages.count-1)
        if currentPage != page { currentPage = page }
    }
    @objc private func resized(_ notification: Notification) {
        guard let session, session.contactSheet || session.sidebar && session.sidebarMode != .contents, session.mode != .preview else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.update() }
        resizeWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.18,execute:work)
    }
    func update() {
        guard let session, session.mode != .preview, let editor = session.editor else { return }
        if observedEditor !== editor {
            NotificationCenter.default.removeObserver(self)
            observedEditor = editor; observedClip = editor.enclosingScrollView?.contentView
            editor.postsFrameChangedNotifications = true; observedClip?.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self,selector:#selector(scrolled(_:)),name:NSView.boundsDidChangeNotification,object:observedClip)
            NotificationCenter.default.addObserver(self,selector:#selector(resized(_:)),name:NSView.frameDidChangeNotification,object:editor)
        }
        editor.refresh()
        let next = "\(session.mode):\(session.active):\(session.buffer.revision):\(session.buffer.presentationRevision):\(editor.lastAppearance):\(editor.textContainer?.containerSize.width ?? 720)"
        guard key != next else { return }; key = next
        cache.removeAllObjects(); generation += 1; containers = []; ranges = []; labels = []
        let snapshot = NSMutableAttributedString(attributedString:editor.textStorage ?? NSTextStorage())
        // Figures are native attachment overlays in the main editor. Give the
        // immutable thumbnail its own image attachment, never its live controls.
        snapshot.enumerateAttribute(.attachment,in:NSRange(location:0,length:snapshot.length)) { value,range,_ in
            guard let attachment = value as? ObjectAttachment, let block = attachment.block else { return }
            let raw = session.buffer.source.bytes(block.source), size = attachment.bounds.size
            let image = NSImage(size:size,flipped:true) { [weak session,weak editor] rect in
                guard let session, let editor else { return false }
                if let path = imagePath(raw), let figure = loadImage(path,session:session) {
                    figure.draw(in:NSRect(x:rect.width*0.075,y:0,width:rect.width*0.85,height:rect.height-64),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
                }
                let caption = ParsedSource.parse(raw).tree.descendants("Named").first { raw.bytes($0.span).hasPrefix("caption:") }?.descendants("ContentBlock").first?.markup
                if let caption {
                    let text = DocumentBuffer(raw.bytes(caption.span)).projection.text
                    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
                    (text as NSString).draw(in:NSRect(x:20,y:rect.height-57,width:rect.width-40,height:40),withAttributes:[.font:editor.readingFont(size:14,italic:true),.foregroundColor:session.inkColor,.paragraphStyle:paragraph])
                }
                return true
            }
            let copy = NSTextAttachment(); copy.bounds = attachment.bounds; copy.image = image
            snapshot.addAttribute(.attachment,value:copy,range:range)
        }
        if session.mode == .write {
            for (index,block) in session.buffer.projection.blocks.enumerated() where ["bullet","number"].contains(block.kind) {
                labels.append((block.display.location,block.kind == "bullet" ? "•" : "\(editor.listNumber(index))."))
            }
        }
        let contentWidth = max(200,editor.textContainer?.containerSize.width ?? 720)
        pageSize = NSSize(width:contentWidth+88,height:(contentWidth+88)*sqrt(2))
        let text = NSTextStorage(attributedString:snapshot), manager = NSLayoutManager()
        text.addLayoutManager(manager); storage = text; layout = manager
        var end = 0
        repeat {
            let container = NSTextContainer(containerSize:NSSize(width:contentWidth,height:pageSize.height-88)); container.lineFragmentPadding = 0
            manager.addTextContainer(container); manager.ensureLayout(for:container)
            let glyphs = manager.glyphRange(for:container), characters = manager.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
            containers.append(container); ranges.append(characters)
            let next = NSMaxRange(glyphs)
            if next <= end { break }; end = next
        } while end < manager.numberOfGlyphs
        pages = Array(containers.indices)
        currentPage = ranges.firstIndex { $0.contains(editor.selectedRange().location) } ?? max(0,pages.count-1)
    }
    func image(_ page: Int,width: CGFloat = 170) -> NSImage? {
        guard let session, let appearance = session.editor?.effectiveAppearance, let layout, containers.indices.contains(page) else { return nil }
        let key = "text:\(generation):\(page):\(width)" as NSString
        if let image = cache.object(forKey:key) { return image }
        let scale = width/pageSize.width
        let image = NSImage(size:NSSize(width:width,height:pageSize.height*scale),flipped:true) { [self] rect in
            session.paperColor.setFill(); rect.fill()
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = AffineTransform(scale:scale); (transform as NSAffineTransform).concat()
            let glyphs = layout.glyphRange(for:containers[page])
            layout.drawBackground(forGlyphRange:glyphs,at:NSPoint(x:44,y:44))
            layout.drawGlyphs(forGlyphRange:glyphs,at:NSPoint(x:44,y:44))
            for (offset,label) in labels where ranges[page].contains(offset) {
                let glyph = layout.glyphIndexForCharacter(at:offset), line = layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
                (label as NSString).draw(at:NSPoint(x:44+line.minX,y:44+line.minY),withAttributes:[.font:NSFont.systemFont(ofSize:CGFloat(session.fontSize)),.foregroundColor:session.inkColor])
            }
            return true
        }
        // Materialize the raster now: lazy drawing closures otherwise retain
        // old text layouts and rerun every time a thumbnail is displayed.
        var data: Data?
        appearance.performAsCurrentDrawingAppearance { data = image.tiffRepresentation }
        guard let data, let raster = NSImage(data:data) else { return nil }
        cache.setObject(raster,forKey:key,cost:Int(raster.size.width*raster.size.height*4)); return raster
    }
    func pdfThumbnail(_ page: Int,width: CGFloat) -> NSImage? {
        guard let session, let pdf = session.pdf, let target = pdf.page(at:page) else { return nil }
        let key = "pdf:\(session.compileRevision):\(ObjectIdentifier(pdf)):\(page):\(width)" as NSString
        if let image = cache.object(forKey:key) { return image }
        let image = target.thumbnail(of:NSSize(width:width,height:width*sqrt(2)),for:.mediaBox)
        cache.setObject(image,forKey:key,cost:Int(image.size.width*image.size.height*4)); return image
    }
    func navigate(_ page: Int) {
        guard let session, ranges.indices.contains(page), let editor = session.editor else { return }
        let range = NSRange(location:ranges[page].location,length:0)
        editor.finishComposition(); editor.setSelectedRange(range); editor.captureSelection(); editor.scrollRangeToVisible(range)
        currentPage = page; session.window?.makeFirstResponder(editor)
    }
}
