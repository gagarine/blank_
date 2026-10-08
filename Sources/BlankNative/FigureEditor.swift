import AppKit
import SwiftUI
import BlankCore

struct FigureFieldEditor: View {
    @ObservedObject var session: DocumentSession
    let edit: FigureFieldEdit
    let editSource: () -> Void
    @NativeState private var path = ""
    @NativeState private var caption = ""
    @NativeState private var alt = ""
    @NativeState private var width = 85
    @NativeState private var replacement: URL?
    @NativeState private var failure = ""
    var body: some View {
        SheetFrame(title:"Edit Image",width:500,dismiss:{ session.sheet = nil }) {
            TextField("Project-relative image path",text:$path).textFieldStyle(.roundedBorder)
                .onChange(of:path) { _,_ in replacement = nil }
            Button("Choose image or PDF…") {
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.image,.pdf]
                if panel.runModal() == .OK, let url = panel.url { replacement = url }
            }
            if let replacement { Text("Replacement: "+replacement.lastPathComponent).font(.system(size:11)).foregroundStyle(.secondary) }
            TextField("Caption",text:$caption).textFieldStyle(.roundedBorder)
            TextField("Alternative text",text:$alt).textFieldStyle(.roundedBorder)
            Stepper("Width: \(width)%",value:$width,in:5...100,step:5)
            if !failure.isEmpty { Text(failure).font(.system(size:11)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Edit source…",action:editSource)
                Spacer()
                Button("Cancel") { session.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    do { _ = try session.applyFigure(edit,path:path,caption:caption,alt:alt,width:width,replacement:replacement) }
                    catch { failure = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.onAppear { path = edit.path; caption = edit.caption; alt = edit.alt; width = edit.width }
    }
}

@MainActor extension DocumentSession {
    @discardableResult func applyFigure(_ edit: FigureFieldEdit,path: String,caption: String,alt: String,width: Int,replacement: URL? = nil) throws -> Bool {
        guard requestEditing(), objectSnapshotIsCurrent(), edit.original.utf8.elementsEqual(objectOriginal.utf8) else { return false }
        // Choose only stages a URL. Cancel, stale edits and failed reads/writes
        // leave project assets alone. Keep both assets for source Undo/Redo.
        let finalPath = try replacement.map { try importImage($0) } ?? path
        let source = edit.applying(path:finalPath,caption:caption,alt:alt,width:width)
        if source.utf8.elementsEqual(objectOriginal.utf8) { sheet = nil; return true }
        return applyObjectSource(source)
    }
}
