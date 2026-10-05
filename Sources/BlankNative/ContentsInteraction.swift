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
    weak var source: ContentsRowView? { didSet { if let source { owner = source.session } } }
    private weak var owner: DocumentSession?
    weak var destination: ContentsRowView?
    var placement: SectionPlacement = .before
    var after: Bool { placement != .before }
    private let rows = NSHashTable<ContentsRowView>.weakObjects()
    weak var markerRow: ContentsRowView?
    var markerAfter = false
    var markerIndent: CGFloat = 0
    @Published var collapsed = Set<Int>()
    func register(_ row: ContentsRowView) { rows.add(row) }
    var revision = -1
    var path = ""
    func highlight(_ row: ContentsRowView?,placement: SectionPlacement = .before) {
        let old = destination, oldMarker = markerRow
        destination = row; self.placement = placement
        markerRow = row; markerAfter = placement != .before; markerIndent = 0
        if let row, case let .heading(target) = row.item, placement != .before,
           let session = row.session {
            let blocks = session.buffer.projection.blocks, level = blocks[target].level
            let end = blocks.dropFirst(target+1).first { $0.kind == "heading" && $0.level <= level }?.source.start ?? session.buffer.source.utf8.count
            // Put the marker below the last expanded descendant, even offscreen.
            markerRow = rows.allObjects.filter { candidate in
                guard candidate.window === row.window, !candidate.isHiddenOrHasHiddenAncestor,
                      !candidate.bounds.isEmpty, case let .heading(index) = candidate.item,
                      blocks.indices.contains(index) else { return false }
                return index >= target && blocks[index].source.start < end
            }.max { left,right in
                guard case let .heading(a) = left.item, case let .heading(b) = right.item else { return false }; return a < b
            } ?? row
            if placement == .inside, let source, case let .heading(from) = source.item,
               let markerRow, case let .heading(marker) = markerRow.item {
                markerIndent = CGFloat(max(0,blocks[from].level-blocks[marker].level))*12
            }
        }
        for view in [old,oldMarker,row,markerRow] { view?.needsDisplay = true }
    }
    func canMove(to row: ContentsRowView,after: Bool) -> Bool {
        canMove(to:row,placement:after ? .after : .before)
    }
    func canMove(to row: ContentsRowView,placement: SectionPlacement) -> Bool {
        guard let source, let session = row.session, !session.sidebarOrderLocked, source.session === session,
              path == session.active, revision == session.buffer.revision, source.item != row.item else { return false }
        switch (source.item,row.item) {
        case let (.heading(from),.heading(to)):
            return session.buffer.sectionMove(from,target:to,placement:placement) != nil
        case let (.chapter(from),.chapter(to)):
            guard from != session.entry, to != session.entry else { return false }
            return session.includes.contains { parent in
                let paths = session.buffers[parent]?.includes.compactMap { session.projectAssetPath($0.path,file:parent) } ?? []
                guard let a = paths.firstIndex(of:from), let b = paths.firstIndex(of:to), paths.filter({ $0 == from }).count == 1, paths.filter({ $0 == to }).count == 1 else { return false }
                return (placement != .before ? b+1 : b) != a && (placement != .before ? b+1 : b) != a+1
            }
        default: return false
        }
    }
    func remapCollapsed(blocks: [ProjectedBlock],span: ByteSpan,oldAt: Int,newStart: Int,delta: Int,openedParent: Int?,session: DocumentSession) {
        // Collapse follows source positions rather than titles (which may repeat).
        let insertion = oldAt >= span.end ? oldAt-span.count : oldAt
        let offsets = collapsed.subtracting(openedParent.map { [$0] } ?? []).compactMap { index -> Int? in
            guard blocks.indices.contains(index) else { return nil }
            let start = blocks[index].source.start
            if start >= span.start && start < span.end { return newStart+start-span.start }
            let removed = start >= span.end ? start-span.count : start
            return removed >= insertion ? removed+span.count+delta : removed
        }
        collapsed = Set(session.headings.filter { offsets.contains($0.1.source.start) }.map(\.0))
    }
    func finish() {
        owner?.sidebarDragging = false
        owner = nil; source = nil; highlight(nil); NSCursor.arrow.set()
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
        view.session = session; view.drag = drag; drag.register(view); view.item = item; view.activate = activate
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
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds,cursor:.arrow) }
    override func accessibilityPerformPress() -> Bool { activate(); return true }
    @objc func activateRow(_ sender: Any?) { activate() }
    override func mouseDown(with event: NSEvent) {
        guard session?.sidebarOrderLocked != true else { super.mouseDown(with:event); return }
        press = convert(event.locationInWindow,from:nil)
        // Track the whole native gesture here. Hosting an NSButton inside a
        // SwiftUI outline must not depend on SwiftUI forwarding drag events.
        while let next = window?.nextEvent(matching:[.leftMouseDragged,.leftMouseUp],until:.distantFuture,inMode:.eventTracking,dequeue:true) {
            if next.type == .leftMouseUp { mouseUp(with:next); return }
            mouseDragged(with:next)
            if press == nil { return }
        }
        press = nil
    }
    override func mouseUp(with event: NSEvent) {
        guard press != nil else { return }; press = nil
        NSCursor.arrow.set()
        if bounds.contains(convert(event.locationInWindow,from:nil)) { activate() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let press, let drag, let session, !session.sidebarOrderLocked else { return }
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
        NSCursor.closedHand.set()
        beginDraggingSession(with:[native],event:event,source:self).animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession,sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession,willBeginAt screenPoint: NSPoint) { NSCursor.closedHand.set() }
    func draggingSession(_ session: NSDraggingSession,movedTo screenPoint: NSPoint) { NSCursor.closedHand.set() }
    func draggingSession(_ session: NSDraggingSession,endedAt screenPoint: NSPoint,operation: NSDragOperation) { drag?.finish() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let event = NSApp.currentEvent { autoscroll(with:event) }
        guard let drag else { return [] }
        guard sender.draggingSource as? ContentsRowView === drag.source else { drag.highlight(nil); return [] }
        var placement: SectionPlacement = convert(sender.draggingLocation,from:nil).y >= bounds.midY ? .after : .before
        if let source = drag.source, let session, case let .heading(from) = source.item, case let .heading(to) = item,
           session.buffer.projection.blocks.indices.contains(from), session.buffer.projection.blocks.indices.contains(to),
           session.buffer.projection.blocks[from].level > session.buffer.projection.blocks[to].level { placement = .inside }
        guard drag.canMove(to:self,placement:placement) else { drag.highlight(nil); return [] }
        drag.highlight(self,placement:placement); NSCursor.closedHand.set(); return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { if drag?.destination === self { drag?.highlight(nil) } }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingUpdated(sender) == .move }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingUpdated(sender) == .move, let drag, let source = drag.source, let session else { return false }
        guard session.requestEditing() else { return false }
        let changed: Bool
        switch (source.item,item) {
        case let (.heading(from),.heading(to)):
            let blocks = session.buffer.projection.blocks
            let move = session.buffer.sectionMove(from,target:to,placement:drag.placement)
            let oldCount = session.buffer.source.utf8.count
            changed = session.buffer.moveSection(from,target:to,placement:drag.placement)
            if changed, let move {
                drag.remapCollapsed(blocks:blocks,span:move.span,oldAt:move.at,newStart:session.buffer.selection.anchor,delta:session.buffer.source.utf8.count-oldCount,openedParent:drag.placement == .inside ? to : nil,session:session)
                session.changed()
            }
        case let (.chapter(from),.chapter(to)): changed = session.moveChapter(from,before:to,after:drag.after)
        default: changed = false
        }
        drag.highlight(nil); return changed
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if drag?.destination === self && drag?.placement == .inside {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect:bounds,xRadius:4,yRadius:4).fill()
        }
        guard let drag, drag.markerRow === self else { return }
        NSColor.controlAccentColor.setFill()
        NSRect(x:drag.markerIndent,y:drag.markerAfter ? bounds.maxY-2 : bounds.minY,width:max(0,bounds.width-drag.markerIndent),height:2).fill()
    }
}

// One panel cursor owner routes overlapping tracking events to the visible
// row. The native arrow remains the navigation cursor until a drag starts.
struct ContentsCursorArea: NSViewRepresentable {
    var session: DocumentSession
    func makeNSView(context: Context) -> ContentsCursorView { ContentsCursorView() }
    func updateNSView(_ view: ContentsCursorView,context: Context) {
        view.session = session; session.contentsCursorView = view
        if let editor = session.editor { editor.window?.invalidateCursorRects(for:editor) }
    }
    static func dismantleNSView(_ view: ContentsCursorView,coordinator: ()) {
        if let session = view.session, session.contentsCursorView === view {
            session.contentsCursorView = nil
            if let editor = session.editor { editor.window?.invalidateCursorRects(for:editor) }
        }
    }
}
final class ContentsCursorView: NSView {
    weak var session: DocumentSession?
    private var tracking: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        if let editor = session?.editor { editor.window?.invalidateCursorRects(for:editor) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:.zero,options:[.cursorUpdate,.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(tracking!)
    }
    @discardableResult func updateCursor(for event: NSEvent) -> Bool {
        guard let window, !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(event.locationInWindow,from:nil)) else { return false }
        func control(in view: NSView) -> NSView? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            for child in view.subviews.reversed() { if let hit = control(in:child) { return hit } }
            if view is ContentsRowView,
               view.visibleRect.contains(view.convert(event.locationInWindow,from:nil)) { return view }
            return nil
        }
        if let root = window.contentView, let button = control(in:root) {
            if let row = button as? ContentsRowView {
                (row.drag?.source != nil ? NSCursor.closedHand : NSCursor.arrow).set()
            } else { NSCursor.arrow.set() }
        } else { NSCursor.arrow.set() }
        return true
    }
    override func cursorUpdate(with event: NSEvent) { updateCursor(for:event) }
    override func mouseEntered(with event: NSEvent) { updateCursor(for:event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(for:event) }
}
