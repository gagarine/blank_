import AppKit
import SwiftUI
import Combine

// AppKit supplies sidebar glass, resizing, safe areas and collapse animation.
// Both the persistent sidebar and transient hover outline share drag state.
@MainActor final class DocumentSplitViewController: NSSplitViewController {
    let session: DocumentSession
    let contentsDrag = ContentsDrag()
    private(set) var contentsItem: NSSplitViewItem!
    private var subscriptions = Set<AnyCancellable>()
    private var collapseObservation: NSKeyValueObservation?
    private var synchronizing = false

    init(session: DocumentSession) {
        self.session = session
        super.init(nibName:nil,bundle:nil)
        let contents = NSHostingController(rootView:ContentsView(session:session,contentsDrag:contentsDrag))
        contents.sizingOptions = []
        contentsItem = NSSplitViewItem(sidebarWithViewController:contents)
        contentsItem.minimumThickness = 200; contentsItem.maximumThickness = 320
        contentsItem.preferredThicknessFraction = 0.22
        contentsItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        contentsItem.isCollapsed = !session.sidebar
        contentsItem.titlebarSeparatorStyle = .none
        let editor = NSHostingController(rootView:EditorRoot(session:session,contentsDrag:contentsDrag))
        editor.sizingOptions = []
        let detail = NSSplitViewItem(viewController:editor)
        detail.minimumThickness = 420
        addSplitViewItem(contentsItem); addSplitViewItem(detail)
        collapseObservation = contentsItem.observe(\.isCollapsed,options:[.new]) { [weak self] item,_ in
            MainActor.assumeIsolated {
                guard let self, !self.synchronizing, self.session.sidebar == item.isCollapsed else { return }
                self.session.sidebarHover = false; self.session.sidebar = !item.isCollapsed
            }
        }
        session.$sidebar.removeDuplicates().sink { [weak self] shown in
            guard let self, self.contentsItem.isCollapsed == shown else { return }
            self.synchronizing = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
                self.contentsItem.animator().isCollapsed = !shown
            }
            self.synchronizing = false
        }.store(in:&subscriptions)
    }
    required init?(coder: NSCoder) { fatalError() }
}
