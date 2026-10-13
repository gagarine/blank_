import SwiftUI
import AppKit

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
                        VStack(alignment:.leading,spacing:5) {
                            Text(item.name).font(.headline)
                            Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical,4).tag(item.id)
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
    @NativeState private var showReadme = false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(item.name).font(.title2)
                Text(item.version).foregroundStyle(.secondary)
                Spacer()
                Link("Documentation",destination:item.documentationURL)
            }
            Text(item.description).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            Text((item.authors+item.categories).joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                if library.project(item)?.documentation != nil { Button("Readme") { showReadme = true } }
                Spacer()
                if library.previewing { ProgressView().controlSize(.small); Button("Cancel Preview") { library.cancelPreview() } }
                else if library.pdf(item) == nil { Button("Load Preview") { library.requestPreview() } }
            }
            if let data = library.pdf(item) {
                TemplatePDFView(data:data).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if let error = library.previewError {
                ScrollView { Text(error).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ContentUnavailableView(library.previewing ? "Preparing Preview…" : "Preview",systemImage:"doc",description:Text("The starter project remains editable if its preview cannot compile.")).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }.padding(18)
        .sheet(isPresented:$showReadme) {
            VStack(alignment:.leading,spacing:16) {
                HStack { Text(item.name+" Readme").font(.headline); Spacer(); Button("Done") { showReadme = false }.keyboardShortcut(.cancelAction) }
                ScrollView { Text(library.project(item)?.documentation ?? "Readme is no longer cached. Load the preview again.").textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
            }.padding(20).frame(width:600,height:600)
        }
        .onChange(of:item.id) { _,_ in showReadme = false }
    }
}
