import SwiftUI
import AppKit
import PDFKit

enum SidebarMode: String, CaseIterable { case thumbnails = "Thumbnails", contents = "Table of Contents", contactSheet = "Contact Sheet" }
enum PreviewDisplayMode: String, CaseIterable {
    case continuous = "Continuous Scroll", single = "Single Page", two = "Two Pages"
    var pdfMode: PDFDisplayMode { switch self { case .continuous: .singlePageContinuous; case .single: .singlePage; case .two: .twoUp } }
}
struct DocumentSidebar: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var contentsDrag: ContentsDrag
    var body: some View {
        VStack(spacing:0) {
            if session.searchVisible && !session.searchQuery.isEmpty { SearchResultsView(session:session,search:session.searchController) }
            else if session.sidebarMode == .contents { ContentsView(session:session,contentsDrag:contentsDrag) }
            else { ThumbnailSidebar(session:session,thumbnails:session.thumbnails) }
            if session.sidebarMode == .contents && !(session.searchVisible && !session.searchQuery.isEmpty) { HStack {
                Toggle(isOn:$session.sidebarOrderLocked) { Label("Lock section order",systemImage:session.sidebarOrderLocked ? "lock.fill" : "lock.open") }
                    .toggleStyle(.button).buttonStyle(.plain).font(.system(size:11)).foregroundStyle(.secondary)
                    .help("Prevent dragging headings and chapters. Text editing and block movement stay available.")
                Spacer(minLength:0)
            }.padding(16) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.clear)
    }
}
struct SearchResultsView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var search: DocumentSearch
    var snippet: (DocumentMatch)->AttributedString = { match in
        let text = NSMutableAttributedString(string:match.snippet)
        if NSMaxRange(match.snippetMatch) <= text.length { text.addAttributes([.backgroundColor:NSColor.systemYellow,.foregroundColor:NSColor.black,.font:NSFont.systemFont(ofSize:11,weight:.semibold)],range:match.snippetMatch) }
        return AttributedString(text)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { Text("Search Results").font(.headline); Spacer(); if search.searching { ProgressView().controlSize(.small) } }.padding(16)
            if search.matches.isEmpty && !search.searching { Text("No matches").foregroundStyle(.secondary).padding(.horizontal,16) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:4) {
                        ForEach(search.groups) { group in
                            let match = group.matches.first { $0.id == search.selected } ?? group.matches[0]
                            Button { search.reveal(match.id) } label: {
                                HStack(alignment:.top,spacing:10) {
                                    if let page = match.page { SearchPageThumbnail(session:session,page:page) }
                                    VStack(alignment:.leading,spacing:4) {
                                        HStack {
                                            Text(match.page.map { "Page \($0+1)" } ?? (session.projectSearch ? match.path : session.mode.rawValue)).fontWeight(.semibold)
                                            Spacer(minLength:2)
                                            if match.page != nil { Text("\(group.matches.count) \(group.matches.count == 1 ? "match" : "matches")") }
                                        }.font(.system(size:10)).foregroundStyle(.secondary)
                                        Text(snippet(match)).font(.system(size:11)).lineLimit(4).frame(maxWidth:.infinity,alignment:.leading)
                                    }
                                }.padding(10).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                                    .background(group.matches.contains { $0.id == search.selected } ? Color.primary.opacity(0.08) : .clear).clipShape(RoundedRectangle(cornerRadius:8))
                            }.buttonStyle(.plain).id(group.id)
                        }
                    }.padding(.horizontal,8)
                }.onChange(of:search.selected) { _,index in
                    if let group = search.groups.first(where:{ $0.matches.contains { $0.id == index } }) { proxy.scrollTo(group.id,anchor:.center) }
                }
            }
        }
    }
}
struct SearchPageThumbnail: View {
    @ObservedObject var session: DocumentSession
    var page: Int
    @NativeState private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage:image).resizable().scaledToFit() } else { Color.clear } }.frame(width:38,height:54)
            .task(id:"\(session.compileRevision):\(page)") { image = session.thumbnails.pdfThumbnail(page,width:76) }
    }
}
struct ThumbnailSidebar: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var thumbnails: DocumentThumbnails
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Text(session.sidebarMode.rawValue).font(.headline).padding(16)
            if session.mode == .preview, let pdfView = session.pdfView {
                NativePDFThumbnails(pdfView:pdfView).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if session.mode == .preview { Text("Typesetting…").foregroundStyle(.secondary).padding(16); Spacer() }
            else {
                ScrollView {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:155))],spacing:18) {
                        ForEach(thumbnails.pages,id:\.self) { page in TextPageThumbnail(session:session,thumbnails:thumbnails,page:page) }
                    }.padding(16)
                }
            }
        }.task(id:"\(session.sidebar):\(session.mode.rawValue):\(session.active):\(session.revision):\(session.fontFamily):\(session.fontSize):\(session.dark):\(session.systemColors):\(session.paper):\(session.ink)") {
            do { try await Task.sleep(for:.milliseconds(180)) } catch { return }
            if session.sidebar && session.mode != .preview { thumbnails.update() }
        }
    }
}
struct TextPageThumbnail: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var thumbnails: DocumentThumbnails
    var page: Int
    @NativeState private var image: NSImage?
    var body: some View {
        Button { thumbnails.navigate(page) } label: {
            VStack(spacing:6) {
                Group { if let image { Image(nsImage:image).resizable().scaledToFit() } else { Rectangle().fill(Color(nsColor:session.paperColor)).aspectRatio(0.707,contentMode:.fit) } }
                    .clipShape(RoundedRectangle(cornerRadius:4)).shadow(color:.black.opacity(0.12),radius:2,y:1)
                Text("\(page+1)").font(.system(size:11)).foregroundStyle(.secondary)
            }.padding(5).background(thumbnails.currentPage == page ? Color.accentColor.opacity(0.18) : .clear).clipShape(RoundedRectangle(cornerRadius:8)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(session.mode.rawValue) page \(page+1)")
            .task(id:"\(thumbnails.generation):\(page)") { image = thumbnails.image(page) }
    }
}
struct NativePDFThumbnails: NSViewRepresentable {
    var pdfView: PDFView
    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView(); view.backgroundColor = .clear; view.allowsDragging = false
        return view
    }
    func updateNSView(_ view: PDFThumbnailView,context: Context) {
        view.pdfView = pdfView; view.maximumNumberOfColumns = 1
        view.thumbnailSize = NSSize(width:156,height:220)
    }
}
struct SearchStatus: View {
    @ObservedObject var search: DocumentSearch
    var body: some View { Text(search.status).foregroundStyle(.secondary) }
}
