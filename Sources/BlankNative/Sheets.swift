import AppKit
import SwiftUI
import BlankCore

struct SheetFrame<Content: View>: View {
    var title: String
    var width: CGFloat = 500
    var dismiss: ()->Void
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack { Text(title).font(.system(size:18,weight:.semibold)); Spacer(); Button { dismiss() } label: { Image(systemName:"xmark").font(.system(size:11)).foregroundStyle(.secondary).frame(width:28,height:28).contentShape(Rectangle()) }.buttonStyle(.plain).help("Close "+title).accessibilityLabel("Close "+title).keyboardShortcut(.cancelAction) }
            content
        }.padding(28).frame(width:width).background(Color(nsColor:.windowBackgroundColor))
    }
}
struct GoToPageSheet: View {
    @ObservedObject var session: DocumentSession
    @NativeState private var page = ""
    @FocusState private var focused: Bool
    var destination: Int? {
        guard session.canGoToPage, let number = Int(page.trimmingCharacters(in:.whitespaces)),
              (1...(session.pdf?.pageCount ?? 1)).contains(number) else { return nil }
        return number
    }
    var body: some View {
        SheetFrame(title:"Go to Page",width:300,dismiss:{ session.sheet = nil }) {
            HStack {
                Text("Page:")
                TextField("Page number",text:$page).textFieldStyle(.roundedBorder).focused($focused)
                Text("of \(session.pdf?.pageCount ?? 0)").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { session.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Go") {
                    guard let destination else { return }
                    session.goPage(destination); session.sheet = nil
                    session.window?.makeFirstResponder(session.pdfView)
                }.keyboardShortcut(.defaultAction).disabled(destination == nil)
            }
        }.onAppear { page = String(session.previewPage); focused = true }
    }
}
struct CommandsSheet: View {
    @ObservedObject var session: DocumentSession
    @NativeState var selectedCommand = 0
    var actions: [(String,String,()->Void)] {
        [
            ("Settings","⌘,",{ session.sheet = .settings }),
            ("Statistics & info","",{ session.sheet = .statistics }),
            ("Open document","⌘O",{ session.sheet = nil; AppController.shared.openDocument(nil) }),
            ("Save","⌘S",{ session.sheet = nil; session.save() }),
            (session.sidebar ? "Hide sidebar" : "Show sidebar","⌘⇧L",{ session.toggleSidebar(); session.sheet = nil }),
            (session.paragraphFocus ? "Turn off paragraph focus" : "Paragraph focus","",{ session.paragraphFocus.toggle(); session.editor?.lastAppearance = ""; session.editor?.refresh(); session.sheet = nil }),
            (session.typewriter ? "Turn off typewriter scrolling" : "Typewriter scrolling","",{ session.typewriter.toggle(); session.sheet = nil }),
            ("Write mode","⌘1",{ session.sheet = nil; session.switchMode(.write) }),
            ("Source mode","⌘2",{ session.sheet = nil; session.switchMode(.source) }),
            ("Preview mode","⌘3",{ session.sheet = nil; session.switchMode(.preview) }),
            ("Find in document","⌘F",{ session.sheet = nil; session.showSearch() }),
            ("Templates…","",{ session.pendingDocumentAction = { AppController.shared.templates(nil) }; session.sheet = nil }),
            ("New project","",{ session.sheet = nil; AppController.shared.newProject(nil) }),
            ("New document","⌘N",{ session.sheet = nil; AppController.shared.newDocument(nil) }),
            ("Rename document","",{ session.performDocumentAction { $0.rename(nil) } }),
            ("Move document","",{ session.performDocumentAction { $0.move(nil) } }),
            ("Tutorial","",{ session.sheet = nil; AppController.shared.tutorial(nil) }),
            ("Export PDF","⌘⇧E",{ session.sheet = nil; session.exportPDF() }),
            ("Refresh preview","",{ session.sheet = nil; session.compileRevision = -1; session.compile() }),
            ("Convert bibliography…","",{ session.showBibliographyConversion() }),
            ("Bibliography style","",{ session.insertionKind = "bibliography"; session.sheet = .insertion }),
            ("Refresh Zotero references","",{ session.sheet = nil; ZoteroIntegration.refresh(session) }),
            ("Open recovery copy","",{ session.sheet = nil; AppController.shared.recover(nil) })
        ]
    }
    var matches: [(String,String,()->Void)] { actions.filter { session.commandQuery.isEmpty || $0.0.localizedCaseInsensitiveContains(session.commandQuery) } }
    var commandWidth: CGFloat {
        let widest = actions.map { ($0.0 as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12)]).width + ($0.1 as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:10)]).width }.max() ?? 200
        return ceil(widest+140)
    }
    func symbol(_ title: String) -> String {
        switch title {
        case "Settings": return "gearshape"
        case "Statistics & info": return "chart.bar"
        case "Open document": return "folder"
        case "Save": return "square.and.arrow.down"
        case "Write mode": return "pencil"
        case "Source mode": return "chevron.left.forwardslash.chevron.right"
        case "Preview mode": return "doc.richtext"
        case "Find in document": return "magnifyingglass"
        case "Templates…": return "square.grid.2x2"
        case "New document": return "doc.badge.plus"
        case "Rename document": return "character.cursor.ibeam"
        case "Move document": return "folder"
        case "Tutorial": return "book"
        case "Export PDF": return "square.and.arrow.up"
        case "Refresh preview": return "arrow.clockwise"
        case "Convert bibliography…": return "arrow.triangle.2.circlepath"
        case "Bibliography style": return "books.vertical"
        case "Refresh Zotero references": return "arrow.triangle.2.circlepath"
        case "Open recovery copy": return "clock.arrow.circlepath"
        default:
            if title.contains("contents") || title.contains("sidebar") { return "sidebar.left" }
            if title.contains("focus") { return "text.alignleft" }
            return "arrow.up.and.down.text.horizontal"
        }
    }
    var body: some View {
        SheetFrame(title:"Commands",width:commandWidth,dismiss:{ session.sheet = nil }) {
            CommandSearchField(session:session,submit:{ if matches.indices.contains(selectedCommand) { matches[selectedCommand].2() } },move:{ delta in selectedCommand = max(0,min(selectedCommand+delta,matches.count-1)) },changed:{ selectedCommand = 0 })
                .frame(height:24)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing:2) {
                        if matches.isEmpty { Text("No matching commands").font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.vertical,20) }
                        ForEach(Array(matches.enumerated()),id:\.offset) { index,action in
                            MenuRowButton(label:action.0,action:action.2) { HStack(spacing:10) { Image(systemName:symbol(action.0)).frame(width:20).foregroundStyle(.secondary); Text(action.0).font(.system(size:12)).lineLimit(1).fixedSize(); Spacer(); Text(action.1).font(.system(size:10)).foregroundStyle(.tertiary).fixedSize() }.padding(10).frame(maxWidth:.infinity).contentShape(Rectangle()).background(index == selectedCommand ? Color.primary.opacity(0.05) : .clear).clipShape(RoundedRectangle(cornerRadius:5)).contentShape(.interaction,Rectangle()) }.id(index)
                        }
                    }
                }.onChange(of:selectedCommand) { _,index in proxy.scrollTo(index) }.onChange(of:session.commandQuery) { _,_ in proxy.scrollTo(0) }
            }.frame(height:min(340,max(64,CGFloat(matches.count)*46-2)))
        }.onDisappear { session.pendingCommandKeys.removeAll() }
    }
}
struct SettingsSheet: View {
    @ObservedObject var session: DocumentSession
    @AppStorage("reopenUnsavedDocuments") private var reopensUnsavedDocuments = true
    var fonts: [String] { EditorPreferences.installedEditorFamilies }
    var body: some View {
        SheetFrame(title:"Settings",dismiss:{ session.sheet = nil }) {
            Form {
                Picker("Editor font",selection:$session.fontFamily) { ForEach(fonts,id:\.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                HStack { Text("Text size"); Slider(value:$session.fontSize,in:13...28,step:1); Text("\(Int(session.fontSize)) pt").monospacedDigit().frame(width:45) }
                Toggle("Use system colors",isOn:$session.systemColors)
                ColorPicker("Page",selection:$session.paper,supportsOpacity:false).disabled(session.systemColors)
                ColorPicker("Text",selection:$session.ink,supportsOpacity:false).disabled(session.systemColors)
                Toggle("Dark appearance",isOn:$session.dark)
                Toggle("Paragraph focus",isOn:$session.paragraphFocus)
                Toggle("Typewriter scrolling",isOn:$session.typewriter)
                Section {
                    Toggle("Reopen unsaved documents on launch",isOn:$reopensUnsavedDocuments)
                    Text("Restore available drafts when blank_ starts. Saving and closing use macOS’s standard behavior.").font(.system(size:11)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).frame(height:455)
            Text("Source uses the system monospace face. PDF typography is controlled by your Typst source.").font(.system(size:11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { session.sheet = nil }.keyboardShortcut(.defaultAction) }
        }.onDisappear { session.storeEditorPreferences() }
    }
}
struct StatisticsSheet: View {
    @ObservedObject var session: DocumentSession
    var projectWords: Int { session.includes.reduce(0) { $0+(session.buffers[$1]?.counts.words ?? 0) } }
    var dates: URLResourceValues? { session.root.flatMap { try? $0.appendingPathComponent(session.active).resourceValues(forKeys:[.creationDateKey,.contentModificationDateKey,.fileSizeKey]) } }
    var body: some View {
        SheetFrame(title:"Statistics & info",dismiss:{ session.sheet = nil }) {
            Grid(alignment:.leading,horizontalSpacing:70,verticalSpacing:14) {
                GridRow { Text("Words"); Text("\(session.buffer.counts.words)").monospacedDigit() }
                GridRow { Text("Characters"); Text("\(session.buffer.counts.characters)").monospacedDigit() }
                GridRow { Text("Source bytes"); Text("\(session.buffer.source.utf8.count)").monospacedDigit() }
                GridRow { Text("Headings"); Text("\(session.headings.count)").monospacedDigit() }
                GridRow { Text("Project files"); Text("\(session.buffers.count)").monospacedDigit() }
                GridRow { Text("Project words"); Text("\(projectWords)").monospacedDigit() }
                GridRow { Text("Reading time"); Text("\(max(1,session.buffer.projection.text.split(whereSeparator:\.isWhitespace).count/200)) min") }
                GridRow { Text("Undo storage"); Text(ByteCountFormatter.string(fromByteCount:Int64(session.buffer.historyBytes),countStyle:.memory)) }
                if let date = dates?.creationDate { GridRow { Text("Created"); Text(date.formatted(date:.abbreviated,time:.shortened)) } }
                if let date = dates?.contentModificationDate { GridRow { Text("Last saved"); Text(date.formatted(date:.abbreviated,time:.shortened)) } }
            }.font(.system(size:12))
            if let root = session.root { Text(root.appendingPathComponent(session.entry).path).font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("Text counts describe prose and table cells. Custom code is omitted. Project words include the open chapter files.").font(.system(size:11)).foregroundStyle(.secondary)
        }
    }
}
struct InsertionSheet: View {
    @ObservedObject var session: DocumentSession
    @NativeState var text = ""
    @NativeState var extra = ""
    @NativeState var alt = ""
    @NativeState var imageWidth = 85
    @NativeState var columns = 2
    @NativeState var rows = 3
    @StateObject private var citationSearch = CitationSearch()
    @NativeState private var citationChoices = CitationChoices()
    @NativeState private var chosenReferences: [String:ZoteroReference] = [:]
    @NativeState var finding = false
    @NativeState var failure = ""
    @NativeState var library = "personal"
    @NativeState var locator = ""
    @NativeState var form = "normal"
    @NativeState private var loadedInitialReferences = false
    @FocusState var focus: Bool
    @NativeState var bibliographyDestination = ""
    @NativeState var bibliographyLocation = ""
    @NativeState private var referenceLabels: [String] = []
    var title: String { session.insertionKind == "bibliography" ? "Bibliography style" : SlashCommand.all.first { $0.kind == session.insertionKind }?.label ?? "Insert" }
    var body: some View {
        SheetFrame(title:title,width:session.insertionKind == "citation" ? 620 : 500,dismiss:{ session.sheet = nil }) {
            if session.insertionKind == "citation" { citation }
            else if session.insertionKind == "table" {
                HStack { Stepper("Columns: \(columns)",value:$columns,in:1...12); Spacer(); Stepper("Rows: \(rows)",value:$rows,in:1...50) }
                Text("Edit cells directly in Write. Change rows and columns through the table's block menu.").font(.system(size:11)).foregroundStyle(.secondary)
            } else {
                if session.insertionKind == "image" {
                    TextField("Project-relative image path",text:$text).textFieldStyle(.roundedBorder)
                    Button("Choose image or PDF…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image,.pdf]
                        if panel.runModal() == .OK, let url = panel.url { do { text = try session.importImage(url) } catch { failure = error.localizedDescription } }
                    }
                    TextField("Caption",text:$extra).textFieldStyle(.roundedBorder)
                    TextField("Alternative text",text:$alt).textFieldStyle(.roundedBorder)
                    Stepper("Width: \(imageWidth)%",value:$imageWidth,in:5...100,step:5)
                } else if session.insertionKind == "reference" {
                    ReferenceLabelField(text:$text,labels:referenceLabels,submit:{ insert() },cancel:{ session.sheet = nil }).frame(height:26)
                    Text("Choose an existing label or enter a new target.").font(.system(size:11)).foregroundStyle(.secondary)
                } else if session.insertionKind == "link" {
                    TextField("https://…",text:$text).textFieldStyle(.roundedBorder).focused($focus)
                    TextField("Link text",text:$extra).textFieldStyle(.roundedBorder)
                } else if session.insertionKind == "bibliography" {
                    if session.bibliographyLocations.count > 1 {
                        Picker("Bibliography",selection:$bibliographyLocation) {
                            Text("Choose a bibliography…").tag("")
                            ForEach(session.bibliographyLocations) { Text($0.label).tag($0.id) }
                        }
                    }
                    TextField("Style name or CSL path",text:$text).textFieldStyle(.roundedBorder)
                    HStack {
                        Menu("Standard styles") { ForEach(["apa","ieee","chicago-author-date","mla","vancouver"],id:\.self) { style in Button(style) { text = style } } }
                        Button("Choose CSL…") {
                            let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension:"csl")!]
                            if panel.runModal() == .OK, let url = panel.url {
                                do {
                                    let relative = try session.importImage(url)
                                    if let path = session.projectAssetPath(relative), let location = session.bibliographyLocations.first(where:{ $0.id == bibliographyLocation }) { text = session.relativeAssetPath(path,file:location.file) }
                                    else { text = relative }
                                } catch { failure = error.localizedDescription }
                            }
                        }.disabled(bibliographyLocation.isEmpty)
                    }
                } else {
                    TextField(session.insertionKind == "equation" ? "Typst mathematics" : session.insertionKind == "label" || session.insertionKind == "reference" ? "Label name" : "Text",text:$text,axis:.vertical).lineLimit(3...7).textFieldStyle(.roundedBorder).focused($focus)
                }
            }
            if !failure.isEmpty { Text(failure).font(.system(size:11)).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Cancel") { session.sheet = nil }.keyboardShortcut(.cancelAction); Button("Insert") { insert() }.keyboardShortcut(.defaultAction).disabled(finding || session.insertionKind == "reference" && crossReferenceTarget(text).isEmpty) }
        }.onAppear {
            focus = true
            if session.insertionKind == "reference" { referenceLabels = session.referenceLabels }
            if session.insertionKind == "bibliography" {
                text = "apa"
                if session.bibliographyLocations.count == 1 { bibliographyLocation = session.bibliographyLocations[0].id }
            }
            if session.insertionKind == "citation" && !loadedInitialReferences {
                loadedInitialReferences = true
                session.loadBibliographies(); citationChoices = session.citationChoices()
                session.prepareProjectCopy { error in
                    if let error { failure = error.localizedDescription }
                    else { session.loadBibliographies(); citationChoices = session.citationChoices(); session.objectWillChange.send() }
                }
                searchZotero()
            }
        }.onDisappear { citationSearch.cancel() }
    }
    var citation: some View {
        VStack(alignment:.leading,spacing:12) {
            TextField("Title, author or year",text:$text).textFieldStyle(.roundedBorder).focused($focus)
                .onChange(of:text) { _,_ in searchZotero() }
            TextField("Library: personal or groups/123",text:$library).textFieldStyle(.roundedBorder)
                .onChange(of:library) { _,_ in chosenReferences.removeAll(); searchZotero() }
            if citationSearch.finding { ProgressView().controlSize(.small) }
            if !citationSearch.error.isEmpty { Text(citationSearch.error).font(.system(size:11)).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ForEach(citationChoices.results(citationSearch.references,query:text)) { ref in
                        Toggle(isOn:Binding(get:{ chosenReferences[ref.id] != nil },set:{ if $0 { chosenReferences[ref.id] = ref } else { chosenReferences.removeValue(forKey:ref.id) } })) {
                            VStack(alignment:.leading,spacing:3) {
                                HStack {
                                    Text(ref.title).font(.system(size:12))
                                    if citationChoices.keys.contains(ref.citeKey) { Label("Already cited",systemImage:"checkmark.circle.fill").font(.system(size:10)).foregroundStyle(.secondary) }
                                }
                                Text([ref.author,ref.year].filter { !$0.isEmpty }.joined(separator:" · ")).font(.system(size:10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(4)
            }.frame(height:220)
            HStack { TextField("Page / locator",text:$locator).textFieldStyle(.roundedBorder); Picker("Citation display",selection:$form) { Text("Standard citation").tag("normal"); Text("In a sentence").tag("prose"); Text("Author only").tag("author"); Text("Year only").tag("year") }.frame(width:250) }
            if let destinations = try? session.referenceDestinations(), destinations.count > 1 {
                Picker("Bibliography",selection:$bibliographyDestination) {
                    Text("Choose a destination…").tag("")
                    ForEach(destinations) { Text($0.label).tag($0.id) }
                }
            }
            Text("The document’s style controls formatting; this choice controls how the citation is used.").font(.system(size:11)).foregroundStyle(.secondary)
            Text(form == "prose" ? "For example in APA: Smith (2020) found…" : form == "author" ? "For example: Smith" : form == "year" ? "For example: 2020" : "Uses the document’s citation style, for example (Smith, 2020) in APA or [1] in IEEE.").font(.system(size:11)).foregroundStyle(.secondary)
            Text("Keep Zotero open with Settings → Advanced → Allow other applications on this computer to communicate with Zotero enabled.").font(.system(size:11)).foregroundStyle(.secondary)
        }
    }
    func searchZotero() { citationSearch.search(query:text,library:library,delay:loadedInitialReferences && text.isEmpty ? 0 : 0.18) }
    func insert() {
        guard session.requestEditing() else { return }
        switch session.insertionKind {
        case "table":
            let cells = (0..<rows*columns).map { "  [\($0 < columns ? "Column \($0+1)" : "")]," }.joined(separator:"\n")
            session.insertSource("#table(columns: \(columns),\n\(cells)\n)",block:true)
        case "image": session.insertSource("#figure(image(\(jsonString(text)), width: \(imageWidth)%, alt: \(jsonString(alt))), caption: [\(escapeTypst(extra))])",block:true)
        case "equation": session.insertSource("$ \(text) $",block:true)
        case "footnote": session.insertSource("#footnote[\(escapeTypst(text))]")
        case "link": session.insertSource("#link(\(jsonString(text)))[\(escapeTypst(extra.isEmpty ? text : extra))]")
        case "label": session.insertSource("<\(safeLabel(text))>")
        case "reference":
            let target = crossReferenceTarget(text)
            guard !target.isEmpty else { return }
            // Terminate the inline code so adjacent prose/brackets cannot
            // become part of the target or another argument of the call.
            session.insertSource("#ref(<\(target)>);")
        case "citation":
            finding = true
            ZoteroIntegration.insert(chosenReferences.values.sorted { $0.id < $1.id }.map { ref in
                var ref = ref; if citationChoices.keys.contains(ref.citeKey) { ref.key = "" }; return ref
            },session:session,anchor:session.insertionAnchor,locator:locator,form:form,destinationID:bibliographyDestination.isEmpty ? nil : bibliographyDestination) { error in finding = false; if let error { failure = error.localizedDescription } else { session.sheet = nil } }
        case "bibliography":
            do { try session.setBibliographyStyle(text,locationID:bibliographyLocation); session.sheet = nil }
            catch { failure = error.localizedDescription }
        default: break
        }
    }
}
func jsonString(_ text: String) -> String { typstStringLiteral(text) }
func safeLabel(_ text: String) -> String { text.filter { $0.isLetter || $0.isNumber || "-_:.".contains($0) } }
struct ObjectSheet: View {
    @ObservedObject var session: DocumentSession
    @NativeState var raw = ""
    @NativeState private var editingSource = false
    var body: some View {
        if session.objectTitle == "Edit Citation", let edit = CitationFieldEdit(session.objectOriginal) {
            CitationFieldEditor(session:session,edit:edit)
        } else if !editingSource, session.objectTitle == "Edit Image", let edit = FigureFieldEdit(session.objectOriginal) {
            FigureFieldEditor(session:session,edit:edit,editSource:{ editingSource = true })
        } else { sourceEditor }
    }
    var sourceEditor: some View {
        SheetFrame(title:editingSource ? "Edit source" : session.objectTitle,width:620,dismiss:{ session.sheet = nil }) {
            TextEditor(text:$raw).font(.system(size:13,design:.monospaced)).frame(height:260).border(Color.primary.opacity(0.1))
            Text("Every character is preserved. Preview shows the typeset result.").font(.system(size:11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { session.sheet = nil }.keyboardShortcut(.cancelAction); Button("Apply") { apply() }.keyboardShortcut(.defaultAction) }
        }.onAppear { raw = session.objectOriginal }
    }
    func apply() {
        _ = session.applyObjectSource(raw)
    }
}
struct ConflictSheet: View {
    @ObservedObject var session: DocumentSession
    var body: some View {
        SheetFrame(title:"Document changed outside blank_",dismiss:{ session.sheet = nil }) {
            Text("Your local writing is retained in a recovery copy. Choose which version to keep for the changed files.").font(.system(size:12))
            Text(session.conflictDisk.keys.sorted().joined(separator:"\n")).font(.system(size:12,design:.monospaced))
            HStack {
                Button("Use disk version") {
                    session.useDiskVersion()
                }
                Spacer()
                Button("Keep my writing") {
                    for (path,text) in session.conflictDisk { if session.deletedFiles.contains(path) { session.bases.removeValue(forKey:path) } else { session.bases[path] = text } }
                    session.deletedFiles.removeAll()
                    session.conflictDisk.removeAll(); session.sheet = nil; session.error = nil; session.autosave()
                }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
