import SwiftUI
import AppKit
import PDFKit

struct UniverseGallery: View {
    @ObservedObject var library: UniverseLibrary
    let query: String
    var items: [UniverseTemplate] { library.templates.filter { $0.matches(query) } }
    var body: some View {
        if library.templates.isEmpty {
            VStack(spacing:16) {
                if library.loading { ProgressView("Loading Typst Universe…") }
                else {
                    ContentUnavailableView("Universe Unavailable",systemImage:"globe",description:Text(library.loadError ?? "Load the catalogue to browse templates."))
                    Button("Try Again") { library.load(refresh:true) }
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            HSplitView {
                List(selection:$library.selection) {
                    ForEach(items) { item in
                        UniverseRow(item:item,thumbnails:library.thumbnails).tag(item.id)
                    }
                }.frame(minWidth:230,idealWidth:300,maxWidth:380).accessibilityLabel("Universe templates")
                if let item = library.selected {
                    UniverseDetails(library:library,item:item).frame(minWidth:300,maxWidth:.infinity,maxHeight:.infinity)
                } else {
                    ContentUnavailableView(items.isEmpty ? "No Matching Templates" : "Choose a Template",systemImage:"doc.text",description:Text(items.isEmpty ? "Try another search." : "Inspect its details and preview before creating a document.")).frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }
        }
    }
}
struct UniverseDetails: View {
    @ObservedObject var library: UniverseLibrary
    let item: UniverseTemplate
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(item.name).font(.title2)
                Spacer()
                Link("Universe",destination:item.documentationURL)
            }
            Text(item.description).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            VSplitView {
                VStack(spacing:8) {
                    if let data = library.pdf(item) {
                        UniversePDFPreview(data:data).id(item.id)
                    } else if let error = library.previewError {
                        ScrollView { Text(error).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                        Button("Retry Preview") { library.requestPreview() }
                    } else {
                        ProgressView("Preparing Preview…").frame(maxWidth:.infinity,maxHeight:.infinity)
                    }
                    if library.previewing {
                        Button("Cancel Preview") { library.cancelPreview(); library.previewError = "Preview cancelled." }
                    }
                }.frame(minHeight:160,maxHeight:.infinity)
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        if library.project(item)?.documentation != nil {
                            Text("Readme").font(.headline)
                            UniverseReadme(blocks:library.project(item)?.readmeBlocks ?? []).textSelection(.enabled)
                        }
                        UniverseAbout(item:item)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(.top,12)
                }.frame(minHeight:110,idealHeight:200,maxHeight:.infinity)
            }
        }.padding(18)
        .task(id:item.id) { library.requestPreview() }
    }
}

struct UniverseAbout: View {
    let item: UniverseTemplate
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("About").font(.headline)
            Grid(alignment:.leading,horizontalSpacing:18,verticalSpacing:8) {
                row("Author",item.authors.joined(separator:", "))
                if let license = item.license { row("License",license) }
                row("Current version",item.version)
                if let updated = item.updatedAt { row("Last updated",date(updated)) }
                if let first = item.firstReleasedAt { row("First released",date(first)) }
                if let compiler = item.compiler { row("Minimum Typst version",compiler) }
                if let url = item.repositoryURL {
                    GridRow { Text("Repository").foregroundStyle(.secondary); Link(url.host ?? "Repository",destination:url) }
                }
                if !item.categories.isEmpty { row("Category",item.categories.map { $0.capitalized }.joined(separator:", ")) }
            }.font(.callout).textSelection(.enabled)
        }
    }
    private func row(_ label: String,_ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).fixedSize(horizontal:false,vertical:true) }
    }
    private func date(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970:timestamp).formatted(.dateTime.year().month(.wide).day())
    }
}

@MainActor final class UniversePreviewPages: ObservableObject {
    let document: PDFDocument?
    @Published var index = 0
    var count: Int { document?.pageCount ?? 0 }
    init(data: Data) { document = PDFDocument(data:data) }
    func move(_ offset: Int) { index = min(max(0,index+offset),max(0,count-1)) }
}
struct UniversePDFPreview: View {
    @StateObject private var pages: UniversePreviewPages
    init(data: Data) { _pages = StateObject(wrappedValue:UniversePreviewPages(data:data)) }
    var body: some View {
        VStack(spacing:8) {
            UniversePageView(pages:pages).frame(maxWidth:.infinity,maxHeight:.infinity)
            HStack(spacing:16) {
                Button { pages.move(-1) } label: { Image(systemName:"chevron.left") }.help("Previous page").accessibilityLabel("Previous page").disabled(pages.index == 0)
                Text("\(pages.index+1) of \(pages.count)").monospacedDigit().foregroundStyle(.secondary).accessibilityLabel("Preview page \(pages.index+1) of \(pages.count)")
                Button { pages.move(1) } label: { Image(systemName:"chevron.right") }.help("Next page").accessibilityLabel("Next page").disabled(pages.index+1 >= pages.count)
            }.controlSize(.small)
        }
    }
}
struct UniversePageView: NSViewRepresentable {
    @ObservedObject var pages: UniversePreviewPages
    final class Coordinator {
        var observation: NSObjectProtocol?
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage; view.autoScales = true; view.backgroundColor = .windowBackgroundColor
        view.document = pages.document
        context.coordinator.observation = NotificationCenter.default.addObserver(forName:.PDFViewPageChanged,object:view,queue:.main) { [weak view, weak pages] _ in
            // PDFKit also handles native arrow navigation; keep the pager in sync.
            DispatchQueue.main.async {
                guard let view, let pages, let page = view.currentPage, let document = pages.document else { return }
                let index = document.index(for:page)
                if pages.index != index { pages.index = index }
            }
        }
        return view
    }
    func updateNSView(_ view: PDFView,context: Context) {
        if let page = pages.document?.page(at:pages.index), view.currentPage !== page { view.go(to:page) }
    }
}

struct UniverseRow: View {
    let item: UniverseTemplate
    @ObservedObject var thumbnails: UniverseThumbnails
    var body: some View {
        HStack(spacing:12) {
            Group {
                if let image = thumbnails.image(item) { Image(nsImage:image).resizable().scaledToFit() }
                else { Image(systemName:"doc").font(.title2).foregroundStyle(.secondary) }
            }.frame(width:52,height:72).accessibilityLabel(item.name+" thumbnail")
            VStack(alignment:.leading,spacing:5) {
                Text(item.name).font(.headline)
                Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(.vertical,4)
        .onAppear { thumbnails.show(item) }
        .onDisappear { thumbnails.hide(item) }
    }
}
