import SwiftUI
import AppKit
import PDFKit
import BlankCore

// The macOS 27 CLT SDK exposes a State macro without its plugin.
// Name the stable property-wrapper type explicitly; supports macOS 14+.
typealias NativeState<Value> = SwiftUI.State<Value>

struct SlashCommand: Identifiable {
    var kind: String
    var level = 0
    var label: String
    var hint: String
    var symbol: String
    var keywords: String
    var insertion = false
    var id: String { kind+String(level) }
    static let all: [SlashCommand] = [
        .init(kind:"paragraph",label:"Paragraph",hint:"Plain text",symbol:"¶",keywords:"text"),
        .init(kind:"heading",level:1,label:"Heading 1",hint:"Chapter title",symbol:"H₁",keywords:"title h1"),
        .init(kind:"heading",level:2,label:"Heading 2",hint:"Section",symbol:"H₂",keywords:"subtitle h2"),
        .init(kind:"heading",level:3,label:"Heading 3",hint:"Subsection",symbol:"H₃",keywords:"subtitle h3"),
        .init(kind:"bullet",label:"Bulleted list",hint:"Unordered items",symbol:"•",keywords:"list"),
        .init(kind:"number",label:"Numbered list",hint:"Ordered items",symbol:"1.",keywords:"list"),
        .init(kind:"quote",label:"Quotation",hint:"Block quotation",symbol:"❝",keywords:"quote"),
        .init(kind:"image",label:"Image and caption",hint:"Insert a figure",symbol:"▧",keywords:"picture photo media pdf svg",insertion:true),
        .init(kind:"table",label:"Table",hint:"Rows and columns",symbol:"▦",keywords:"grid",insertion:true),
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
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing:2) {
                    if commands.isEmpty { Text("No matching commands").foregroundStyle(.secondary).padding() }
                    ForEach(Array(commands.enumerated()),id:\.element.id) { i,command in
                        Button { choose(i) } label: {
                            HStack(spacing:12) {
                                Text(command.symbol).font(.system(size:18,design:.serif)).frame(width:28)
                                VStack(alignment:.leading,spacing:3) { Text(command.label).font(.system(size:12,weight:.medium)); Text(command.hint).font(.system(size:10)).foregroundStyle(.secondary) }
                                Spacer()
                            }.padding(.horizontal,10).padding(.vertical,7).frame(height:44).background(i == index ? Color.primary.opacity(0.07) : .clear).clipShape(RoundedRectangle(cornerRadius:5))
                        }.buttonStyle(.plain).id(i)
                    }
                }.padding(6)
            }.onChange(of:index) { _,value in proxy.scrollTo(value) }
        }.frame(width:280).background(.background)
    }
}
struct EditorRoot: View {
    @ObservedObject var session: DocumentSession
    @NativeState private var collapsed = Set<Int>()
    @NativeState private var draggingHeading: Int?
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:16) {
                Text("blank_").font(.system(size:24,weight:.semibold,design:.serif)).tracking(-1.3)
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width:1,height:15)
                Text(session.title).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth:.infinity,alignment:.leading)
                HStack(spacing:2) {
                    ForEach(EditorMode.allCases,id:\.self) { mode in
                        Button { session.switchMode(mode) } label: { Text(mode.rawValue).font(.system(size:11,weight:session.mode == mode ? .medium : .regular)).padding(.horizontal,14).padding(.vertical,7).background(session.mode == mode ? Color.white : .clear).clipShape(RoundedRectangle(cornerRadius:5)) }.buttonStyle(.plain)
                    }
                }.padding(3).background(Color.black.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(Color.black.opacity(0.10),lineWidth:0.5))
                Spacer().frame(width:16)
                Button { session.exportPDF() } label: { Image(systemName:"square.and.arrow.up").font(.system(size:13)) }.buttonStyle(.plain).help("Export PDF")
            }.padding(.horizontal,26).frame(height:62).background(Color.white)
            Divider().opacity(0.6)
            if session.searchVisible { searchBar }
            HStack(spacing:0) {
                if session.sidebar { contents.frame(width:235); Divider() }
                ZStack(alignment:.leading) {
                    if session.mode == .preview { PreviewView(session:session) }
                    else { NativeEditor(session:session) }
                    if !session.sidebar {
                        Color.clear.frame(width:18).contentShape(Rectangle()).onHover { session.sidebarHover = $0 }
                        if session.sidebarHover && !session.headings.isEmpty {
                            contents.frame(width:235).background(Color.white).shadow(color:.black.opacity(0.07),radius:12,x:4).onHover { session.sidebarHover = $0 }.transition(.opacity)
                        }
                    }
                }
            }
            if let error = session.error {
                HStack(alignment:.top) {
                    Image(systemName:"exclamationmark.circle").foregroundStyle(.secondary)
                    Text(error).font(.system(size:11)).textSelection(.enabled).lineLimit(4)
                    Spacer()
                    Button { session.error = nil } label: { Image(systemName:"xmark").font(.system(size:10)) }.buttonStyle(.plain)
                }.padding(12).background(Color.orange.opacity(0.04))
            }
            Divider().opacity(0.5)
            HStack {
                Text(session.root == nil ? "Unsaved document" : session.dirty ? "Saving…" : "Saved").font(.system(size:10)).foregroundStyle(.tertiary)
                Spacer()
                Button { session.sheet = .statistics } label: { Text("\(wordCount) words").font(.system(size:10)).foregroundStyle(.secondary) }.buttonStyle(.plain)
                Text("⌘K").font(.system(size:10)).foregroundStyle(.tertiary).padding(.leading,18)
            }.padding(.horizontal,26).frame(height:30).background(Color.white)
        }.frame(minWidth:660,minHeight:420).background(Color.white).preferredColorScheme(.light)
        .sheet(item:$session.sheet) { sheet in
            switch sheet {
            case .commands: CommandsSheet(session:session)
            case .settings: SettingsSheet(session:session)
            case .statistics: StatisticsSheet(session:session)
            case .insertion: InsertionSheet(session:session)
            case .object: ObjectSheet(session:session)
            case .conflict: ConflictSheet(session:session)
            }
        }
    }
    var wordCount: Int { session.buffer.projection.text.split { $0.isWhitespace || $0.isNewline }.count }
    var searchBar: some View {
        HStack(spacing:8) {
            Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
            TextField("Find",text:$session.searchQuery).onSubmit { session.find() }.frame(maxWidth:180)
            Button { session.find(next:false) } label: { Image(systemName:"chevron.up") }
            Button { session.find() } label: { Image(systemName:"chevron.down") }
            Toggle("Aa",isOn:$session.caseSensitive).toggleStyle(.button).help("Match case")
            Divider().frame(height:18)
            TextField("Replace",text:$session.replaceText).frame(maxWidth:170)
            Button("Replace") { session.replace() }; Button("All") { session.replace(all:true) }
            Spacer()
            Button { session.searchVisible = false; session.window?.makeFirstResponder(session.editor) } label: { Image(systemName:"xmark") }
        }.font(.system(size:11)).controlSize(.small).padding(.horizontal,24).padding(.vertical,9).background(Color.white)
    }
    var visibleHeadings: [(Int,ProjectedBlock)] {
        var hiddenLevel: Int?
        let headings = session.headings
        // Omit a single document-title wrapper, matching Go's outline.
        let omitTitle = headings.filter { $0.1.level == 1 }.count == 1 && headings.count > 1
        return headings.filter { index,b in
            if omitTitle && b.level == 1 { return false }
            if let level = hiddenLevel { if b.level > level { return false }; hiddenLevel = nil }
            if collapsed.contains(index) { hiddenLevel = b.level }
            return true
        }
    }
    var contents: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { Text("CONTENTS").font(.system(size:9,weight:.semibold)).tracking(1.2).foregroundStyle(.tertiary); Spacer(); Button { session.sidebar.toggle() } label: { Image(systemName:session.sidebar ? "pin.fill" : "pin").font(.system(size:10)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("Pin contents · ⌘⇧L") }.padding(.horizontal,22).padding(.top,25).padding(.bottom,15)
            ScrollView {
                VStack(alignment:.leading,spacing:3) {
                    if session.includes.count > 1 {
                        ForEach(session.includes,id:\.self) { path in
                            Button { session.switchFile(path) } label: { Label(path,systemImage:"doc.text").font(.system(size:11)).lineLimit(1).truncationMode(.middle).foregroundStyle(session.active == path ? .primary : .secondary).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,6) }.buttonStyle(.plain)
                        }
                        Divider().padding(.vertical,12)
                    }
                    ForEach(visibleHeadings,id:\.0) { index,b in
                        HStack(spacing:5) {
                            let hasChildren = session.headings.contains { $0.0 > index && $0.1.level > b.level && $0.0 < (session.headings.first { $0.0 > index && $0.1.level <= b.level }?.0 ?? Int.max) }
                            Button { if collapsed.contains(index) { collapsed.remove(index) } else { collapsed.insert(index) } } label: { Image(systemName:collapsed.contains(index) ? "chevron.right" : "chevron.down").font(.system(size:8)).opacity(hasChildren ? 0.6 : 0) }.buttonStyle(.plain).frame(width:10).disabled(!hasChildren)
                            Button { session.buffer.selection = EditSelection(b.body.start,b.body.start); if session.mode == .preview { session.switchMode(.write) }; session.editor?.refresh(reveal:true) } label: { Text(b.text).font(.system(size:11)).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain)
                        }.padding(.leading,CGFloat(max(0,b.level-(session.headings.filter { $0.1.level == 1 }.count == 1 ? 2 : 1)))*12).padding(.vertical,7)
                        .onDrag { draggingHeading = index; return NSItemProvider(object:String(index) as NSString) }
                        .onDrop(of:["public.text"],isTargeted:nil) { _ in
                            if let from = draggingHeading { session.buffer.moveSection(from,before:index); session.changed(); draggingHeading = nil }; return true
                        }
                    }
                }.padding(.horizontal,16)
            }
            Spacer(minLength:0)
        }.background(Color.white)
    }
}
struct PreviewView: NSViewRepresentable {
    @ObservedObject var session: DocumentSession
    func makeNSView(context: Context) -> PDFView {
        let view = NavigablePDFView(); view.session = session; session.pdfView = view
        view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.backgroundColor = NSColor(calibratedWhite:0.96,alpha:1); view.displaysPageBreaks = true; view.pageBreakMargins = NSEdgeInsets(top:16,left:16,bottom:16,right:16)
        view.document = session.pdf
        return view
    }
    func updateNSView(_ view: PDFView,context: Context) {
        if view.document !== session.pdf {
            view.document = session.pdf
            if let anchor = session.sourceMap.first(where: { ($0["path"] as? String) == session.active && ($0["end"] as? Int ?? 0) >= session.buffer.selection.focus }), let page = anchor["page"] as? Int, let pdfPage = session.pdf?.page(at:max(0,page-1)) { view.go(to:pdfPage) }
        }
    }
}
final class NavigablePDFView: PDFView {
    weak var session: DocumentSession?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with:event)
        guard let session, let page = currentPage, let document else { return }
        session.previewPage = document.index(for:page)+1
        let location = convert(event.locationInWindow,from:nil), point = convert(location,to:page)
        let height = page.bounds(for:.mediaBox).height
        let pageNumber = document.index(for:page)+1
        if let nearest = session.sourceMap.filter({ ($0["page"] as? Int) == pageNumber }).min(by: {
            abs(($0["y"] as? Double ?? 0)-(height-point.y)) < abs(($1["y"] as? Double ?? 0)-(height-point.y))
        }), let path = nearest["path"] as? String, let byte = nearest["start"] as? Int, let buffer = session.buffers[path] {
            session.active = path; buffer.selection = EditSelection(byte,byte)
        }
    }
}
