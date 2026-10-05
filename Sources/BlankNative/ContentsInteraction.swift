import AppKit
import SwiftUI
import BlankCore

enum ContentsItem: Equatable {
    case heading(Int)
    case chapter(String)
}

// One local drag owner keeps the insertion line unique and rejects foreign
// payloads or a document that changed while a drag was in progress.
@MainActor final class ContentsDrag: ObservableObject {
    weak var source: ContentsRowView?
    weak var destination: ContentsRowView?
    var after = false
    var revision = -1
    var path = ""
    func highlight(_ row: ContentsRowView?,after: Bool = false) {
        let old = destination; destination = row; self.after = after
        old?.needsDisplay = true; row?.needsDisplay = true
    }
    func canMove(to row: ContentsRowView,after: Bool) -> Bool {
        guard let source, let session = row.session, source.session === session,
              path == session.active, revision == session.buffer.revision, source.item != row.item else { return false }
        switch (source.item,row.item) {
        case let (.heading(from),.heading(to)):
            let blocks = session.buffer.projection.blocks
            guard blocks.indices.contains(from), blocks.indices.contains(to), blocks[from].level == blocks[to].level else { return false }
            let end = blocks.dropFirst(from+1).first { $0.kind == "heading" && $0.level <= blocks[from].level }?.source.start ?? session.buffer.source.utf8.count
            let at = after ? blocks.dropFirst(to+1).first { $0.kind == "heading" && $0.level <= blocks[to].level }?.source.start ?? session.buffer.source.utf8.count : blocks[to].source.start
            return at < blocks[from].source.start || at > end
        case let (.chapter(from),.chapter(to)):
            guard from != session.entry, to != session.entry else { return false }
            return session.includes.contains { parent in
                let paths = session.buffers[parent]?.includes.compactMap { session.projectAssetPath($0.path,file:parent) } ?? []
                guard let a = paths.firstIndex(of:from), let b = paths.firstIndex(of:to), paths.filter({ $0 == from }).count == 1, paths.filter({ $0 == to }).count == 1 else { return false }
                return (after ? b+1 : b) != a && (after ? b+1 : b) != a+1
            }
        default: return false
        }
    }
    func finish() {
        source?.session?.sidebarDragging = false
        source = nil; highlight(nil); NSCursor.arrow.set()
    }
}

struct ContentsRow: NSViewRepresentable {
    var session: DocumentSession
    var drag: ContentsDrag
    var item: ContentsItem
    var title: String
    var selected = false
    var activate: ()->Void
    func makeNSView(context: Context) -> ContentsRowView { ContentsRowView() }
    func sizeThatFits(_ proposal: ProposedViewSize,nsView: ContentsRowView,context: Context) -> CGSize? {
        CGSize(width:proposal.width ?? 180,height:28)
    }
    func updateNSView(_ view: ContentsRowView,context: Context) {
        view.session = session; view.drag = drag; view.item = item; view.activate = activate
        view.label.stringValue = title; view.label.textColor = selected ? .labelColor : .secondaryLabelColor
        view.label.lineBreakMode = if case .chapter = item { .byTruncatingMiddle } else { .byTruncatingTail }
        view.setAccessibilityLabel(title)
    }
}

final class ContentsRowView: NSButton, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("local.blank.contents-move")
    weak var session: DocumentSession?
    var drag: ContentsDrag?
    var item = ContentsItem.heading(0)
    var activate: ()->Void = {}
    let label = NSTextField(labelWithString:"")
    var press: NSPoint?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame:frame)
        title = ""; isBordered = false; isTransparent = true
        target = self; action = #selector(activateRow(_:))
        label.font = .systemFont(ofSize:11); label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1; label.setAccessibilityElement(false)
        addSubview(label); registerForDraggedTypes([Self.pasteboardType])
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout(); label.frame = NSRect(x:0,y:(bounds.height-16)/2,width:bounds.width,height:16)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point,from:superview)) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds,cursor:.openHand) }
    override func accessibilityPerformPress() -> Bool { activate(); return true }
    @objc func activateRow(_ sender: Any?) { activate() }
    override func mouseDown(with event: NSEvent) { press = convert(event.locationInWindow,from:nil); NSCursor.closedHand.set() }
    override func mouseUp(with event: NSEvent) {
        guard press != nil else { return }; press = nil
        NSCursor.openHand.set()
        if bounds.contains(convert(event.locationInWindow,from:nil)) { activate() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let press, let drag, let session else { return }
        let point = convert(event.locationInWindow,from:nil)
        guard hypot(point.x-press.x,point.y-press.y) >= 4 else { return }
        self.press = nil; session.editor?.finishComposition()
        drag.source = self; drag.path = session.active; drag.revision = session.buffer.revision
        session.sidebarDragging = true
        let writer = NSPasteboardItem(); writer.setString("move",forType:Self.pasteboardType)
        let native = NSDraggingItem(pasteboardWriter:writer)
        let image = NSImage(size:bounds.size)
        image.lockFocus(); label.attributedStringValue.draw(at:NSPoint(x:0,y:(bounds.height-16)/2)); image.unlockFocus()
        native.setDraggingFrame(bounds,contents:image)
        beginDraggingSession(with:[native],event:event,source:self).animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession,sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession,willBeginAt screenPoint: NSPoint) { NSCursor.closedHand.set() }
    func draggingSession(_ session: NSDraggingSession,movedTo screenPoint: NSPoint) { NSCursor.closedHand.set() }
    func draggingSession(_ session: NSDraggingSession,endedAt screenPoint: NSPoint,operation: NSDragOperation) { drag?.finish() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let drag, sender.draggingSource as? ContentsRowView === drag.source else { return [] }
        let after = convert(sender.draggingLocation,from:nil).y >= bounds.midY
        guard drag.canMove(to:self,after:after) else { drag.highlight(nil); return [] }
        drag.highlight(self,after:after); NSCursor.closedHand.set(); return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { if drag?.destination === self { drag?.highlight(nil) } }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingUpdated(sender) == .move }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingUpdated(sender) == .move, let drag, let source = drag.source, let session else { return false }
        let changed: Bool
        switch (source.item,item) {
        case let (.heading(from),.heading(to)):
            changed = drag.after ? session.buffer.moveSection(from,after:to) : session.buffer.moveSection(from,before:to)
            if changed { session.changed() }
        case let (.chapter(from),.chapter(to)): changed = session.moveChapter(from,before:to,after:drag.after)
        default: changed = false
        }
        drag.highlight(nil); return changed
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard drag?.destination === self else { return }
        NSColor.controlAccentColor.setFill()
        NSRect(x:0,y:drag?.after == true ? bounds.maxY-2 : bounds.minY,width:bounds.width,height:2).fill()
    }
}

struct ContentsPin: NSViewRepresentable {
    var pinned: Bool
    var toggle: ()->Void
    func makeNSView(context: Context) -> ContentsPinButton {
        let button = ContentsPinButton(); button.isBordered = false; button.title = ""; button.imagePosition = .imageOnly
        button.target = button; button.action = #selector(ContentsPinButton.activate(_:)); return button
    }
    func updateNSView(_ button: ContentsPinButton,context: Context) {
        button.image = NSImage(systemSymbolName:pinned ? "pin.fill" : "pin",accessibilityDescription:nil)
        button.setAccessibilityLabel(pinned ? "Unpin Contents" : "Pin Contents")
        button.toolTip = (pinned ? "Unpin" : "Pin")+" Contents · ⌘⇧L"; button.perform = toggle
    }
}
final class ContentsPinButton: NSButton {
    var perform: ()->Void = {}
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds,cursor:.pointingHand) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc func activate(_ sender: Any?) { perform() }
}
struct ContentsCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> ContentsCursorView { ContentsCursorView() }
    func updateNSView(_ view: ContentsCursorView,context: Context) {}
}
final class ContentsCursorView: NSView {
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds,cursor:.arrow) }
}
