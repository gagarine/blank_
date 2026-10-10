import SwiftUI
import AppKit
import PDFKit
import BlankCore

// The macOS 27 CLT SDK exposes a State macro without its plugin.
// Name the stable property-wrapper type explicitly.
typealias NativeState<Value> = SwiftUI.State<Value>

enum EditorLayout {
    static func textPadding(width: CGFloat,mode: EditorMode) -> CGFloat {
        mode == .source ? 30 : max(48,(width-720)/2)
    }
}

struct SlashCommand: Identifiable {
    var kind: String
    var level = 0
    var label: String
    var hint: String
    var symbol: String
    var keywords: String
    var insertion = false
    // Cell commands must round-trip through the cell projection and native
    // rendering. Structural document objects have no supported cell editor.
    var supportedInTableCell: Bool { ["paragraph","link","footnote","citation","label","reference"].contains(kind) }
    var systemSymbol: String {
        ["paragraph":"paragraphsign","heading":"textformat.size","bullet":"list.bullet","number":"list.number","quote":"quote.bubble","image":"photo","table":"tablecells","raw":"chevron.left.forwardslash.chevron.right","code":"chevron.left.forwardslash.chevron.right","citation":"books.vertical","footnote":"text.badge.plus","equation":"function","link":"link","label":"tag","reference":"arrow.turn.up.right"][kind] ?? "textformat"
    }
    var id: String { kind+String(level) }
    static var blockStyles: [SlashCommand] { Array(all.prefix(7)) + [SlashCommand(kind:"raw",label:"Code block",hint:"Displayed code example",symbol:"</>",keywords:"raw programming")] }
    static let all: [SlashCommand] = [
        .init(kind:"paragraph",label:"Paragraph",hint:"Plain text",symbol:"¶",keywords:"text"),
        .init(kind:"heading",level:1,label:"Heading 1",hint:"Chapter title",symbol:"H₁",keywords:"title h1"),
        .init(kind:"heading",level:2,label:"Heading 2",hint:"Section",symbol:"H₂",keywords:"subtitle h2"),
        .init(kind:"heading",level:3,label:"Heading 3",hint:"Subsection",symbol:"H₃",keywords:"subtitle h3"),
        .init(kind:"bullet",label:"Bulleted list",hint:"Unordered items",symbol:"•",keywords:"list"),
        .init(kind:"number",label:"Numbered list",hint:"Ordered items",symbol:"1.",keywords:"list"),
        .init(kind:"quote",label:"Quotation",hint:"Block quotation",symbol:"❝",keywords:"quote"),
        .init(kind:"raw",label:"Code block",hint:"Displayed code example",symbol:"</>",keywords:"raw programming"),
        .init(kind:"image",label:"Image and caption",hint:"Insert a figure",symbol:"▧",keywords:"picture photo media pdf svg",insertion:true),
        .init(kind:"table",label:"Table",hint:"Rows and columns",symbol:"▦",keywords:"grid",insertion:true),
        .init(kind:"code",label:"Code",hint:"Typst source",symbol:"</>",keywords:"source syntax programming",insertion:true),
        .init(kind:"citation",label:"Citation",hint:"Search Zotero",symbol:"@",keywords:"reference bibliography",insertion:true),
        .init(kind:"footnote",label:"Footnote",hint:"An explanatory note",symbol:"¹",keywords:"note",insertion:true),
        .init(kind:"equation",label:"Equation",hint:"Typst mathematics",symbol:"∑",keywords:"math formula",insertion:true),
        .init(kind:"link",label:"Link",hint:"Link to a web page",symbol:"↗",keywords:"url",insertion:true),
        .init(kind:"label",label:"Label",hint:"Name this position",symbol:"<>",keywords:"anchor",insertion:true),
        .init(kind:"reference",label:"Cross-reference",hint:"Refer to a label",symbol:"↪",keywords:"xref",insertion:true)
    ]
}
struct SlashMenu: View {
    var commands: [SlashCommand]
    var index: Int
    var choose: (Int)->Void
    static func contentWidth(_ commands: [SlashCommand]) -> CGFloat {
        let textWidth = commands.map { max(($0.label as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium)]).width, ($0.hint as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:10)]).width) }.max() ?? 140
        return ceil(textWidth+100)
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing:2) {
                    if commands.isEmpty { Text("No matching commands").foregroundStyle(.secondary).padding() }
                    ForEach(Array(commands.enumerated()),id:\.element.id) { i,command in
                        MenuRowButton(label:command.label+", "+command.hint,action:{ choose(i) }) {
                            HStack(spacing:12) {
                                Image(systemName:command.systemSymbol).font(.system(size:17)).frame(width:28)
                                VStack(alignment:.leading,spacing:3) { Text(command.label).font(.system(size:12,weight:.medium)).lineLimit(1); Text(command.hint).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer()
                            }.padding(.horizontal,10).padding(.vertical,7).frame(maxWidth:.infinity).frame(height:44).contentShape(Rectangle()).background(i == index ? Color.primary.opacity(0.07) : .clear).clipShape(RoundedRectangle(cornerRadius:5)).contentShape(.interaction,Rectangle())
                        }.id(i)
                    }
                }.padding(6)
            }.onAppear { proxy.scrollTo(index) }.onChange(of:index) { _,value in proxy.scrollTo(value) }
        }.background(.background).background(SlashMenuCursorArea().allowsHitTesting(false))
    }
}
// A native button supplies one rectangular target beneath the SwiftUI label.
// Decoration never participates in hit testing, including empty row space.
struct MenuRowButton<Content: View>: View {
    var label: String
    var height: CGFloat = 44
    var action: ()->Void
    var hover: (Bool)->Void = { _ in }
    @ViewBuilder var content: Content
    var body: some View {
        MenuButtonTarget(label:label,height:height,action:action,hover:hover)
            .frame(maxWidth:.infinity)
            .overlay { content.allowsHitTesting(false).accessibilityHidden(true) }
            .frame(height:height)
    }
}
struct MenuButtonTarget: NSViewRepresentable {
    var label: String
    var height: CGFloat
    var action: ()->Void
    var hover: (Bool)->Void = { _ in }
    func makeNSView(context: Context) -> MenuActionButton {
        let button = MenuActionButton()
        button.title = ""; button.isBordered = false; button.isTransparent = true
        button.target = button; button.action = #selector(MenuActionButton.activate(_:))
        return button
    }
    func sizeThatFits(_ proposal: ProposedViewSize,nsView: MenuActionButton,context: Context) -> CGSize? {
        CGSize(width:proposal.width ?? 200,height:height)
    }
    func updateNSView(_ button: MenuActionButton,context: Context) {
        button.setAccessibilityLabel(label); button.perform = action; button.hover = hover
    }
}
final class MenuActionButton: NSButton {
    var perform: ()->Void = {}
    var hover: (Bool)->Void = { _ in }
    private var hoverTracking: NSTrackingArea?
    private(set) var isHovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.mouseMoved,.activeInActiveApp,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseMoved(with event: NSEvent) { if isEnabled { isHovered = true; hover(true) } }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    private func setHovered(_ value: Bool) {
        let value = value && isEnabled
        guard value != isHovered else { return }
        isHovered = value; hover(value)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds,cursor:.arrow)
    }
    @objc func activate(_ sender: Any?) { perform() }
}
// The editor stays first responder for slash filtering. Track the popover
// throughout the active app, including its padding and empty-results area.
struct SlashMenuCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> SlashMenuCursorView { SlashMenuCursorView() }
    func updateNSView(_ view: SlashMenuCursorView,context: Context) {}
}
final class SlashMenuCursorView: NSView {
    private var cursorTracking: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect:.zero,options:[.cursorUpdate,.mouseEnteredAndExited,.mouseMoved,.activeInActiveApp,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); cursorTracking = area
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds,cursor:.arrow)
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
}
struct EditorRoot: View {
    @ObservedObject var session: DocumentSession
    @NativeState private var searchAfterSheet = false
    var body: some View {
        VStack(spacing:0) {
            ZStack {
                Group {
                    if session.mode == .preview { PreviewView(session:session) }
                    else { NativeEditor(session:session) }
                }.opacity(session.contactSheet ? 0 : 1).allowsHitTesting(!session.contactSheet).accessibilityHidden(session.contactSheet)
                if session.contactSheet { ContactSheetView(session:session,thumbnails:session.thumbnails) }
            }.frame(maxWidth:.infinity,maxHeight:.infinity).ignoresSafeArea(.container,edges:.top)
            if let error = session.error {
                HStack(alignment:.top) {
                    Image(systemName:"exclamationmark.circle").foregroundStyle(.secondary)
                    Text(error).font(.system(size:11)).textSelection(.enabled).lineLimit(4)
                    Spacer()
                    Button { session.error = nil } label: { Image(systemName:"xmark").font(.system(size:10)) }.buttonStyle(.plain)
                }.padding(12).background(Color.orange.opacity(0.04))
            }
        }.frame(minWidth:420,minHeight:420).ignoresSafeArea(.container,edges:.top).preferredColorScheme(session.dark ? .dark : nil)
        .sheet(item:$session.sheet,onDismiss:{
            if searchAfterSheet { searchAfterSheet = false; focusSearch() }
            let action = session.pendingDocumentAction; session.pendingDocumentAction = nil; action?()
        }) { sheet in
            switch sheet {
            case .commands: CommandsSheet(session:session)
            case .settings: SettingsSheet(session:session)
            case .statistics: StatisticsSheet(session:session)
            case .insertion: InsertionSheet(session:session)
            case .bibliographyConversion: BibliographyConversionSheet(session:session)
            case .object: ObjectSheet(session:session)
            case .conflict: ConflictSheet(session:session)
            case .page: GoToPageSheet(session:session)
            }
        }
        .onChange(of:session.searchFocusRequest) { _,_ in
            // Repeated Cmd-F re-enters the existing field rather than editing
            // the document. Defer until the search options have been laid out.
            if session.window?.attachedSheet != nil { searchAfterSheet = true }
            else { focusSearch() }
        }
        .onChange(of:session.dark) { _,dark in session.window?.appearance = dark ? NSAppearance(named:.darkAqua) : nil }
    }
    private func focusSearch() {
        DispatchQueue.main.async { (session.window?.windowController as? DocumentWindow)?.focusNativeSearch() }
    }
    var searchBar: some View {
        HStack(spacing:8) {
            Button { session.find(next:false) } label: { Image(systemName:"chevron.up") }.help("Previous match").accessibilityLabel("Previous match")
            Button { session.find() } label: { Image(systemName:"chevron.down") }.help("Next match").accessibilityLabel("Next match")
            Toggle("Aa",isOn:$session.caseSensitive).toggleStyle(.button).help("Match case")
            if session.mode != .preview {
                Toggle("Project",isOn:$session.projectSearch).toggleStyle(.button).help("Search included files")
                Divider().frame(height:18)
                TextField("Replace",text:$session.replaceText).onExitCommand { session.hideSearch() }.frame(maxWidth:170)
                Button("Replace") { session.replace() }; Button("All") { session.replace(all:true) }
            }
            Spacer()
            SearchStatus(search:session.searchController)
            Button { session.hideSearch() } label: { Image(systemName:"xmark").frame(width:24,height:24).contentShape(Rectangle()) }.buttonStyle(.plain).help("Close search · Esc").accessibilityLabel("Close search")
        }.font(.system(size:11)).controlSize(.small).padding(.horizontal,24).padding(.vertical,9)
    }
}
struct ContentsView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var contentsDrag: ContentsDrag
    var body: some View { contents.onChange(of:session.active) { _,_ in contentsDrag.collapsed.removeAll() } }
    var visibleHeadings: [(Int,ProjectedBlock)] {
        var hiddenLevel: Int?
        let headings = session.headings
        return headings.filter { index,b in
            if let level = hiddenLevel { if b.level > level { return false }; hiddenLevel = nil }
            if contentsDrag.collapsed.contains(index) { hiddenLevel = b.level }
            return true
        }
    }
    var contents: some View {
        VStack(alignment:.leading,spacing:0) {
            ScrollView {
                VStack(alignment:.leading,spacing:3) {
                    if session.includes.count > 1 {
                        ForEach(session.includes,id:\.self) { path in
                            HStack(spacing:5) {
                                Image(systemName:"doc.text").font(.system(size:11)).foregroundStyle(.secondary).allowsHitTesting(false)
                                ContentsRow(session:session,drag:contentsDrag,item:.chapter(path),title:path,selected:session.active == path,activate:{ session.switchFile(path) })
                            }.frame(height:28)
                        }
                        Divider().padding(.vertical,12)
                    }
                    ForEach(visibleHeadings,id:\.0) { index,b in
                        HStack(spacing:5) {
                            let hasChildren = session.headings.contains { $0.0 > index && $0.1.level > b.level && $0.0 < (session.headings.first { $0.0 > index && $0.1.level <= b.level }?.0 ?? Int.max) }
                            Button { if contentsDrag.collapsed.contains(index) { contentsDrag.collapsed.remove(index) } else { contentsDrag.collapsed.insert(index) } } label: { Image(systemName:contentsDrag.collapsed.contains(index) ? "chevron.right" : "chevron.down").font(.system(size:8)).opacity(hasChildren ? 0.6 : 0).frame(width:20,height:28).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(!hasChildren).accessibilityLabel((contentsDrag.collapsed.contains(index) ? "Expand " : "Collapse ")+b.text).accessibilityHidden(!hasChildren)
                            ContentsRow(session:session,drag:contentsDrag,item:.heading(index),title:b.text,activate:{ session.navigateToSource(path:session.active,selection:EditSelection(b.body.start,b.body.start)) })
                        }.padding(.leading,CGFloat(max(0,b.level-1))*12).frame(height:28)
                    }
                }.padding(.horizontal,16).padding(.top,16)
            }
            Spacer(minLength:0)
        }
    }
}
struct PreviewView: NSViewRepresentable {
    @ObservedObject var session: DocumentSession
    func makeNSView(context: Context) -> PDFView {
        let view = NavigablePDFView(); view.session = session; session.pdfView = view
        view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor; view.displaysPageBreaks = true; view.pageBreakMargins = NSEdgeInsets(top:16,left:16,bottom:16,right:16)
        view.document = session.pdf
        view.isHidden = session.contactSheet
        view.displayMode = session.previewDisplayMode.pdfMode
        DispatchQueue.main.async { session.previewViewReady += 1; session.searchController.applyHighlights() }
        return view
    }
    func updateNSView(_ view: PDFView,context: Context) {
        view.isHidden = session.contactSheet
        view.displayMode = session.previewDisplayMode.pdfMode
        if view.document !== session.pdf {
            view.document = session.pdf
            if let anchor = session.sourceMap.first(where: { ($0["path"] as? String) == session.active && ($0["end"] as? Int ?? 0) >= session.buffer.selection.focus }), let page = anchor["page"] as? Int, let pdfPage = session.pdf?.page(at:max(0,page-1)) { view.go(to:pdfPage) }
        }
    }
}
final class NavigablePDFView: PDFView {
    weak var session: DocumentSession?
    override init(frame: NSRect) {
        super.init(frame:frame)
        observePageChanges()
    }
    required init?(coder: NSCoder) {
        super.init(coder:coder)
        observePageChanges()
    }
    private func observePageChanges() {
        NotificationCenter.default.addObserver(self,selector:#selector(pageChanged),name:.PDFViewPageChanged,object:self)
    }
    @objc private func pageChanged(_ notification: Notification) {
        guard let session, let page = currentPage, let document else { return }
        let number = document.index(for:page)+1
        if session.previewPage != number { session.previewPage = number }
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with:event)
        let location = convert(event.locationInWindow,from:nil)
        guard let session, let page = page(for:location,nearest:true), let document else { return }
        let point = convert(location,to:page)
        let height = page.bounds(for:.mediaBox).height
        let pageNumber = document.index(for:page)+1
        if let nearest = session.sourceMap.filter({ ($0["page"] as? Int) == pageNumber }).min(by: {
            abs(($0["y"] as? Double ?? 0)-(height-point.y)/height) < abs(($1["y"] as? Double ?? 0)-(height-point.y)/height)
        }), let path = nearest["path"] as? String, let byte = nearest["start"] as? Int, let buffer = session.buffers[path] {
            session.active = path; buffer.selection = EditSelection(byte,byte)
        }
    }
}
