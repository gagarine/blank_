import AppKit
import SwiftUI
import Combine

// AppKit supplies sidebar glass, resizing, safe areas and collapse animation.
// The sidebar opens only through navigation and search controls.
@MainActor final class DocumentSplitViewController: NSSplitViewController {
    let session: DocumentSession
    let contentsDrag = ContentsDrag()
    private(set) var contentsItem: NSSplitViewItem!
    private var subscriptions = Set<AnyCancellable>()
    private var collapseObservation: NSKeyValueObservation?
    private var synchronizing = false
    private var requestedCollapse = true
    private var activeTransitions = 0
    private var detailItem: NSSplitViewItem!
    private var accessory: NSSplitViewItemAccessoryViewController?

    init(session: DocumentSession) {
        self.session = session
        super.init(nibName:nil,bundle:nil)
        let contents = NSHostingController(rootView:DocumentSidebar(session:session,contentsDrag:contentsDrag))
        contents.sizingOptions = []
        contentsItem = NSSplitViewItem(sidebarWithViewController:contents)
        contentsItem.minimumThickness = 200; contentsItem.maximumThickness = 320
        contentsItem.preferredThicknessFraction = 0.22
        contentsItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        contentsItem.isCollapsed = !session.sidebar
        contentsItem.titlebarSeparatorStyle = .none
        let editor = NSHostingController(rootView:EditorRoot(session:session))
        editor.sizingOptions = []
        let detail = NSSplitViewItem(viewController:editor)
        detail.minimumThickness = 420
        detail.automaticallyAdjustsSafeAreaInsets = true
        detailItem = detail
        addSplitViewItem(contentsItem); addSplitViewItem(detail)
        session.$searchVisible.combineLatest(session.$contactSheet).sink { [weak self] search,contact in
            DispatchQueue.main.async { self?.updateAccessory(search:search,contact:contact) }
        }.store(in:&subscriptions)
        collapseObservation = contentsItem.observe(\.isCollapsed,options:[.new]) { [weak self] item,_ in
            MainActor.assumeIsolated {
                guard let self, !self.synchronizing, self.activeTransitions == 0, self.session.sidebar == item.isCollapsed else { return }
                self.session.sidebar = !item.isCollapsed
            }
        }
        session.$sidebar.removeDuplicates().sink { [weak self] shown in
            guard let self else { return }
            self.requestedCollapse = !shown
            if self.activeTransitions == 0 && self.contentsItem.isCollapsed == self.requestedCollapse { return }
            self.activeTransitions += 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
                self.contentsItem.animator().isCollapsed = self.requestedCollapse
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.activeTransitions -= 1
                    if self.activeTransitions == 0 {
                        self.synchronizing = true; self.contentsItem.isCollapsed = self.requestedCollapse
                        self.synchronizing = false
                    }
                }
            }
        }.store(in:&subscriptions)
    }
    override func splitView(_ splitView: NSSplitView,additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
        let native = super.splitView(splitView,additionalEffectiveRectOfDividerAt:dividerIndex)
        guard dividerIndex == 0, let target = sidebarResizeRect else { return native }
        // Extend AppKit's own divider target without drawing another divider
        // or replacing its drag tracking and sidebar size constraints.
        return native.isEmpty ? target : native.union(target)
    }
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        // Changing a pane's width doesn't change the split view's own frame.
        // Rebuild its native cursor/drag regions at the new divider position.
        splitView.window?.invalidateCursorRects(for:splitView)
    }
    private var sidebarResizeRect: NSRect? {
        guard splitView.isVertical, contentsItem?.isCollapsed == false,
              let sidebarPane = splitView.arrangedSubviews.first else { return nil }
        // AppKit can inset the hosted content inside its native pane. The
        // divider belongs to the outer pane, independently of that content.
        let pane = sidebarPane.frame
        guard pane.maxX > splitView.bounds.minX else { return nil }
        return NSRect(x:pane.maxX+splitView.dividerThickness/2-7,y:splitView.bounds.minY,width:14,height:splitView.bounds.height).intersection(splitView.bounds)
    }
    func updateResizeCursor(for event: NSEvent) -> Bool {
        guard activeTransitions == 0, event.window === splitView.window,
              let target = sidebarResizeRect, target.contains(splitView.convert(event.locationInWindow,from:nil)) else { return false }
        NSCursor.resizeLeftRight.set(); return true
    }
    private func updateAccessory(search: Bool,contact: Bool) {
        let height: CGFloat = contact ? 38 : (search ? 38 : 0)
        if height == 0 { detailItem.topAlignedAccessoryViewControllers = []; accessory = nil; return }
        if accessory == nil {
            let controller = NSSplitViewItemAccessoryViewController()
            controller.automaticallyAppliesContentInsets = false
            if #available(macOS 26.1, *) { controller.preferredScrollEdgeEffectStyle = .soft }
            controller.view = NSHostingView(rootView:DocumentAccessory(session:session))
            detailItem.addTopAlignedAccessoryViewController(controller); accessory = controller
        }
        accessory?.view.setFrameSize(NSSize(width:detailItem.viewController.view.bounds.width,height:height))
    }
    required init?(coder: NSCoder) { fatalError() }
}

struct DocumentAccessory: View {
    @ObservedObject var session: DocumentSession
    var body: some View {
        VStack(spacing:0) {
            if session.contactSheet {
                HStack {
                    Text(session.title).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Button("Done") { session.closeContactSheet() }
                }.font(.system(size:11)).controlSize(.small).padding(.horizontal,24).frame(height:38)
            } else {
                if session.searchVisible { EditorRoot(session:session).searchBar }
            }
        }.frame(maxWidth:.infinity)
    }
}
