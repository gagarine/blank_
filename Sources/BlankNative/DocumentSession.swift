import AppKit
import SwiftUI
import PDFKit
import BlankCore

enum EditorMode: String, CaseIterable { case write = "Write", source = "Source", preview = "Preview" }
enum SheetKind: String, Identifiable { case commands, settings, statistics, insertion, object, conflict, rename; var id: String { rawValue } }
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
    @Published var sidebarDragging = false
    func toggleSidebar() { sidebarHover = false; sidebar.toggle() }
    @Published var revision = 0
    @Published var dirty = false
    @Published var error: String?
    @Published var sheet: SheetKind?
    @Published var commandQuery = ""
    @Published var searchVisible = false
    @Published var searchQuery = ""
    @Published var replaceText = ""
    @Published var caseSensitive = false
    @Published var projectSearch = false
    @Published var compiling = false
    @Published var pdf: PDFDocument?
    @Published var previewPage = 1
    @Published var paragraphFocus = false
    @Published var typewriter = false
    @Published var fontFamily: String = EditorPreferences.preferredEditorFamily
    @Published var fontSize: Double = UserDefaults.standard.object(forKey:"readingSize") as? Double ?? 18
    @Published var paper: Color = EditorPreferences.color("paper",fallback:.white)
    @Published var ink: Color = EditorPreferences.color("ink",fallback:NSColor(calibratedWhite:0.20,alpha:1))
    @Published var systemColors = EditorPreferences.usesSystemColors
    var paperColor: NSColor { systemColors ? .textBackgroundColor : NSColor(paper) }
    var inkColor: NSColor { systemColors ? .labelColor : NSColor(ink) }
    @Published var dark = UserDefaults.standard.bool(forKey:"dark")
    var buffers: [String:DocumentBuffer] = ["Untitled.typ":DocumentBuffer()]
    var bases: [String:String] = [:]
    var assets: [String:Data] = [:]
    var root: URL?
    var entry = "Untitled.typ"
    var conflictDisk: [String:String] = [:]
    var deletedFiles = Set<String>()
    var buffer: DocumentBuffer { buffers[active]! }
    var title: String { entry.replacingOccurrences(of:".typ",with:"") }
    var onTitle: (() -> Void)?
    weak var editor: NativeTextView?
    weak var pdfView: PDFView?
    weak var window: NSWindow?
    let compiler = TypstCompiler()
    var compileRevision = -1
    var pendingExport: (URL,Int)?
    var sourceMap: [[String:Any]] = []
    var insertionKind = "footnote"
    var insertionAnchor = EditSelection(0,0)
    var objectIndex = 0
    var saveWork: DispatchWorkItem?
    var diskScanWork: DispatchWorkItem?
    var projectUndoPath: String?
    var watch: DispatchSourceFileSystemObject?
    var watchers: [DispatchSourceFileSystemObject] = []
    var writing = false
    let recoveryQueue = DispatchQueue(label:"blank.recovery",qos:.utility)
    var recoveryURL: URL {
        AppController.dataDirectory.appendingPathComponent("recovery/\(id).json")
    }
    var includes: [String] {
        var ordered: [String] = [], seen = Set<String>()
        func visit(_ path: String) {
            guard let model = buffers[path], !seen.contains(path) else { return }; seen.insert(path); ordered.append(path)
            for include in model.includes { if let next = projectAssetPath(include.path,file:path) { visit(next) } }
        }
        visit(entry)
        return ordered
    }
    var headings: [(Int, ProjectedBlock)] {
        buffer.projection.blocks.enumerated().filter { $0.element.kind == "heading" }.map { ($0.offset,$0.element) }
    }
    func changed() {
        projectUndoPath = nil
        if !buffer.lastEditWasLocal { refreshIncludes() }
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
        if mode == .preview { capturePreviewPosition() } else { editor?.captureReadingPosition() }
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
        let projectPath = projectUndoPath, model = projectPath.flatMap { buffers[$0] } ?? buffer
        editor?.finishComposition(); if redo { model.redo() } else { model.undo() }; changed(); projectUndoPath = projectPath; editor?.refresh(reveal:true)
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
        if directory.boolValue, let data = try? Data(contentsOf:project.appendingPathComponent("writer.json")), let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let configured = json["entry"] as? String { file = configured }
        var loaded: [String:DocumentBuffer] = [:]
        var seen = Set<String>()
        func visit(_ path: String) throws {
            guard !seen.contains(path) else { return }; seen.insert(path)
            let target = project.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard target.path.hasPrefix(project.resolvingSymlinksInPath().path+"/") else { throw CocoaError(.fileReadNoPermission) }
            let text = try String(contentsOf:target,encoding:.utf8); loaded[path] = DocumentBuffer(text)
            for include in loaded[path]!.includes+loaded[path]!.imports where !include.path.hasPrefix("@") {
                let child = include.path
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
        // Directory events cover atomic file replacement and newly created
        // included chapters without an idle polling timer.
        let directories = Set([root]+buffers.keys.map { root.appendingPathComponent($0).deletingLastPathComponent() })
        for directory in directories {
            let fd = Darwin.open(directory.path,O_EVTONLY); guard fd >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete],queue:.main)
            watcher.setEventHandler { [weak self] in
                self?.diskScanWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.refreshIncludes()
                    for path in Array(self.buffers.keys) { self.checkDisk(path,reinstall:false) }
                    self.installWatchers()
                }
                self?.diskScanWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
            }
            watcher.setCancelHandler { Darwin.close(fd) }; watcher.resume(); watchers.append(watcher)
        }
    }
    func checkDisk(_ path: String,reinstall: Bool = true) {
        guard let root, let local = buffers[path], let base = bases[path] else { return }
        let target = root.appendingPathComponent(path)
        guard let disk = try? String(contentsOf:target,encoding:.utf8) else {
            if !FileManager.default.fileExists(atPath:target.path) { deletedFiles.insert(path); conflictDisk[path] = ""; error = "\(path) was deleted outside blank_. Your writing is retained in recovery."; sheet = .conflict; persistRecovery() }
            else { error = "Could not read \(path) as UTF-8. Saving is blocked until the file can be read; your local writing is retained in recovery."; persistRecovery() }
            return
        }
        guard disk != base else { if reinstall { installWatchers() }; return }
        if disk == local.source { bases[path] = disk; return }
        if local.source == base {
            local.loadExternal(disk); bases[path] = disk; refreshIncludes(); revision += 1; editor?.refresh()
        } else { conflictDisk[path] = disk; error = "\(path) changed outside blank_. Choose which version to keep before saving."; sheet = .conflict }
        if reinstall { installWatchers() }
    }
    func autosave() {
        persistRecovery()
        if root != nil { do { try saveToDisk() } catch { self.error = error.localizedDescription } }
    }
    func persistRecovery() {
        let payload = Recovery(id:id,entry:entry,root:root?.path,files:buffers.mapValues(\.source),assets:assets)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let target = recoveryURL
        recoveryQueue.async {
            do { try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true); try data.write(to:target,options:.atomic) } catch { NSLog("Recovery: %@",error.localizedDescription) }
        }
    }
    func ensureRecovery() -> Bool {
        do {
            let payload = Recovery(id:id,entry:entry,root:root?.path,files:buffers.mapValues(\.source),assets:assets), data = try JSONEncoder().encode(payload), target = recoveryURL
            try recoveryQueue.sync { try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true); try data.write(to:target,options:.atomic) }
            return true
        } catch { self.error = "Recovery could not be saved: "+error.localizedDescription; return false }
    }
    @discardableResult func useDiskVersion() -> Bool {
        editor?.finishComposition()
        // Keep the discarded local revision independently of the rolling journal.
        // Later autosaves and termination must not replace this conflict copy.
        let archive = recoveryURL.deletingLastPathComponent().appendingPathComponent("\(id)-conflict-\(UUID().uuidString).json")
        do {
            let payload = Recovery(id:id,entry:entry,root:root?.path,files:buffers.mapValues(\.source),assets:assets)
            let data = try JSONEncoder().encode(payload)
            try recoveryQueue.sync { try FileManager.default.createDirectory(at:archive.deletingLastPathComponent(),withIntermediateDirectories:true); try data.write(to:archive,options:.atomic) }
        } catch { self.error = "Local writing could not be preserved: "+error.localizedDescription; return false }
        for (path,text) in conflictDisk {
            if deletedFiles.contains(path) {
                if path == entry { root = nil; buffers[path]?.loadExternal(""); bases.removeAll() }
                else { buffers.removeValue(forKey:path); bases.removeValue(forKey:path); if active == path { active = entry } }
            } else { buffers[path]?.loadExternal(text); bases[path] = text }
        }
        deletedFiles.removeAll(); conflictDisk.removeAll(); sheet = nil; error = nil
        refreshIncludes(); revision += 1; editor?.refresh(); onTitle?()
        return true
    }
    func save(_ saveAs: Bool = false, completion: ((Bool)->Void)? = nil) {
        editor?.finishComposition()
        if root != nil && !saveAs { do { try saveToDisk(); completion?(true) } catch { self.error = error.localizedDescription; completion?(false) }; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.init(filenameExtension:"typ")!]; panel.nameFieldStringValue = entry; panel.title = "Save Document"
        guard let window else { completion?(false); return }
        panel.beginSheetModal(for:window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { completion?(false); return }
            do {
                try self.saveCopy(to:url); completion?(true)
            } catch { self.error = error.localizedDescription; completion?(false) }
        }
    }
    static func writeDependency(_ data: Data,path: String,root: URL) throws {
        let target = try dependencyTarget(path,root:root)
        if FileManager.default.fileExists(atPath:target.path) {
            if try Data(contentsOf:target) == data { return }
            throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"\(path) already exists with different content. Choose an empty folder."])
        }
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:target,options:.atomic)
    }
    static func dependencyTarget(_ path: String,root: URL) throws -> URL {
        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path+"/") else { throw CocoaError(.fileWriteNoPermission) }
        return target
    }
    func referencedAssets() -> Set<String> {
        var result = Set<String>()
        let manuscript = Set(includes)
        for (file,buffer) in buffers where file.lowercased().hasSuffix(".typ") || manuscript.contains(file) {
            for literal in literalAssetPaths(buffer.source,buffer.parsed) {
                if let path = projectAssetPath(literal,file:file) { result.insert(path) }
            }
        }
        return result
    }
    func saveToDisk() throws {
        guard let root else { return }
        guard conflictDisk.isEmpty else { throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"Resolve external changes before saving."]) }
        // Preflight every source before replacing any file.
        for (path,buffer) in buffers {
            let target = try Self.dependencyTarget(path,root:root)
            if bases[path] != nil && !FileManager.default.fileExists(atPath:target.path) {
                checkDisk(path); throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"A project file was deleted. Resolve the change before saving."])
            }
            if FileManager.default.fileExists(atPath:target.path) {
                let disk: String
                do { disk = try String(contentsOf:target,encoding:.utf8) }
                catch { persistRecovery(); throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"Could not read \(path) as UTF-8. The file has not been overwritten; your local writing is retained in recovery.",NSUnderlyingErrorKey:error]) }
                if disk != bases[path] && disk != buffer.source {
                    checkDisk(path); persistRecovery(); throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"External changes detected in \(path). Your local writing is retained in recovery."])
                }
            }
        }
        for (path,data) in assets {
            let target = try Self.dependencyTarget(path,root:root)
            if FileManager.default.fileExists(atPath:target.path), try Data(contentsOf:target) != data { throw CocoaError(.fileWriteFileExists) }
        }
        for (path,buffer) in buffers {
            let target = try Self.dependencyTarget(path,root:root)
            if bases[path] != buffer.source {
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data(buffer.source.utf8).write(to:target,options:.atomic); bases[path] = buffer.source
            }
        }
        for (path,data) in assets { try Self.writeDependency(data,path:path,root:root) }
        dirty = false; onTitle?(); installWatchers()
    }
    func compile(export: URL? = nil) {
        guard !compiling else {
            if let export {
                if pendingExport == nil { pendingExport = (export,revision) }
                else { error = "A PDF export is already waiting for compilation to finish." }
            }
            return
        }
        if compileRevision == revision, export == nil, pdf != nil { return }
        compiling = true
        let snapshot = buffers.mapValues(\.source), current = revision
        let directory = root ?? AppController.dataDirectory.appendingPathComponent("drafts/\(id)")
        do { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); for (path,data) in assets { try Self.writeDependency(data,path:path,root:directory) } }
        catch { self.error = error.localizedDescription; compiling = false; return }
        compiler.compile(root:directory,entry:entry,files:snapshot,revision:current) { [weak self] response in
            guard let self else { return }; self.compiling = false
            defer {
                if let (url,requestedRevision) = self.pendingExport {
                    self.pendingExport = nil
                    if requestedRevision == self.revision { self.compile(export:url) }
                    else { self.error = "Document changed while waiting to export. Try again." }
                }
            }
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
    func goPage(_ page: Int) {
        guard let pdf, let target = pdf.page(at:page-1) else { return }
        previewPage = page; pdfView?.go(to:target)
    }
    func capturePreviewPosition() {
        guard let view = pdfView, let page = view.currentPage, let document = view.document else { return }
        let number = document.index(for:page)+1
        previewPage = number
        let point = view.currentDestination?.point ?? NSPoint(x:0,y:page.bounds(for:.mediaBox).height)
        let height = page.bounds(for:.mediaBox).height, y = max(0,min(1,1-point.y/height))
        if let anchor = sourceMap.filter({ ($0["page"] as? Int) == number }).min(by:{ abs(($0["y"] as? Double ?? 0)-y) < abs(($1["y"] as? Double ?? 0)-y) }), let path = anchor["path"] as? String, let start = anchor["start"] as? Int, let buffer = buffers[path] {
            active = path; buffer.selection = EditSelection(start,start)
        }
    }
    func exportPDF() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = title+".pdf"; panel.title = "Export PDF"
        guard let window else { return }
        panel.beginSheetModal(for:window) { [weak self] result in if result == .OK, let url = panel.url { self?.compile(export:url) } }
    }
    func find(next: Bool = true) {
        guard !searchQuery.isEmpty, let editor else { return }
        if projectSearch { findInProject(next:next); return }
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        let start = next ? NSMaxRange(selection) : selection.location
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let range = next ? NSRange(location:min(start,text.length),length:max(0,text.length-start)) : NSRange(location:0,length:start)
        var match = text.range(of:searchQuery,options:next ? options : options.union(.backwards),range:range)
        if match.location == NSNotFound { match = text.range(of:searchQuery,options:next ? options : options.union(.backwards)) }
        if match.location != NSNotFound { editor.setSelectedRange(match); editor.scrollRangeToVisible(match); editor.captureSelection() }
    }
    func findInProject(next: Bool) {
        guard let editor, let initial = includes.firstIndex(of:active) else { return }
        let paths = includes, selection = editor.selectedRange(), options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        for step in 0...paths.count {
            let index = (initial+(next ? step : -step)+paths.count)%paths.count, path = paths[index], model = buffers[path]!
            let text = (mode == .source ? model.source : model.projection.text) as NSString
            let at = min(text.length,next ? NSMaxRange(selection) : selection.location)
            let range: NSRange
            if step == 0 { range = next ? NSRange(location:at,length:text.length-at) : NSRange(location:0,length:at) }
            else if step == paths.count { range = next ? NSRange(location:0,length:at) : NSRange(location:at,length:text.length-at) }
            else { range = NSRange(location:0,length:text.length) }
            let match = text.range(of:searchQuery,options:next ? options : options.union(.backwards),range:range)
            if match.location != NSNotFound {
                switchFile(path)
                model.selection = mode == .source ? EditSelection(model.source.byteOffset(utf16:match.location),model.source.byteOffset(utf16:NSMaxRange(match))) : EditSelection(model.projection.sourceOffset(at:match.location),model.projection.sourceOffset(at:NSMaxRange(match)))
                self.editor?.refresh(reveal:true); return
            }
        }
    }
    func replace(all: Bool = false) {
        guard let editor, !searchQuery.isEmpty else { return }
        if !all { editor.insertText(replaceText,replacementRange:editor.selectedRange()); find(); return }
        let paths = projectSearch ? includes : [active]
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        for path in paths {
            let model = buffers[path]!, copy = DocumentBuffer(model.source), original = (mode == .source ? model.source : model.projection.text) as NSString
            var matches: [NSRange] = [], at = 0
            while at < original.length {
                let m = original.range(of:searchQuery,options:options,range:NSRange(location:at,length:original.length-at))
                if m.location == NSNotFound { break }; matches.append(m); at = NSMaxRange(m)
            }
            for m in matches.reversed() { if mode == .source { copy.editSource(m,text:replaceText) } else { copy.editWrite(m,text:replaceText) } }
            model.breakUndoGroup(); model.commit(copy.source,selection:model.selection)
        }
        changed()
    }
    func insertSource(_ text: String, block: Bool = false) {
        let span = insertionAnchor.span
        let insert = block ? "\n\n"+text+"\n\n" : text
        buffer.commit(buffer.source.replacingBytes(span,with:insert),selection:EditSelection(span.start+insert.utf8.count,span.start+insert.utf8.count)); changed(); sheet = nil
    }
    func chooseInsertion(_ kind: String) {
        synchronizeSelection(); insertionAnchor = buffer.selection
        if kind == "table" {
            let start = insertionAnchor.span.start+2
            insertSource("#table(columns: 2,\n  [], [],\n  [], [],\n)",block:true)
            if let index = buffer.projection.blocks.firstIndex(where:{ $0.kind == "table" && $0.source.start == start }) { editor?.focusTableCell(index,0) }
            return
        }
        insertionKind = kind; sheet = .insertion
    }
    func editObject(_ index: Int) { objectIndex = index; sheet = .object }
    func importImage(_ url: URL) throws -> String {
        let data = try Data(contentsOf:url)
        let path = "assets/\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
        assets[path] = data
        if let root { try Self.writeDependency(data,path:path,root:root) }
        return relativeAssetPath(path)
    }
}
