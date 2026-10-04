import AppKit
import SwiftUI
import PDFKit
import ImageIO
import BlankCore

final class WeakTableView { weak var value: TableBlockView?; init(_ value: TableBlockView) { self.value = value } }
@MainActor final class ObjectAttachment: NSTextAttachment {
    weak var editor: NativeTextView?
    let index: Int
    let width: CGFloat
    init(editor: NativeTextView,index: Int,width: CGFloat) {
        self.editor = editor; self.index = index; self.width = width
        super.init(data:nil,ofType:nil)
        // NSTextView on the tested SDK requests providers for measurement but
        // does not mount them. Reserve native attachment geometry and mount the
        // visible AppKit controls in NativeTextView instead.
        allowsTextAttachmentView = false
        bounds = NSRect(x:0,y:0,width:width,height:height)
        image = NSImage(size:bounds.size)
    }
    required init?(coder: NSCoder) { fatalError() }
    var block: ProjectedBlock? {
        guard let blocks = editor?.session?.buffer.projection.blocks, blocks.indices.contains(index) else { return nil }; return blocks[index]
    }
    var height: CGFloat {
        guard let block, let session = editor?.session else { return 80 }
        if block.kind == "table", block.columns > 0 { return CGFloat((block.tableCells.count+block.columns-1)/block.columns)*54+34 }
        let raw = session.buffer.source.bytes(block.source)
        if let path = imagePath(raw), let size = imageDimensions(path,session:session) {
            return min(440,width*0.85*size.height/max(1,size.width))+64
        }
        return 100
    }
}
final class TableCellField: NSTextField {
    var index = 0
    var model = DocumentBuffer()
}
final class TableBlockView: NSView, NSTextFieldDelegate {
    weak var editor: NativeTextView?
    let index: Int
    var fields: [TableCellField] = []
    var columns = 1
    var first = true
    override var isFlipped: Bool { true }
    init(editor: NativeTextView,index: Int,frame: NSRect) {
        self.editor = editor; self.index = index
        super.init(frame:frame)
        guard let session = editor.session, session.buffer.projection.blocks.indices.contains(index) else { return }
        let block = session.buffer.projection.blocks[index]; columns = max(1,block.columns)
        for (i,span) in block.tableCells.enumerated() {
            let model = DocumentBuffer(session.buffer.source.bytes(span))
            let field = TableCellField(); field.index = i; field.model = model; field.stringValue = model.projection.text
            field.isBordered = false; field.drawsBackground = false; field.isEditable = true; field.isSelectable = true
            field.textColor = session.inkColor
            field.font = editor.readingFont(size:CGFloat(session.fontSize)*0.85,bold:i < columns)
            field.cell?.wraps = true; field.cell?.isScrollable = false; field.lineBreakMode = .byWordWrapping
            field.delegate = self; field.setAccessibilityLabel("Table row \(i/columns+1), column \(i%columns+1)")
            addSubview(field); fields.append(field)
        }
        let controls = NSButton(title:"Table options…",target:self,action:#selector(options(_:))); controls.isBordered = false; controls.font = .systemFont(ofSize:10); controls.contentTintColor = session.systemColors ? .secondaryLabelColor : session.inkColor.withAlphaComponent(0.65)
        controls.frame = NSRect(x:0,y:frame.height-27,width:115,height:24); addSubview(controls)
        layoutFields()
    }
    required init?(coder: NSCoder) { fatalError() }
    func layoutFields() {
        let cellWidth = bounds.width/CGFloat(columns)
        for field in fields { field.frame = NSRect(x:CGFloat(field.index%columns)*cellWidth+12,y:CGFloat(field.index/columns)*54+15,width:cellWidth-24,height:40) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (editor?.session?.inkColor ?? .labelColor).withAlphaComponent(0.22).setStroke()
        let path = NSBezierPath(); path.lineWidth = 0.5
        let rows = (fields.count+columns-1)/columns
        for row in 0...rows { let y = CGFloat(row)*54+7; path.move(to:NSPoint(x:0,y:y)); path.line(to:NSPoint(x:bounds.width,y:y)) }
        for column in 0...columns { let x = CGFloat(column)*bounds.width/CGFloat(columns); path.move(to:NSPoint(x:x,y:7)); path.line(to:NSPoint(x:x,y:CGFloat(rows)*54+7)) }
        path.stroke()
    }
    @objc func options(_ sender: Any?) { window?.makeFirstResponder(editor); editor?.objectEditing = false; editor?.session?.editObject(index) }
    func controlTextDidBeginEditing(_ obj: Notification) { editor?.objectEditing = true; editor?.session?.buffer.breakUndoGroup() }
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? TableCellField, let session = editor?.session,
              session.buffer.projection.blocks.indices.contains(index) else { return }
        let block = session.buffer.projection.blocks[index]
        guard block.tableCells.indices.contains(field.index), let patch = SourcePatch.difference(field.model.projection.text,field.stringValue) else { return }
        let old = field.model.projection.text
        let span = block.tableCells[field.index], location = old.utf16Offset(byte:patch.start)
        session.buffer.selection = EditSelection(span.start+field.model.projection.sourceOffset(at:location),span.start+field.model.projection.sourceOffset(at:location+patch.removed.utf16.count))
        field.model.editWrite(NSRange(location:old.utf16Offset(byte:patch.start),length:patch.removed.utf16.count),text:patch.inserted)
        session.buffer.commit(session.buffer.source.replacingBytes(span,with:field.model.source),selection:EditSelection(span.start+field.model.selection.focus,span.start+field.model.selection.focus),group:"table")
        session.changed()
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.editor else { return }
            let editingCell = self.fields.contains { $0.currentEditor() != nil }
            if !editingCell { editor.objectEditing = false; editor.refresh() }
        }
    }
    func control(_ control: NSControl,textView: NSTextView,doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? TableCellField else { return false }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            let next = field.index+1
            if next < fields.count { window?.makeFirstResponder(fields[next]) }
            else { addRowAndFocus() }
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            if field.index > 0 { window?.makeFirstResponder(fields[field.index-1]) }
            else { editor?.objectEditing = false; window?.makeFirstResponder(editor) }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { editor?.objectEditing = false; window?.makeFirstResponder(editor); editor?.refresh(); return true }
        return false
    }
    func addRowAndFocus() {
        guard let editor, let session = editor.session else { return }
        let block = session.buffer.projection.blocks[index]
        let raw = session.buffer.source.bytes(block.source)
        let needsComma = !raw.dropLast().trimmingCharacters(in:.whitespacesAndNewlines).hasSuffix(",")
        let insertion = (needsComma ? "," : "")+"\n"+(0..<columns).map { _ in "  [],\n" }.joined()
        let at = block.source.end-1, cellCount = fields.count
        session.buffer.commit(session.buffer.source.replacingBytes(ByteSpan(at,at),with:insertion),selection:session.buffer.selection)
        editor.objectEditing = false; session.changed()
        DispatchQueue.main.async { [weak editor] in
            if let table = editor?.tableViews[self.index]?.value, table.fields.indices.contains(cellCount) { table.window?.makeFirstResponder(table.fields[cellCount]) }
        }
    }
}
final class FigureBlockView: NSView {
    weak var editor: NativeTextView?
    let index: Int
    override var isFlipped: Bool { true }
    init(editor: NativeTextView,index: Int,frame: NSRect) {
        self.editor = editor; self.index = index; super.init(frame:frame)
        guard let session = editor.session else { return }
        let block = session.buffer.projection.blocks[index], raw = session.buffer.source.bytes(block.source)
        let imageView = NSImageView(frame:NSRect(x:frame.width*0.075,y:0,width:frame.width*0.85,height:frame.height-64))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        if let path = imagePath(raw) { imageView.image = loadImage(path,session:session) }
        addSubview(imageView)
        let parsed = ParsedSource.parse(raw)
        let caption = parsed.tree.descendants("Named").first { raw.bytes($0.span).hasPrefix("caption:") }?.descendants("ContentBlock").first?.markup
        let text = caption.map { DocumentBuffer(raw.bytes($0.span)).projection.text } ?? (imageView.image == nil ? "Figure unavailable · Edit source to check the path" : "")
        let label = NSTextField(wrappingLabelWithString:text); label.font = editor.readingFont(size:14,italic:true); label.textColor = session.systemColors ? .secondaryLabelColor : session.inkColor.withAlphaComponent(0.65); label.alignment = .center
        label.frame = NSRect(x:20,y:frame.height-57,width:frame.width-40,height:40); addSubview(label)
        setAccessibilityLabel("Figure: "+text)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { if event.clickCount >= 2 { editor?.session?.editObject(index) } }
}
func imagePath(_ raw: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern:"(?:#)?image\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\""), let match = regex.firstMatch(in:raw,range:NSRange(location:0,length:raw.utf16.count)) else { return nil }
    let quoted = "\""+(raw as NSString).substring(with:match.range(at:1))+"\""
    return try? JSONDecoder().decode(String.self,from:Data(quoted.utf8))
}
@MainActor private let figureCache: NSCache<NSString,NSImage> = {
    let cache = NSCache<NSString,NSImage>(); cache.countLimit = 24; cache.totalCostLimit = 64*1024*1024; return cache
}()
@MainActor func imageData(_ path: String,session: DocumentSession) -> Data? {
    guard let path = session.projectAssetPath(path) else { return nil }
    if let data = session.assets[path] { return data }
    guard let root = session.root else { return nil }
    let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
    guard url.path.hasPrefix(root.resolvingSymlinksInPath().path+"/") else { return nil }
    return try? Data(contentsOf:url,options:.mappedIfSafe)
}
@MainActor func imageDimensions(_ path: String,session: DocumentSession) -> NSSize? {
    guard let data = imageData(path,session:session) else { return nil }
    if path.lowercased().hasSuffix(".pdf"), let page = PDFDocument(data:data)?.page(at:0) { return page.bounds(for:.mediaBox).size }
    guard let source = CGImageSourceCreateWithData(data as CFData,nil), let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any], let width = props[kCGImagePropertyPixelWidth as String] as? Double, let height = props[kCGImagePropertyPixelHeight as String] as? Double else { return nil }
    return NSSize(width:width,height:height)
}
@MainActor func loadImage(_ path: String,session: DocumentSession) -> NSImage? {
    guard let projectPath = session.projectAssetPath(path) else { return nil }
    let version = session.assets[projectPath].map { "\($0.count):\($0.hashValue)" } ?? (session.root.flatMap { try? $0.appendingPathComponent(projectPath).resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate }.map { String($0.timeIntervalSince1970) } ?? "missing")
    let key = (session.id+":"+projectPath+":"+version) as NSString
    if let cached = figureCache.object(forKey:key) { return cached }
    guard let data = imageData(path,session:session) else { return nil }
    let image: NSImage
    if path.lowercased().hasSuffix(".pdf"), let page = PDFDocument(data:data)?.page(at:0) { image = page.thumbnail(of:NSSize(width:1000,height:1000),for:.mediaBox) }
    else if let source = CGImageSourceCreateWithData(data as CFData,nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1400,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) { image = NSImage(cgImage:thumbnail,size:.zero) }
    else if let native = NSImage(data:data) { image = native }
    else { return nil }
    let cost = Int(max(1,image.size.width)*max(1,image.size.height)*4)
    figureCache.setObject(image,forKey:key,cost:cost)
    return image
}
