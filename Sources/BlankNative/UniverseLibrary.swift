import AppKit
import PDFKit
import BlankCore

struct UniverseTemplate: Identifiable, Decodable, Equatable {
    let name: String
    let version: String
    let description: String
    let authors: [String]
    let categories: [String]
    let keywords: [String]
    let license: String?
    let repository: String?
    let compiler: String?
    let updatedAt: Double?
    let firstReleasedAt: Double?
    var repositoryURL: URL? {
        guard let repository, let url = URL(string:repository), ["https","http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    let thumbnail: Bool?
    var thumbnailURL: URL? {
        thumbnail == true ? URL(string:"https://packages.typst.org/preview/thumbnails/\(name)-\(version)-small.webp") : nil
    }
    var id: String { name+":"+version }
    var documentationURL: URL { URL(string:"https://typst.app/universe/package/\(name)/\(version)/")! }
    func matches(_ query: String) -> Bool {
        query.isEmpty || ([name,description]+authors+categories+keywords).joined(separator:" ").localizedStandardContains(query)
    }
}

final class UniverseProject: NSObject, @unchecked Sendable {
    let entry: String
    let files: [String:Data]
    let documentation: String?
    let readmeBlocks: [UniverseReadmeBlock]
    var cost: Int { files.values.reduce(0) { $0+$1.count } }
    init(reply: [String:Any]) throws {
        guard let entry = reply["entry"] as? String, let encoded = reply["files"] as? [String:String], encoded.count <= 10_000 else { throw Self.failure("The template returned no project.") }
        var files: [String:Data] = [:], total = 0
        for (path,text) in encoded {
            guard Self.safePath(path), let data = Data(base64Encoded:text) else { throw Self.failure("The template contains an invalid file.") }
            total += data.count
            guard total <= 64*1024*1024 else { throw Self.failure("The template exceeds 64 MiB.") }
            if path.lowercased().hasSuffix(".typ"), String(data:data,encoding:.utf8) == nil { throw Self.failure("Template source is not UTF-8.") }
            files[path] = data
        }
        guard Self.safePath(entry), entry.lowercased().hasSuffix(".typ"), files[entry] != nil else { throw Self.failure("The template entry file is missing.") }
        self.entry = entry; self.files = files; documentation = reply["documentation"] as? String
        readmeBlocks = documentation.map(UniverseReadmeBlock.parse) ?? []
    }
    private static func failure(_ message: String) -> NSError { NSError(domain:"Universe",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") && path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    // Parsing and copying files runs on the worker queue before installing a
    // session on the main actor. Every creation owns its own buffers and bytes.
    func contents() -> (buffers: [String:DocumentBuffer], assets: [String:Data]) {
        var buffers: [String:DocumentBuffer] = [:], assets: [String:Data] = [:]
        for (path,data) in files {
            if path.lowercased().hasSuffix(".typ"), let text = String(data:data,encoding:.utf8) {
                let buffer = DocumentBuffer(text)
                for index in buffer.projection.blocks.indices where buffer.projection.blocks[index].kind == "source" { buffer.setSourceCollapsed(index,true) }
                buffers[path] = buffer
            }
            else { assets[path] = data }
        }
        return (buffers,assets)
    }
    @MainActor func session(contents: (buffers: [String:DocumentBuffer], assets: [String:Data])) -> DocumentSession {
        let session = DocumentSession(); session.entry = entry; session.active = entry
        session.buffers = contents.buffers; session.assets = contents.assets; session.dirty = true
        TemplateLibrary.prepareForWriting(session,selectTitle:true)
        return session
    }
}

@MainActor final class UniverseLibrary: ObservableObject {
    @Published var templates: [UniverseTemplate] = []
    @Published var selection: String? { didSet { if selection != oldValue { selectedProject = nil; requestPreview() } } }
    @Published var loading = false
    @Published var loadError: String?
    @Published var warning: String?
    @Published var previewing = false
    @Published var previewError: String?
    @Published var creating = false
    @Published var createError: String?
    @Published var generation = 0
    let thumbnails = UniverseThumbnails()
    private var requestedPreviewID: String?
    private var selectedProject: (id:String,project:UniverseProject)?
    private let now: () -> Date
    private var catalogueLoadedAt: Date?
    private var catalogueClient: TypstCompiler?
    private var previewClient: TypstCompiler?
    private var createClient: TypstCompiler?
    private var catalogueToken = UUID(), previewToken = UUID(), createToken = UUID()
    private let worker = DispatchQueue(label:"blank.universe.projects",qos:.userInitiated)
    private let projects = NSCache<NSString,UniverseProject>()
    private let pdfs = NSCache<NSString,NSData>()
    var selected: UniverseTemplate? { templates.first { $0.id == self.selection } }
    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
        projects.countLimit = 2; projects.totalCostLimit = 64*1024*1024
        pdfs.countLimit = 6; pdfs.totalCostLimit = 32*1024*1024
    }
    func project(_ item: UniverseTemplate) -> UniverseProject? { selectedProject?.id == item.id ? selectedProject?.project : projects.object(forKey:item.id as NSString) }
    func pdf(_ item: UniverseTemplate) -> Data? { pdfs.object(forKey:item.id as NSString).map { $0 as Data } }
    func load(refresh: Bool = false) {
        guard !loading, refresh || templates.isEmpty || catalogueLoadedAt.map({ now().timeIntervalSince($0) >= 24*60*60 }) != false else { return }
        loading = true; loadError = nil
        let token = UUID(); catalogueToken = token
        let client = TypstCompiler(); catalogueClient = client
        client.universe("universeCatalog",params:["refresh":refresh]) { [weak self = self] result in
            guard let self, catalogueToken == token else { return }
            worker.async { [self] in
                let decoded = Result { () throws -> ([UniverseTemplate],String?) in
                    let reply = try result.get()
                    let data = try JSONSerialization.data(withJSONObject:reply["templates"] ?? [])
                    return (try JSONDecoder().decode([UniverseTemplate].self,from:data),reply["warning"] as? String)
                }
                DispatchQueue.main.async { [weak self = self] in
                    guard let self, catalogueToken == token else { return }
                    loading = false; catalogueClient = nil
                    do {
                        let (items,message) = try decoded.get(); templates = items; warning = message; catalogueLoadedAt = now()
                        if !templates.contains(where:{ $0.id == self.selection }) { selection = nil }
                    } catch { loadError = error.localizedDescription }
                }
            }
        }
    }
    func cancelBrowsing() {
        catalogueToken = UUID(); catalogueClient?.cancel(); catalogueClient = nil; loading = false
        cancelPreview(); cancelCreation(); thumbnails.cancelAll()
    }
    func cancelPreview() {
        previewToken = UUID(); previewClient?.cancel(); previewClient = nil; previewing = false; requestedPreviewID = nil
    }
    private func fetch(_ item: UniverseTemplate, client: TypstCompiler, completion: @escaping (Result<UniverseProject,Error>) -> Void) {
        if let cached = project(item) { completion(.success(cached)); return }
        client.universe("universeTemplate",params:["name":item.name,"version":item.version]) { [weak self = self] result in
            guard let self else { return }
            worker.async { [self] in
                let decoded = Result { try UniverseProject(reply:result.get()) }
                DispatchQueue.main.async { [weak self = self] in
                    if let value = try? decoded.get() {
                        self?.projects.setObject(value,forKey:item.id as NSString,cost:value.cost)
                        if self?.selection == item.id { self?.selectedProject = (item.id,value) }
                    }
                    completion(decoded)
                }
            }
        }
    }
    func requestPreview() {
        guard let item = selected else { cancelPreview(); previewError = nil; return }
        guard !previewing || requestedPreviewID != item.id else { return }
        cancelPreview(); previewError = nil
        guard pdf(item) == nil || project(item) == nil else { return }
        requestedPreviewID = item.id
        previewing = true
        let token = UUID(); previewToken = token
        let client = TypstCompiler(); previewClient = client
        fetch(item,client:client) { [weak self = self] result in
            guard let self, previewToken == token else { return }
            switch result {
            case let .failure(error): finishPreview(token,error:error.localizedDescription)
            case let .success(project):
                selectedProject = (item.id,project); generation += 1
                if pdf(item) != nil { finishPreview(token,error:nil); return }
                worker.async { [self] in
                    let folder = AppController.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("blank-universe-"+UUID().uuidString)
                    let prepared = Result { () throws -> [String:String] in
                        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                        var sources: [String:String] = [:]
                        for (path,data) in project.files {
                            if path.lowercased().hasSuffix(".typ"), let text = String(data:data,encoding:.utf8) { sources[path] = text }
                            else {
                                let target = folder.appendingPathComponent(path)
                                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                                try data.write(to:target)
                            }
                        }
                        return sources
                    }
                    DispatchQueue.main.async { [weak self = self] in
                        guard let self, previewToken == token else { Self.removePreviewFolder(folder); return }
                        do {
                            let sources = try prepared.get()
                            client.compile(root:folder,entry:project.entry,files:sources,revision:0) { [weak self = self] response in
                                Self.removePreviewFolder(folder)
                                guard let self, previewToken == token else { return }
                                do {
                                    let compiled = try response.get()
                                    guard let data = compiled.data else { throw TemplateLibrary.failure(compiled.diagnostics.joined(separator:"\n")) }
                                    guard data.count <= 32*1024*1024 else { throw TemplateLibrary.failure("This preview exceeds 32 MiB. You can still create and edit the template.") }
                                    pdfs.setObject(data as NSData,forKey:item.id as NSString,cost:data.count)
                                    finishPreview(token,error:nil)
                                } catch { finishPreview(token,error:error.localizedDescription) }
                            }
                        } catch { Self.removePreviewFolder(folder); finishPreview(token,error:error.localizedDescription) }
                    }
                }
            }
        }
    }
    nonisolated private static func removePreviewFolder(_ folder: URL) {
        DispatchQueue.global(qos:.utility).async { try? FileManager.default.removeItem(at:folder) }
    }
    private func finishPreview(_ token: UUID,error: String?) {
        guard previewToken == token else { return }
        previewing = false; previewClient = nil; previewError = error.map { String($0.prefix(4000)) }; generation += 1
    }
    func cancelCreation() {
        createToken = UUID(); createClient?.cancel(); createClient = nil; creating = false
    }
    func create(completion: @escaping (DocumentSession) -> Void) {
        guard let item = selected, !creating else { return }
        creating = true; createError = nil
        let token = UUID(); createToken = token
        let client = TypstCompiler(); createClient = client
        fetch(item,client:client) { [weak self = self] result in
            guard let self, createToken == token else { return }
            switch result {
            case let .failure(error): creating = false; createClient = nil; createError = error.localizedDescription
            case let .success(project):
                worker.async { [self] in
                    let contents = project.contents()
                    DispatchQueue.main.async { [weak self = self] in
                        guard let self, createToken == token else { return }
                        creating = false; createClient = nil
                        completion(project.session(contents:contents))
                    }
                }
            }
        }
    }
}
