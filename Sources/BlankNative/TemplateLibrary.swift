import AppKit
import PDFKit
import BlankCore
import CryptoKit

extension Notification.Name { static let blankDocumentSaved = Notification.Name("blankDocumentSaved") }

struct DocumentTemplate: Identifiable, Equatable {
    let id: String
    let entry: String
    let version: String
    var name: String { (entry as NSString).deletingPathExtension }
    var cacheKey: NSString { (id+"/"+version) as NSString }
}

// Templates are ordinary, self-contained Typst projects. writer.json is the
// same entry manifest already maintained by native rename/save operations.
@MainActor final class TemplateLibrary: ObservableObject {
    static let starterNames = ["Standard","Thesis","Paper","Letter A4","Book"]
    let root: URL
    @Published private(set) var templates: [DocumentTemplate] = []
    @Published var selection: String?
    @Published private(set) var generation = 0
    @Published private(set) var renderErrors: [String:String] = [:]
    private let images = NSCache<NSString,NSImage>()
    private let pdfs = NSCache<NSString,NSData>()
    private var requested: [String:String] = [:]
    private var failedVersions: [String:String] = [:]
    private var pending = 0
    private var compiler: TypstCompiler?
    private let rasterQueue = DispatchQueue(label:"blank.templates.raster",qos:.utility)
    private var savedObserver: NSObjectProtocol?
    var selected: DocumentTemplate? { templates.first { $0.id == selection } }

    init(root location: URL? = nil) throws {
        let root = location ?? AppController.dataDirectory.appendingPathComponent("templates")
        self.root = root
        images.countLimit = 32; images.totalCostLimit = 16*1024*1024
        pdfs.countLimit = 8; pdfs.totalCostLimit = 32*1024*1024
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let initialized = root.appendingPathComponent(".initialized")
        if !FileManager.default.fileExists(atPath:initialized.path) {
            for (index,name) in Self.starterNames.enumerated() {
                let id = String(format:"00000000-0000-4000-8000-%012d",index+1)
                guard !FileManager.default.fileExists(atPath:folder(id).path) else { continue }
                guard let url = Bundle.main.resourceURL?.appendingPathComponent("Templates/"+name+".typ") else { throw CocoaError(.fileReadNoSuchFile) }
                let session = DocumentSession(); session.buffer.loadExternal(try String(contentsOf:url,encoding:.utf8))
                try install(session,name:name,id:id)
            }
            try Data().write(to:initialized,options:.atomic)
        }
        try reload()
        savedObserver = NotificationCenter.default.addObserver(forName:.blankDocumentSaved,object:nil,queue:.main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let session = notification.object as? DocumentSession,
                      session.root?.deletingLastPathComponent().standardizedFileURL == self.root.standardizedFileURL else { return }
                do { try self.reload() } catch { session.error = error.localizedDescription }
            }
        }
    }
    deinit { if let savedObserver { NotificationCenter.default.removeObserver(savedObserver) } }
    func folder(_ id: String) -> URL { root.appendingPathComponent(id,isDirectory:true) }
    func url(_ item: DocumentTemplate) throws -> URL { try DocumentSession.dependencyTarget(item.entry,root:folder(item.id)) }
    func reload() throws {
        let fm = FileManager.default
        var result: [DocumentTemplate] = []
        for directory in try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey],options:.skipsHiddenFiles) {
            guard UUID(uuidString:directory.lastPathComponent) != nil,
                  try directory.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true else { continue }
            let manifest = try Data(contentsOf:directory.appendingPathComponent("writer.json"))
            guard let config = try JSONSerialization.jsonObject(with:manifest) as? [String:Any], let entry = config["entry"] as? String,
                  (entry as NSString).lastPathComponent == entry, entry.lowercased().hasSuffix(".typ") else { throw Self.failure("A template has an invalid entry file.") }
            let entryURL = try DocumentSession.dependencyTarget(entry,root:directory)
            // A native Move To may relocate an entry out of its gallery folder.
            // Keep the rest of the library available; the retained package can be restored.
            guard fm.fileExists(atPath:entryURL.path) else { continue }
            var hash = SHA256(); hash.update(data:manifest)
            let contents = fm.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey,.contentModificationDateKey])?.allObjects as? [URL] ?? []
            for file in contents.sorted(by:{ $0.path < $1.path }) {
                let values = try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.contentModificationDateKey])
                guard values.isRegularFile == true else { continue }
                hash.update(data:Data("\(file.path):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)".utf8))
            }
            result.append(DocumentTemplate(id:directory.lastPathComponent,entry:entry,version:hash.finalize().map { String(format:"%02x",$0) }.joined()))
        }
        templates = result.sorted {
            let a = Self.starterNames.firstIndex(of:$0.name) ?? 100, b = Self.starterNames.firstIndex(of:$1.name) ?? 100
            return a != b ? a < b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if !templates.contains(where:{ $0.id == selection }) { selection = templates.first?.id }
        requested = requested.filter { key,_ in templates.contains { $0.id == key } }
        failedVersions = failedVersions.filter { key,version in templates.contains { $0.id == key && $0.version == version } }
        renderErrors = renderErrors.filter { key,_ in failedVersions[key] != nil }
        generation += 1
    }
    static func failure(_ message: String) -> NSError { NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    private func checkedName(_ name: String) throws -> String {
        let input = name.trimmingCharacters(in:.whitespacesAndNewlines)
        let trimmed = input.lowercased().hasSuffix(".typ") ? String(input.dropLast(4)).trimmingCharacters(in:.whitespaces) : input
        guard !trimmed.isEmpty, trimmed.count <= 80, trimmed != ".", trimmed != "..", !trimmed.contains(where:{ "/\\\0\n\r".contains($0) }) else { throw Self.failure("Choose a template name of up to 80 characters without folders or line breaks.") }
        return trimmed
    }
    @discardableResult private func install(_ session: DocumentSession,name: String,id: String = UUID().uuidString) throws -> String {
        let name = try checkedName(name), destination = folder(id), staging = root.appendingPathComponent("."+UUID().uuidString)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:staging) }
        try session.saveCopy(to:staging.appendingPathComponent(name+".typ"),adopt:false)
        try JSONSerialization.data(withJSONObject:["entry":name+".typ","schemaVersion":1],options:[.prettyPrinted,.sortedKeys]).write(to:staging.appendingPathComponent("writer.json"),options:.atomic)
        try FileManager.default.moveItem(at:staging,to:destination)
        return id
    }
    @discardableResult func add(_ session: DocumentSession,name: String) throws -> DocumentTemplate {
        session.editor?.finishComposition()
        let id = try install(session,name:name); try reload(); selection = id
        return templates.first { $0.id == id }!
    }
    func isEditing(_ item: DocumentTemplate) -> Bool {
        AppController.shared?.controllers.contains { $0.session.root?.standardizedFileURL == folder(item.id).standardizedFileURL } == true
    }
    func saveOpenEditor(_ item: DocumentTemplate) throws {
        if let session = AppController.shared?.controllers.first(where:{ $0.session.root?.standardizedFileURL == folder(item.id).standardizedFileURL })?.session {
            session.editor?.finishComposition(); try session.saveToDisk()
        }
    }
    func read(_ item: DocumentTemplate) throws -> DocumentSession {
        let session = DocumentSession(); try session.open(url(item))
        // Reading a snapshot must not leave per-file watchers running.
        session.watchers.forEach { $0.cancel() }; session.watchers.removeAll()
        return session
    }
    func newDocument(from item: DocumentTemplate) throws -> DocumentSession {
        try saveOpenEditor(item)
        let saved = templates.first { $0.id == item.id } ?? item
        let source = try read(saved), copy = DocumentSession()
        copy.entry = source.entry; copy.active = source.entry
        copy.buffers = source.buffers.mapValues { DocumentBuffer($0.source) }
        for path in source.referencedAssets() where copy.buffers[path] == nil {
            copy.assets[path] = try Data(contentsOf:DocumentSession.dependencyTarget(path,root:source.root!))
        }
        var name = "Untitled", suffix = 2
        while copy.buffers[name+".typ"] != nil && name+".typ" != copy.entry { name = "Untitled \(suffix)"; suffix += 1 }
        try copy.renameEntry(name)
        copy.dirty = true
        Self.prepareForWriting(copy,selectTitle:true)
        return copy
    }
    static func prepareForWriting(_ session: DocumentSession,selectTitle: Bool) {
        for buffer in session.buffers.values {
            for index in buffer.projection.blocks.indices where buffer.projection.blocks[index].kind == "source" { buffer.setSourceCollapsed(index,true) }
        }
        if let first = session.buffer.projection.blocks.first(where:{ $0.kind != "source" && !$0.text.isEmpty }) {
            session.buffer.selection = EditSelection(first.body.start,selectTitle ? first.body.end : first.body.start)
        }
    }
    func duplicate(_ item: DocumentTemplate) throws -> DocumentTemplate {
        try saveOpenEditor(item)
        let saved = templates.first { $0.id == item.id } ?? item
        var name = saved.name+" copy", suffix = 2
        while templates.contains(where:{ $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = saved.name+" copy \(suffix)"; suffix += 1 }
        return try add(read(saved),name:name)
    }
    func moveToTrash(_ item: DocumentTemplate,using trash: ((URL) throws -> Void)? = nil) throws {
        guard !isEditing(item) else { throw Self.failure("Close this template’s editor before moving it to the Trash.") }
        if let trash { try trash(folder(item.id)) }
        else { try FileManager.default.trashItem(at:folder(item.id),resultingItemURL:nil) }
        try reload()
    }
    func image(_ item: DocumentTemplate) -> NSImage? { images.object(forKey:item.cacheKey) }
    func pdf(_ item: DocumentTemplate) -> Data? { pdfs.object(forKey:item.cacheKey).map { $0 as Data } }
    func requestPreview(_ item: DocumentTemplate,full: Bool = false) {
        guard full ? pdf(item) == nil : image(item) == nil else { return }
        guard requested[item.id] != item.version, failedVersions[item.id] != item.version else { return }
        requested[item.id] = item.version; renderErrors.removeValue(forKey:item.id)
        do {
            let session = try read(item)
            if compiler == nil { compiler = TypstCompiler() }
            pending += 1
            compiler!.compile(root:session.root!,entry:session.entry,files:session.buffers.mapValues(\.source),revision:0) { [weak self] response in
                guard let self else { return }
                switch response {
                case let .success(result):
                    guard let data = result.data else { self.finish(item,error:result.diagnostics.joined(separator:"\n")); return }
                    self.rasterQueue.async { [weak self] in
                        let document = PDFDocument(data:data)
                        let image = document?.page(at:0)?.thumbnail(of:NSSize(width:300,height:430),for:.mediaBox)
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            if self.templates.contains(where:{ $0.id == item.id && $0.version == item.version }), let image {
                                self.images.setObject(image,forKey:item.cacheKey,cost:300*430*4)
                                self.pdfs.setObject(data as NSData,forKey:item.cacheKey,cost:data.count)
                            }
                            self.finish(item,error:image == nil ? "The template has no preview page." : nil)
                        }
                    }
                case let .failure(error): self.finish(item,error:error.localizedDescription)
                }
            }
        } catch { requested.removeValue(forKey:item.id); failedVersions[item.id] = item.version; renderErrors[item.id] = error.localizedDescription; generation += 1 }
    }
    private func finish(_ item: DocumentTemplate,error: String?) {
        if requested[item.id] == item.version { requested.removeValue(forKey:item.id) }
        if templates.contains(where:{ $0.id == item.id && $0.version == item.version }), let error { failedVersions[item.id] = item.version; renderErrors[item.id] = String(error.prefix(4000)) }
        pending -= 1
        // Release the compiler process once the visible previews are finished.
        if pending == 0 { compiler = nil }
        generation += 1
    }
}
