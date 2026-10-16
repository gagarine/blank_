import AppKit
import SwiftUI
import PDFKit
import ImageIO
import BlankCore

@MainActor final class ObjectAttachment: NSTextAttachment {
    weak var editor: NativeTextView?
    let index: Int
    let width: CGFloat
    init(editor: NativeTextView,index: Int,width: CGFloat) {
        self.editor = editor; self.index = index; self.width = width
        super.init(data:nil,ofType:nil)
        // Figure controls share native attachment geometry and are mounted only
        // while visible. Tables are paragraphs in the text storage itself.
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
        let raw = session.buffer.source.bytes(block.source)
        if let path = imagePath(raw), let size = imageDimensions(path,session:session) {
            return figureImageSize(raw,natural:size,available:width).height+64
        }
        return 100
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
        let natural = imagePath(raw).flatMap { imageDimensions($0,session:session) } ?? NSSize(width:frame.width,height:36)
        let size = figureImageSize(raw,natural:natural,available:frame.width)
        let imageView = NSImageView(frame:NSRect(x:(frame.width-size.width)/2,y:0,width:size.width,height:size.height))
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
    // Image and caption children are display-only; the entire figure opens its editor.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { if event.clickCount >= 2 { editor?.session?.editObject(index) } }
}
func figureImageSize(_ raw: String,natural: NSSize,available: CGFloat) -> NSSize {
    let argument = imageArguments(raw)?.children.first { $0.kind == "Named" && $0.children.first.map { raw.bytes($0.span) } == "width" }
    let literal = argument?.children.last { $0.kind == "Numeric" }.map { raw.bytes($0.span) }
    let percent = literal.flatMap { $0.hasSuffix("%") ? Double($0.dropLast()) : nil }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    let width = percent.map { min(available,available*CGFloat($0)/100) } ?? min(available,natural.width)
    let scale = min(width/max(1,natural.width),4096/max(1,natural.height))
    return NSSize(width:max(1,natural.width*scale),height:max(1,natural.height*scale))
}
func imagePath(_ raw: String) -> String? {
    imageArguments(raw)?.children.first { $0.kind == "Str" }?.stringValue
}
private func imageArguments(_ raw: String) -> SyntaxNode? {
    func find(_ node: SyntaxNode) -> SyntaxNode? {
        if node.kind == "FuncCall", node.children.first.map({ raw.bytes($0.span) }) == "image" {
            return node.children.first { $0.kind == "Args" }
        }
        return node.children.lazy.compactMap(find).first
    }
    return find(ParsedSource.parse(raw).tree)
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
    let dpiX = props[kCGImagePropertyDPIWidth as String] as? Double ?? 72
    let dpiY = props[kCGImagePropertyDPIHeight as String] as? Double ?? 72
    return NSSize(width:width*72/max(1,dpiX),height:height*72/max(1,dpiY))
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
