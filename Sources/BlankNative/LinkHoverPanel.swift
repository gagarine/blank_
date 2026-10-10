import AppKit
import SwiftUI
import BlankCore

struct EditorLinkTarget: Equatable {
    let url: String
    let range: NSRange
    let source: ByteSpan
    let body: ByteSpan
    let path: String
    let revision: Int
}

struct LinkHoverContents: View {
    weak var editor: NativeTextView?
    let target: EditorLinkTarget
    var body: some View {
        VStack(alignment:.leading,spacing:2) {
            Text(target.url).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                .padding(.horizontal,10).frame(height:30).accessibilityLabel("Link URL: "+target.url)
            Divider()
            action("Open Link","arrow.up.right.square") { editor?.openHoveredLink(target) }
            action("Remove Link","link") { editor?.removeHoveredLink(target) }
        }.padding(6).frame(width:280).font(.system(size:12)).background(.background)
            .onHover { inside in
                if inside { editor?.linkDismissWork?.cancel() } else { editor?.scheduleLinkDismiss() }
            }
    }
    func action(_ title: String,_ symbol: String,perform: @escaping ()->Void) -> some View {
        SelectionButton(width:nil,action:perform) {
            Label(title,systemImage:symbol).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,10)
        }.accessibilityLabel(title)
    }
}

extension NativeTextView {
    func validLinkTarget(_ target: EditorLinkTarget) -> Bool {
        guard let session else { return false }
        return session.mode == .write && !session.contactSheet && session.sheet == nil &&
            session.active == target.path && session.buffer.revision == target.revision && !hasMarkedText()
    }
    func linkTarget(at point: NSPoint) -> EditorLinkTarget? {
        guard let session, session.mode == .write, visibleRect.contains(point), !session.contactSheet else { return nil }
        let offset = characterIndexForInsertion(at:point), projection = session.buffer.projection
        let block = projection.blocks[projection.blockIndex(at:offset)]
        var links: [EditorLinkTarget] = []
        func visit(_ nodes: [Inline],displayStart: Int,sourceDelta: Int = 0) {
            var at = displayStart
            for node in nodes {
                if case let .group(span,prefix,suffix,children) = node {
                    if prefix.hasPrefix("#link("), let url = node.runs.first?.style.link, node.length > 0 {
                        links.append(EditorLinkTarget(url:url,range:NSRange(location:at,length:node.length),
                            source:ByteSpan(span.start+sourceDelta,span.end+sourceDelta),
                            body:ByteSpan(span.start+sourceDelta+prefix.utf8.count,span.end+sourceDelta-suffix.utf8.count),
                            path:session.active,revision:session.buffer.revision))
                    }
                    visit(children,displayStart:at,sourceDelta:sourceDelta)
                }
                at += node.length
            }
        }
        if let cell = projection.tableCell(at:NSRange(location:offset,length:0)) {
            for part in block.cellProjections[cell.cell].blocks {
                visit(part.inlines,displayStart:cell.display.location+part.display.location,sourceDelta:cell.source.start)
            }
        } else if block.editable { visit(block.inlines,displayStart:block.display.location) }
        // Hit the actual glyph, not the rest of its line or inter-line padding.
        // Checking individual glyphs also permits wrapped links and their final half.
        return links.reversed().first { target in
            guard offset >= target.range.location && offset <= NSMaxRange(target.range) else { return false }
            let character = min(max(offset,target.range.location),NSMaxRange(target.range)-1)
            if documentGlyphRect(NSRange(location:character,length:1)).contains(point) { return true }
            return character > target.range.location && documentGlyphRect(NSRange(location:character-1,length:1)).contains(point)
        }
    }
    func updateLinkHover(at point: NSPoint,delay: TimeInterval = 0.35) {
        guard !selectingText, !draggingBlock, selectedRange().length == 0,
              selectionPanel?.isShown != true, slashPopover?.isShown != true, blockPopover?.isShown != true,
              let target = linkTarget(at:point), validLinkTarget(target) else { scheduleLinkDismiss(); return }
        linkDismissWork?.cancel()
        if hoveredLink == target && (linkPanel?.isShown == true || linkHoverWork?.isCancelled == false) { return }
        dismissLinkHover(); hoveredLink = target
        let anchor = min(max(characterIndexForInsertion(at:point),target.range.location),NSMaxRange(target.range)-1)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoveredLink == target, self.validLinkTarget(target), let window = self.window,
                  window.firstResponder === self, self.selectedRange().length == 0 else { return }
            let rect = self.documentGlyphRect(NSRange(location:anchor,length:1))
            guard self.visibleRect.intersects(rect) else { self.dismissLinkHover(); return }
            let panel = self.linkPanel ?? SelectionStylePanel(); self.linkPanel = panel
            panel.contentViewController = NSHostingController(rootView:LinkHoverContents(editor:self,target:target))
            panel.contentSize = NSSize(width:280,height:112)
            panel.show(relativeTo:rect,of:self,preferredEdge:.minY)
            window.makeFirstResponder(self)
        }
        linkHoverWork = work
        if delay == 0 { work.perform() } else { DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work) }
    }
    func scheduleLinkDismiss() {
        guard hoveredLink != nil, linkDismissWork == nil || linkDismissWork?.isCancelled == true else { return }
        linkHoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.linkDismissWork = nil
            if let panelWindow = self.linkPanel?.contentViewController?.view.window,
               self.linkPanel?.isShown == true, panelWindow.frame.contains(NSEvent.mouseLocation) { return }
            self.dismissLinkHover()
        }
        linkDismissWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:work)
    }
    func dismissLinkHover() {
        linkHoverWork?.cancel(); linkDismissWork?.cancel(); linkHoverWork = nil; linkDismissWork = nil
        hoveredLink = nil; linkPanel?.close()
    }
    func openHoveredLink(_ target: EditorLinkTarget) {
        guard validLinkTarget(target), let url = URL(string:target.url) else { return }
        dismissLinkHover(); NSWorkspace.shared.open(url)
    }
    func removeHoveredLink(_ target: EditorLinkTarget) {
        guard validLinkTarget(target), let session, session.requestEditing() else { return }
        captureSelection()
        let original = session.buffer.source, body = original.bytes(target.body), selection = session.buffer.selection
        let removed = target.source.count-target.body.count
        func mapped(_ point: Int) -> Int {
            if point <= target.source.start { return point }
            if point >= target.source.end { return point-removed }
            return target.source.start+min(max(0,point-target.body.start),target.body.count)
        }
        // Unwrap this exact source group, retaining its body, neighboring links,
        // comments, native selection and the shared source Undo/Redo history.
        dismissLinkHover()
        session.buffer.commit(original.replacingBytes(target.source,with:body),selection:EditSelection(mapped(selection.anchor),mapped(selection.focus)))
        session.changed(); clearInsertionStyle(); window?.makeFirstResponder(self)
    }
}
