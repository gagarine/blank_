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
            HStack { Text(title).font(.system(size:18,weight:.semibold)); Spacer(); Button { dismiss() } label: { Image(systemName:"xmark").font(.system(size:11)).foregroundStyle(.secondary) }.buttonStyle(.plain).keyboardShortcut(.cancelAction) }
            content
        }.padding(28).frame(width:width).background(Color(nsColor:.windowBackgroundColor))
    }
}
struct CommandsSheet: View {
    @ObservedObject var session: DocumentSession
    @FocusState var focused: Bool
    @NativeState var selectedCommand = 0
    var actions: [(String,String,()->Void)] {
        [
            ("Settings","⌘,",{ session.sheet = .settings }),
            ("Statistics & info","",{ session.sheet = .statistics }),
            ("Open document","⌘O",{ session.sheet = nil; AppController.shared.openDocument(nil) }),
            ("Save","⌘S",{ session.sheet = nil; session.save() }),
            (session.sidebar ? "Unpin table of contents" : "Pin table of contents","⌘⇧L",{ session.sidebar.toggle(); session.sheet = nil }),
            (session.paragraphFocus ? "Turn off paragraph focus" : "Paragraph focus","",{ session.paragraphFocus.toggle(); session.editor?.lastAppearance = ""; session.editor?.refresh(); session.sheet = nil }),
            (session.typewriter ? "Turn off typewriter scrolling" : "Typewriter scrolling","",{ session.typewriter.toggle(); session.sheet = nil }),
            ("Write mode","⌘1",{ session.sheet = nil; session.switchMode(.write) }),
            ("Source mode","⌘2",{ session.sheet = nil; session.switchMode(.source) }),
            ("Preview mode","⌘3",{ session.sheet = nil; session.switchMode(.preview) }),
            ("Find in document","⌘F",{ session.sheet = nil; session.searchVisible = true }),
            ("New document","⌘N",{ session.sheet = nil; AppController.shared.newDocument(nil) }),
            ("New paper","",{ session.sheet = nil; AppController.shared.newPaper(nil) }),
            ("New thesis","",{ session.sheet = nil; AppController.shared.newThesis(nil) }),
            ("Rename document","",{ session.sheet = .rename }),
            ("Tutorial","",{ session.sheet = nil; AppController.shared.tutorial(nil) }),
            ("Export PDF","⌘⇧E",{ session.sheet = nil; session.exportPDF() }),
            ("Fullscreen","⌃⌘F",{ session.sheet = nil; session.window?.toggleFullScreen(nil) }),
            ("Refresh preview","",{ session.sheet = nil; session.compileRevision = -1; session.compile() }),
            ("Bibliography style","",{ session.insertionKind = "bibliography"; session.sheet = .insertion }),
            ("Refresh Zotero references","",{ session.sheet = nil; ZoteroIntegration.refresh(session) }),
            ("Open recovery copy","",{ session.sheet = nil; AppController.shared.recover(nil) })
        ]
    }
    var matches: [(String,String,()->Void)] { actions.filter { session.commandQuery.isEmpty || $0.0.localizedCaseInsensitiveContains(session.commandQuery) } }
    var body: some View {
        SheetFrame(title:"Commands",dismiss:{ session.sheet = nil }) {
            TextField("Search commands…",text:$session.commandQuery).textFieldStyle(.roundedBorder).focused($focused).onSubmit { if matches.indices.contains(selectedCommand) { matches[selectedCommand].2() } }
                .onKeyPress(.downArrow) { selectedCommand = min(selectedCommand+1,max(0,matches.count-1)); return .handled }
                .onKeyPress(.upArrow) { selectedCommand = max(0,selectedCommand-1); return .handled }
                .onChange(of:session.commandQuery) { _,_ in selectedCommand = 0 }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing:2) {
                        ForEach(Array(matches.enumerated()),id:\.offset) { index,action in
                            Button { action.2() } label: { HStack { Text(action.0).font(.system(size:12)); Spacer(); Text(action.1).font(.system(size:10)).foregroundStyle(.tertiary) }.padding(10).background(index == selectedCommand ? Color.primary.opacity(0.05) : .clear).clipShape(RoundedRectangle(cornerRadius:5)).contentShape(Rectangle()) }.buttonStyle(.plain).id(index)
                        }
                    }
                }.onChange(of:selectedCommand) { _,index in proxy.scrollTo(index) }.onChange(of:session.commandQuery) { _,_ in proxy.scrollTo(0) }
            }.frame(height:340)
        }.onAppear { focused = true }
    }
}
struct RenameSheet: View {
    @ObservedObject var session: DocumentSession
    @NativeState var name = ""
    @NativeState var failure = ""
    @FocusState var focused: Bool
    var body: some View {
        SheetFrame(title:"Rename document",dismiss:{ session.sheet = nil }) {
            TextField("Document name",text:$name).textFieldStyle(.roundedBorder).focused($focused).onSubmit { rename() }
            if !failure.isEmpty { Text(failure).font(.system(size:11)).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { session.sheet = nil }.keyboardShortcut(.cancelAction); Button("Rename") { rename() }.keyboardShortcut(.defaultAction) }
        }.onAppear { name = (session.entry as NSString).lastPathComponent.replacingOccurrences(of:".typ",with:""); focused = true }
    }
    func rename() { do { try session.renameEntry(name); session.sheet = nil } catch { failure = error.localizedDescription } }
}
struct SettingsSheet: View {
    @ObservedObject var session: DocumentSession
    var fonts: [String] { NSFontManager.shared.availableFontFamilies.sorted() }
    var body: some View {
        SheetFrame(title:"Settings",dismiss:{ session.sheet = nil }) {
            Form {
                Picker("Reading font",selection:$session.fontFamily) { ForEach(fonts,id:\.self) { Text($0).tag($0) } }
                HStack { Text("Text size"); Slider(value:$session.fontSize,in:13...28,step:1); Text("\(Int(session.fontSize)) pt").monospacedDigit().frame(width:45) }
                ColorPicker("Page",selection:$session.paper,supportsOpacity:false)
                ColorPicker("Text",selection:$session.ink,supportsOpacity:false)
                Toggle("Dark appearance",isOn:$session.dark).onChange(of:session.dark) { _,dark in session.paper = dark ? Color(nsColor:NSColor(calibratedWhite:0.11,alpha:1)) : .white; session.ink = dark ? Color(nsColor:NSColor(calibratedWhite:0.87,alpha:1)) : Color(nsColor:NSColor(calibratedWhite:0.20,alpha:1)) }
                Toggle("Paragraph focus",isOn:$session.paragraphFocus)
                Toggle("Typewriter scrolling",isOn:$session.typewriter)
            }.formStyle(.grouped).frame(height:340)
            Text("Source uses the system monospace face. PDF typography is controlled by your Typst source.").font(.system(size:11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { UserDefaults.standard.set(session.fontFamily,forKey:"readingFont"); UserDefaults.standard.set(session.fontSize,forKey:"readingSize"); EditorPreferences.store(session.paper,key:"paper"); EditorPreferences.store(session.ink,key:"ink"); UserDefaults.standard.set(session.dark,forKey:"dark"); session.sheet = nil; session.editor?.lastAppearance = ""; session.editor?.refresh() }.keyboardShortcut(.defaultAction) }
        }
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
    @NativeState var refs: [ZoteroReference] = []
    @NativeState var finding = false
    @NativeState var failure = ""
    @NativeState var library = "personal"
    @NativeState var locator = ""
    @NativeState var form = "normal"
    @NativeState var selected = Set<String>()
    @FocusState var focus: Bool
    var title: String { session.insertionKind == "bibliography" ? "Bibliography style" : SlashCommand.all.first { $0.kind == session.insertionKind }?.label ?? "Insert" }
    var body: some View {
        SheetFrame(title:title,width:session.insertionKind == "citation" ? 620 : 500,dismiss:{ session.sheet = nil }) {
            if session.insertionKind == "citation" { citation }
            else if session.insertionKind == "table" {
                HStack { Stepper("Columns: \(columns)",value:$columns,in:1...12); Spacer(); Stepper("Rows: \(rows)",value:$rows,in:1...50) }
                Text("Cells can be edited through the block menu. The Typst table keeps its literal source.").font(.system(size:11)).foregroundStyle(.secondary)
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
                } else if session.insertionKind == "link" {
                    TextField("https://…",text:$text).textFieldStyle(.roundedBorder).focused($focus)
                    TextField("Link text",text:$extra).textFieldStyle(.roundedBorder)
                } else if session.insertionKind == "bibliography" {
                    Picker("Style",selection:$text) { ForEach(["apa","ieee","chicago-author-date","mla","vancouver"],id:\.self) { Text($0).tag($0) } }
                } else {
                    TextField(session.insertionKind == "equation" ? "Typst mathematics" : session.insertionKind == "label" || session.insertionKind == "reference" ? "Label name" : "Text",text:$text,axis:.vertical).lineLimit(3...7).textFieldStyle(.roundedBorder).focused($focus)
                }
            }
            if !failure.isEmpty { Text(failure).font(.system(size:11)).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Cancel") { session.sheet = nil }.keyboardShortcut(.cancelAction); Button("Insert") { insert() }.keyboardShortcut(.defaultAction).disabled(finding) }
        }.onAppear { focus = true; if session.insertionKind == "bibliography" { text = "apa" } }
    }
    var citation: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                TextField("Title, author or year",text:$text).textFieldStyle(.roundedBorder).focused($focus).onSubmit { searchZotero() }
                Button("Search") { searchZotero() }.disabled(finding)
            }
            TextField("Library: personal or groups/123",text:$library).textFieldStyle(.roundedBorder)
            if finding { ProgressView().controlSize(.small) }
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ForEach(refs) { ref in
                        Toggle(isOn:Binding(get:{ selected.contains(ref.key) },set:{ if $0 { selected.insert(ref.key) } else { selected.remove(ref.key) } })) {
                            VStack(alignment:.leading,spacing:3) { Text(ref.title).font(.system(size:12)); Text(ref.author+" · "+ref.year).font(.system(size:10)).foregroundStyle(.secondary) }
                        }
                    }
                }.padding(4)
            }.frame(height:220)
            HStack { TextField("Page / locator",text:$locator).textFieldStyle(.roundedBorder); Picker("Form",selection:$form) { Text("Normal").tag("normal"); Text("Prose").tag("prose"); Text("Author").tag("author"); Text("Year").tag("year") }.frame(width:210) }
            Text("Keep Zotero open with Settings → Advanced → Allow other applications on this computer to communicate with Zotero enabled.").font(.system(size:11)).foregroundStyle(.secondary)
        }
    }
    func searchZotero() {
        finding = true; failure = ""
        ZoteroIntegration.search(query:text,library:library) { result in finding = false; switch result { case let .success(items): refs = items; case let .failure(error): failure = error.localizedDescription } }
    }
    func insert() {
        switch session.insertionKind {
        case "table":
            let cells = (0..<rows*columns).map { "  [\($0 < columns ? "Column \($0+1)" : "")]," }.joined(separator:"\n")
            session.insertSource("#table(columns: \(columns),\n\(cells)\n)",block:true)
        case "image": session.insertSource("#figure(image(\(jsonString(text)), width: \(imageWidth)%, alt: \(jsonString(alt))), caption: [\(escapeTypst(extra))])",block:true)
        case "equation": session.insertSource("$ \(text) $",block:true)
        case "footnote": session.insertSource("#footnote[\(escapeTypst(text))]")
        case "link": session.insertSource("#link(\(jsonString(text)))[\(escapeTypst(extra.isEmpty ? text : extra))]")
        case "label": session.insertSource("<\(safeLabel(text))>")
        case "reference": session.insertSource("@\(safeLabel(text))")
        case "citation":
            finding = true
            ZoteroIntegration.insert(refs.filter { selected.contains($0.key) },session:session,anchor:session.insertionAnchor,locator:locator,form:form) { error in finding = false; if let error { failure = error.localizedDescription } else { session.sheet = nil } }
        case "bibliography":
            let buffer = session.buffers[session.entry]!, original = buffer.source
            let regex = try! NSRegularExpression(pattern:"(#bibliography\\([^\\n]*style:\\s*)\"[^\"]*\"")
            let replaced = regex.stringByReplacingMatches(in:original,range:NSRange(location:0,length:original.utf16.count),withTemplate:"$1\"\(text)\"")
            if replaced != original { buffer.commit(replaced,selection:buffer.selection); session.changed(); session.sheet = nil }
            else { failure = "No bibliography style was found. Add #bibliography in Source first." }
        default: break
        }
    }
}
func jsonString(_ text: String) -> String { String(data:try! JSONEncoder().encode(text),encoding:.utf8)! }
func safeLabel(_ text: String) -> String { text.filter { $0.isLetter || $0.isNumber || "-_:.".contains($0) } }
struct ObjectSheet: View {
    @ObservedObject var session: DocumentSession
    @NativeState var raw = ""
    @NativeState var cells: [String] = []
    @NativeState var columns = 0
    @NativeState var originalCells: [String] = []
    @NativeState var originalColumns = 0
    var block: ProjectedBlock { session.buffer.projection.blocks[min(session.objectIndex,session.buffer.projection.blocks.count-1)] }
    var body: some View {
        SheetFrame(title:block.kind == "table" && columns > 0 ? "Edit table" : "Edit \(block.kind)",width:620,dismiss:{ session.sheet = nil }) {
            if block.kind == "table" && columns > 0 {
                ScrollView {
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:columns),spacing:9) {
                        ForEach(cells.indices,id:\.self) { index in TextField("Cell",text:$cells[index],axis:.vertical).textFieldStyle(.roundedBorder).lineLimit(1...4) }
                    }
                }.frame(maxHeight:300)
                HStack {
                    Button("Add row") { cells += Array(repeating:"",count:columns) }
                    Button("Remove row") { if cells.count > columns { cells.removeLast(columns) } }.disabled(cells.count <= columns)
                    Spacer()
                    Button("Add column") { var next: [String] = []; for row in stride(from:0,to:cells.count,by:columns) { next += Array(cells[row..<min(row+columns,cells.count)])+[""] }; cells = next; columns += 1 }.disabled(columns >= 12)
                    Button("Remove column") { if columns > 1 { cells = cells.enumerated().filter { $0.offset % columns != columns-1 }.map(\.element); columns -= 1 } }.disabled(columns <= 1)
                }.controlSize(.small)
            } else {
                TextEditor(text:$raw).font(.system(size:13,design:.monospaced)).frame(height:260).border(Color.primary.opacity(0.1))
                Text("Every character is preserved. Preview shows the typeset result.").font(.system(size:11)).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Cancel") { session.sheet = nil }.keyboardShortcut(.cancelAction); Button("Apply") { apply() }.keyboardShortcut(.defaultAction) }
        }.onAppear {
            raw = session.buffer.source.bytes(block.source); columns = block.columns
            cells = block.tableCells.map { session.buffer.source.bytes($0) }; originalCells = cells; originalColumns = columns
        }
    }
    func apply() {
        let buffer = session.buffer, b = block
        var text = buffer.source
        if b.kind == "table" && columns > 0 {
            if cells.count == originalCells.count && columns == originalColumns {
                for index in cells.indices.reversed() where cells[index] != originalCells[index] { text = text.replacingBytes(b.tableCells[index],with:cells[index]) }
            } else {
                // Keep named table options when changing dimensions.
                let parsed = ParsedSource.parse(raw)
                let named = parsed.tree.descendants("Named").filter { !raw.bytes($0.span).hasPrefix("columns:") }.map { "  "+raw.bytes($0.span)+"," }.joined(separator:"\n")
                let content = cells.map { "  [\($0)]," }.joined(separator:"\n")
                let replacement = "#table(columns: \(columns),\n\(named)\n\(content)\n)"
                text = text.replacingBytes(b.source,with:replacement)
            }
        } else { text = text.replacingBytes(b.source,with:raw) }
        buffer.commit(text,selection:buffer.selection); session.changed(); session.sheet = nil
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
                    session.persistRecovery()
                    for (path,text) in session.conflictDisk {
                        if session.deletedFiles.contains(path) {
                            if path == session.entry { session.root = nil; session.buffers[path]?.loadExternal(""); session.bases.removeAll() }
                            else { session.buffers.removeValue(forKey:path); session.bases.removeValue(forKey:path); if session.active == path { session.active = session.entry } }
                        } else { session.buffers[path]?.loadExternal(text); session.bases[path] = text }
                    }
                    session.deletedFiles.removeAll()
                    session.conflictDisk.removeAll(); session.sheet = nil; session.error = nil; session.revision += 1; session.editor?.refresh()
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
