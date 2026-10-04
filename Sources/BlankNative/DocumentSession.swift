import AppKit
import SwiftUI
import PDFKit
import BlankCore

enum EditorMode: String, CaseIterable { case write = "Write", source = "Source", preview = "Preview" }
enum SheetKind: String, Identifiable { case commands, settings, statistics, insertion, object, conflict; var id: String { rawValue } }
struct Recovery: Codable {
    var id: String
    var entry: String
    var root: String?
    var files: [String:String]
    var assets: [String:Data]
}
@MainActor final class DocumentSession: ObservableObject {
    let id = UUID().uuidString
    @Published var mode: EditorMode = .write
    @Published var active = "Untitled.typ"
    @Published var sidebar = false
    @Published var sidebarHover = false
    @Published var revision = 0
    @Published var dirty = false
    @Published var error: String?
    @Published var sheet: SheetKind?
    @Published var commandQuery = ""
    @Published var searchVisible = false
    @Published var searchQuery = ""
    @Published var replaceText = ""
    @Published var caseSensitive = false
    @Published var compiling = false
    @Published var pdf: PDFDocument?
    @Published var previewPage = 1
    @Published var paragraphFocus = false
    @Published var typewriter = false
    @Published var fontFamily: String = UserDefaults.standard.string(forKey:"readingFont") ?? "Iowan Old Style"
    @Published var fontSize: Double = UserDefaults.standard.object(forKey:"readingSize") as? Double ?? 18
    @Published var paper: Color = .white
    @Published var ink: Color = Color(nsColor:NSColor(calibratedWhite:0.20,alpha:1))
    var buffers: [String:DocumentBuffer] = ["Untitled.typ":DocumentBuffer()]
    var bases: [String:String] = [:]
    var assets: [String:Data] = [:]
    var root: URL?
    var entry = "Untitled.typ"
    var conflictDisk: [String:String] = [:]
    var buffer: DocumentBuffer { buffers[active]! }
    var title: String { entry.replacingOccurrences(of:".typ",with:"") }
    var onTitle: (() -> Void)?
    weak var editor: NativeTextView?
    weak var pdfView: PDFView?
    weak var window: NSWindow?
    let compiler = TypstCompiler()
    var compileRevision = -1
    var sourceMap: [[String:Any]] = []
    var insertionKind = "footnote"
    var insertionAnchor = EditSelection(0,0)
    var objectIndex = 0
    var saveWork: DispatchWorkItem?
    var watch: DispatchSourceFileSystemObject?
    var watchers: [DispatchSourceFileSystemObject] = []
    var writing = false
    var recoveryURL: URL {
        AppController.dataDirectory.appendingPathComponent("recovery/\(id).json")
    }
    var includes: [String] {
        buffers.keys.filter { $0.hasSuffix(".typ") }.sorted { $0 == entry || ($1 != entry && $0 < $1) }
    }
    var headings: [(Int, ProjectedBlock)] {
        buffer.projection.blocks.enumerated().filter { $0.element.kind == "heading" }.map { ($0.offset,$0.element) }
    }
    func changed() {
        revision += 1; dirty = true; error = nil; editor?.refresh(); onTitle?()
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autosave() }
        saveWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.65,execute:work)
        if mode == .preview { compile() }
    }
    func synchronizeSelection() { editor?.captureSelection() }
    func switchMode(_ next: EditorMode) {
        guard next != mode else { return }
        editor?.finishComposition()
        editor?.captureReadingPosition()
        buffer.breakUndoGroup(); mode = next
        if next == .preview { compile() }
        else { DispatchQueue.main.async { [weak self] in self?.editor?.refresh(reveal:true); self?.window?.makeFirstResponder(self?.editor) } }
    }
    func switchFile(_ path: String) {
        guard buffers[path] != nil, path != active else { return }
        editor?.finishComposition(); synchronizeSelection(); buffer.breakUndoGroup(); active = path; revision += 1
        editor?.refresh(reveal:true)
    }
    func undo(_ redo: Bool = false) {
        editor?.finishComposition(); if redo { buffer.redo() } else { buffer.undo() }; changed(); editor?.refresh(reveal:true)
    }
    func format(italic: Bool) {
        guard mode == .write else { return }; synchronizeSelection()
        if let editor { buffer.format(editor.selectedRange(),italic:italic); changed() }
    }
    func open(_ url: URL) throws {
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard fm.fileExists(atPath:url.path,isDirectory:&directory) else { throw CocoaError(.fileNoSuchFile) }
        let project = directory.boolValue ? url : url.deletingLastPathComponent()
        var file = directory.boolValue ? "main.typ" : url.lastPathComponent
        if directory.boolValue, let data = try? Data(contentsOf:project.appendingPathComponent("writer.json")), let json = try? JSONSerialization.jsonObject(with:data) as? [String:String], let configured = json["entry"] { file = configured }
        var loaded: [String:DocumentBuffer] = [:]
        var seen = Set<String>()
        func visit(_ path: String) throws {
            guard !seen.contains(path) else { return }; seen.insert(path)
            let target = project.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard target.path.hasPrefix(project.resolvingSymlinksInPath().path+"/") else { throw CocoaError(.fileReadNoPermission) }
            let text = try String(contentsOf:target,encoding:.utf8); loaded[path] = DocumentBuffer(text)
            let regex = try NSRegularExpression(pattern:"(?m)#include\\s+\"([^\"\\n]+)\"")
            for match in regex.matches(in:text,range:NSRange(location:0,length:text.utf16.count)) {
                let child = (text as NSString).substring(with:match.range(at:1))
                let absolute = target.deletingLastPathComponent().appendingPathComponent(child).standardizedFileURL
                guard absolute.path.hasPrefix(project.standardizedFileURL.path+"/") else { continue }
                let relative = String(absolute.path.dropFirst(project.standardizedFileURL.path.count+1))
                if fm.fileExists(atPath:absolute.path) { try visit(relative) }
            }
        }
        try visit(file)
        for name in ["writer-zotero.bib","writer-references.json"] {
            if let text = try? String(contentsOf:project.appendingPathComponent(name),encoding:.utf8) { loaded[name] = DocumentBuffer(text) }
        }
        root = project; entry = file; active = file; buffers = loaded; bases = loaded.mapValues(\.source); dirty = false
        revision += 1; installWatchers(); onTitle?()
    }
    func installWatchers() {
        watchers.forEach { $0.cancel() }; watchers.removeAll()
        guard let root else { return }
        for path in buffers.keys {
            let fd = Darwin.open(root.appendingPathComponent(path).path,O_EVTONLY)
            guard fd >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete],queue:.main)
            watcher.setEventHandler { [weak self] in self?.checkDisk(path) }
            watcher.setCancelHandler { Darwin.close(fd) }; watcher.resume(); watchers.append(watcher)
        }
    }
    func checkDisk(_ path: String) {
        guard let root, let local = buffers[path], let base = bases[path], let disk = try? String(contentsOf:root.appendingPathComponent(path),encoding:.utf8), disk != base else { return }
        if disk == local.source { bases[path] = disk; return }
        if local.source == base {
            local.loadExternal(disk); bases[path] = disk; revision += 1; editor?.refresh()
        } else { conflictDisk[path] = disk; error = "\(path) changed outside blank_. Choose which version to keep before saving."; sheet = .conflict }
    }
    func autosave() {
        persistRecovery()
        if root != nil { do { try saveToDisk() } catch { self.error = error.localizedDescription } }
    }
    func persistRecovery() {
        let payload = Recovery(id:id,entry:entry,root:root?.path,files:buffers.mapValues(\.source),assets:assets)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let target = recoveryURL
        DispatchQueue.global(qos:.utility).async {
            do { try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true); try data.write(to:target,options:.atomic) } catch { NSLog("Recovery: %@",error.localizedDescription) }
        }
    }
    func save(_ saveAs: Bool = false, completion: ((Bool)->Void)? = nil) {
        editor?.finishComposition()
        if root != nil && !saveAs { do { try saveToDisk(); completion?(true) } catch { self.error = error.localizedDescription; completion?(false) }; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.init(filenameExtension:"typ")!]; panel.nameFieldStringValue = entry; panel.title = "Save Document"
        guard let window else { completion?(false); return }
        panel.beginSheetModal(for:window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { completion?(false); return }
            do {
                let newRoot = url.deletingLastPathComponent(), oldRoot = self.root
                // Copy dependency/asset files without replacing unrelated destination files.
                for (path,data) in self.assets { try Self.writeDependency(data,path:path,root:newRoot) }
                if let oldRoot {
                    let paths = self.referencedAssets()
                    for path in paths { if let data = try? Data(contentsOf:oldRoot.appendingPathComponent(path)) { try Self.writeDependency(data,path:path,root:newRoot) } }
                }
                for (path,buffer) in self.buffers where path != self.entry { try Self.writeDependency(Data(buffer.source.utf8),path:path,root:newRoot) }
                try Data(self.buffers[self.entry]!.source.utf8).write(to:url,options:.atomic)
                let oldEntry = self.entry
                self.buffers[url.lastPathComponent] = self.buffers.removeValue(forKey:oldEntry)
                if self.active == oldEntry { self.active = url.lastPathComponent }
                self.entry = url.lastPathComponent; self.root = newRoot; self.bases = self.buffers.mapValues(\.source); self.dirty = false
                self.installWatchers(); self.onTitle?(); self.persistRecovery(); completion?(true)
            } catch { self.error = error.localizedDescription; completion?(false) }
        }
    }
    static func writeDependency(_ data: Data,path: String,root: URL) throws {
        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.path.hasPrefix(root.standardizedFileURL.path+"/") else { throw CocoaError(.fileWriteNoPermission) }
        if FileManager.default.fileExists(atPath:target.path) {
            if try Data(contentsOf:target) == data { return }
            throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"\(path) already exists with different content. Choose an empty folder."])
        }
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:target,options:.atomic)
    }
    func referencedAssets() -> Set<String> {
        var result = Set<String>()
        let regex = try! NSRegularExpression(pattern:"#?(?:image|bibliography|read)\\(\\s*\"([^\"]+)\"")
        for buffer in buffers.values {
            for m in regex.matches(in:buffer.source,range:NSRange(location:0,length:buffer.source.utf16.count)) { result.insert((buffer.source as NSString).substring(with:m.range(at:1))) }
        }
        return result
    }
    func saveToDisk() throws {
        guard let root else { return }
        guard conflictDisk.isEmpty else { throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"Resolve external changes before saving."]) }
        for (path,buffer) in buffers {
            let target = root.appendingPathComponent(path)
            if let disk = try? String(contentsOf:target,encoding:.utf8), let base = bases[path], disk != base && disk != buffer.source {
                checkDisk(path); throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"External changes detected. Your local recovery copy is safe."])
            }
            if bases[path] != buffer.source {
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data(buffer.source.utf8).write(to:target,options:.atomic); bases[path] = buffer.source
            }
        }
        for (path,data) in assets { try Self.writeDependency(data,path:path,root:root) }
        dirty = false; onTitle?(); installWatchers()
    }
    func compile(export: URL? = nil) {
        guard !compiling else { return }
        if compileRevision == revision, export == nil, pdf != nil { return }
        compiling = true
        let snapshot = buffers.mapValues(\.source), current = revision
        let directory = root ?? AppController.dataDirectory.appendingPathComponent("drafts/\(id)")
        do { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); for (path,data) in assets { try Self.writeDependency(data,path:path,root:directory) } }
        catch { self.error = error.localizedDescription; compiling = false; return }
        compiler.compile(root:directory,entry:entry,files:snapshot,revision:current) { [weak self] response in
            guard let self else { return }; self.compiling = false
            switch response {
            case let .success(result):
                if result.revision != self.revision { if export != nil { self.error = "Document changed during export. Try again." }; if self.mode == .preview { self.compile() }; return }
                if let data = result.data, let document = PDFDocument(data:data) {
                    self.pdf = document; self.compileRevision = current; self.sourceMap = result.map; self.error = nil
                    if let export { do { try data.write(to:export,options:.atomic) } catch { self.error = error.localizedDescription } }
                } else { self.error = result.diagnostics.joined(separator:"\n") }
            case let .failure(error): self.error = error.localizedDescription
            }
        }
    }
    func exportPDF() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = title+".pdf"; panel.title = "Export PDF"
        guard let window else { return }
        panel.beginSheetModal(for:window) { [weak self] result in if result == .OK, let url = panel.url { self?.compile(export:url) } }
    }
    func find(next: Bool = true) {
        guard !searchQuery.isEmpty, let editor else { return }
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        let start = next ? NSMaxRange(selection) : selection.location
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let range = next ? NSRange(location:min(start,text.length),length:max(0,text.length-start)) : NSRange(location:0,length:start)
        var match = text.range(of:searchQuery,options:next ? options : options.union(.backwards),range:range)
        if match.location == NSNotFound { match = text.range(of:searchQuery,options:next ? options : options.union(.backwards)) }
        if match.location != NSNotFound { editor.setSelectedRange(match); editor.scrollRangeToVisible(match); editor.captureSelection() }
    }
    func replace(all: Bool = false) {
        guard let editor, !searchQuery.isEmpty else { return }
        if !all { editor.insertText(replaceText,replacementRange:editor.selectedRange()); find(); return }
        let original = editor.string as NSString
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var matches: [NSRange] = [], at = 0
        while at < original.length {
            let m = original.range(of:searchQuery,options:options,range:NSRange(location:at,length:original.length-at))
            if m.location == NSNotFound { break }; matches.append(m); at = NSMaxRange(m)
        }
        buffer.breakUndoGroup()
        for m in matches.reversed() { if mode == .source { buffer.editSource(m,text:replaceText,group:"replace") } else { buffer.editWrite(m,text:replaceText,group:"replace") } }
        changed()
    }
    func insertSource(_ text: String, block: Bool = false) {
        let span = insertionAnchor.span
        let insert = block ? "\n\n"+text+"\n\n" : text
        buffer.commit(buffer.source.replacingBytes(span,with:insert),selection:EditSelection(span.start+insert.utf8.count,span.start+insert.utf8.count)); changed(); sheet = nil
    }
    func chooseInsertion(_ kind: String) {
        synchronizeSelection(); insertionAnchor = buffer.selection; insertionKind = kind; sheet = .insertion
    }
    func editObject(_ index: Int) { objectIndex = index; sheet = .object }
    func importImage(_ url: URL) throws -> String {
        let data = try Data(contentsOf:url)
        let path = "assets/\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
        assets[path] = data
        if let root { try Self.writeDependency(data,path:path,root:root) }
        return path
    }
}
