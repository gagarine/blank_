import AppKit
import PDFKit
import BlankCore

enum GoAction { case up, down, previousItem, nextItem, page, back, forward }

struct SourceDestination: Equatable {
    let path: String
    let selection: EditSelection
    let revision: Int
}

@MainActor extension DocumentSession {
    var canGoToPage: Bool { mode == .preview && (pdf?.pageCount ?? 0) > 1 && pdfView?.document === pdf }

    func canNavigate(_ action: GoAction) -> Bool {
        guard window?.attachedSheet == nil, sheet == nil, !contactSheet else { return false }
        switch action {
        case .page: return canGoToPage
        case .up, .down:
            guard let scroll = navigationScrollView, let document = scroll.documentView else { return false }
            let visible = scroll.documentVisibleRect
            let towardMinimum = (action == .up) == document.isFlipped
            return towardMinimum ? visible.minY > document.bounds.minY+1 : visible.maxY < document.bounds.maxY-1
        case .previousItem, .nextItem:
            if mode == .preview { return action == .previousItem ? pdfView?.canGoToPreviousPage == true : pdfView?.canGoToNextPage == true }
            return adjacentHeading(next:action == .nextItem) != nil
        case .back: return mode == .preview ? pdfView?.canGoBack == true : navigationBack.last.map(validDestination) == true
        case .forward: return mode == .preview ? pdfView?.canGoForward == true : navigationForward.last.map(validDestination) == true
        }
    }

    func navigate(_ action: GoAction) {
        // Committing marked text may change the source and clear its history.
        // Validate afterward, before attempting to pop an old destination.
        if mode != .preview && action != .up && action != .down { editor?.finishComposition() }
        guard canNavigate(action) else { return }
        switch action {
        case .up, .down:
            guard let scroll = navigationScrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            var target = clip.bounds
            let direction: CGFloat = ((action == .up) == document.isFlipped) ? -1 : 1
            target.origin.y += direction * max(1,target.height-40)
            clip.scroll(to:clip.constrainBoundsRect(target).origin); scroll.reflectScrolledClipView(clip)
        case .previousItem, .nextItem:
            if mode == .preview {
                if action == .nextItem { pdfView?.goToNextPage(nil) } else { pdfView?.goToPreviousPage(nil) }
            } else if let heading = adjacentHeading(next:action == .nextItem) { navigateToSource(path:active,selection:EditSelection(heading.body.start,heading.body.start)) }
        case .page: editor?.finishComposition(); sheet = .page
        case .back, .forward:
            if mode == .preview {
                if action == .back { pdfView?.goBack(nil) } else { pdfView?.goForward(nil) }
            } else {
                synchronizeSelection()
                let here = sourceDestination
                let target = action == .back ? navigationBack.removeLast() : navigationForward.removeLast()
                if action == .back { navigationForward.append(here) } else { navigationBack.append(here) }
                restoreDestination(target)
            }
        }
    }

    // Explicit section jumps form a bounded navigation history, separate from
    // source undo. Revision checks discard obsolete source positions after edits.
    func navigateToSource(path: String,selection: EditSelection) {
        guard let target = buffers[path] else { return }
        editor?.finishComposition()
        if mode == .preview { capturePreviewPosition() } else { synchronizeSelection() }
        let here = sourceDestination
        let destination = SourceDestination(path:path,selection:selection,revision:target.revision)
        guard here != destination || mode == .preview else { return }
        if here != destination {
            navigationBack.append(here)
            if navigationBack.count > 100 { navigationBack.removeFirst() }
            navigationForward.removeAll()
        }
        restoreDestination(destination)
    }
    private var sourceDestination: SourceDestination { SourceDestination(path:active,selection:buffer.selection,revision:buffer.revision) }
    private func validDestination(_ target: SourceDestination) -> Bool { buffers[target.path]?.revision == target.revision }
    private func restoreDestination(_ target: SourceDestination) {
        guard validDestination(target) else { return }
        if mode == .preview { switchMode(.write) }
        buffer.breakUndoGroup()
        let changedFile = active != target.path
        active = target.path; buffer.selection = target.selection
        if changedFile { searchController.update(revealFirst:false) }
        editor?.refresh(reveal:true); window?.makeFirstResponder(editor)
    }
    private func adjacentHeading(next: Bool) -> ProjectedBlock? {
        guard let editor else { return nil }
        let selected = editor.selectedRange().location
        let byte = mode == .source ? editor.string.byteOffset(utf16:selected) : buffer.projection.sourceOffset(at:selected)
        // Treat the heading's marker and body as the same destination.
        let current = headings.last { $0.1.source.start <= byte }
        if next { return headings.first { $0.1.source.start > byte }?.1 }
        if let current, byte > current.1.body.start { return current.1 }
        return headings.last { $0.1.source.start < (current?.1.source.start ?? byte) }?.1
    }
    private var navigationScrollView: NSScrollView? {
        if mode != .preview { return editor?.enclosingScrollView }
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return pdfView.flatMap(find)
    }
}
