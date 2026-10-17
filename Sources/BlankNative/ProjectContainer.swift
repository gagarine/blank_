import AppKit
import BlankCore
import UniformTypeIdentifiers
import PDFKit

// The archive URL is the document identity. Extracted files are private working
// state, used only by the existing source model and official compiler.
enum DocumentFormat: Int, CaseIterable {
    case container, document, folder
    var label: String {
        switch self {
        case .document: return "Typst document (.typ)"
        case .folder: return "Typst project folder"
        case .container: return "Typst document bundle (.typz)"
        }
    }
    var detail: String {
        switch self {
        case .document: return "A Typst source file, with imported images in an adjacent “assets” folder."
        case .folder: return "An ordinary folder containing your Typst source and related files."
        case .container: return "Keeps your document and related files together in one file. Open and edit it directly."
        }
    }
    var typeName: String {
        switch self {
        case .document: return "org.typst.source"
        case .folder: return "local.blank.project-folder"
        case .container: return "org.typst.project-container"
        }
    }
}

@MainActor final class SaveFormatAccessory: NSObject {
    let view = NSStackView()
    let popup = NSPopUpButton()
    let explanation = NSTextField(wrappingLabelWithString:"")
    weak var panel: NSSavePanel?
    var format: DocumentFormat { DocumentFormat(rawValue:popup.indexOfSelectedItem) ?? .document }
    init(panel: NSSavePanel, format: DocumentFormat) {
        self.panel = panel
        super.init()
        popup.addItems(withTitles:DocumentFormat.allCases.map(\.label)); popup.selectItem(at:format.rawValue)
        popup.target = self; popup.action = #selector(changed)
        let row = NSStackView(views:[NSTextField(labelWithString:"File format:"),popup]); row.spacing = 8
        popup.setAccessibilityLabel("File format")
        explanation.preferredMaxLayoutWidth = 440
        explanation.font = .systemFont(ofSize:NSFont.smallSystemFontSize); explanation.textColor = .secondaryLabelColor
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 8
        view.edgeInsets = NSEdgeInsets(top:12,left:0,bottom:12,right:0)
        view.addArrangedSubview(row); view.addArrangedSubview(explanation)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant:440).isActive = true
        explanation.widthAnchor.constraint(equalTo:view.widthAnchor).isActive = true
        panel.accessoryView = view
        let name = panel.nameFieldStringValue as NSString
        // Configuration-only property on macOS 27. Let currentContentType own
        // extension changes once the remote panel has been presented.
        panel.nameFieldStringValue = ["typ","typz"].contains(name.pathExtension.lowercased()) ? name.deletingPathExtension : name as String
        changed()
    }
    @objc func changed() {
        guard let panel else { return }
        let type: UTType = format == .folder ? .directory : UTType(importedAs:format.typeName)
        panel.allowedContentTypes = [type]; panel.currentContentType = type
        panel.allowsOtherFileTypes = false
        explanation.stringValue = format.detail
    }
}

enum ContainerWriteError: LocalizedError {
    case documentChanged
    var errorDescription: String? { "The document changed while preparing its bundle. Save again." }
}

struct PreparedContainerWrite {
    let url: URL
    let revision: Int
    let files: [String:Data]
    let data: Data
}

enum TypstContainer {
    static func encode(_ files: [String:Data],entry: String,preview: Data? = nil,renderPreview: Bool = false) throws -> Data {
        let stage = AppController.temporaryDirectory.appendingPathComponent("blank-typz-"+UUID().uuidString)
        let contents = stage.appendingPathComponent("project"), output = stage.appendingPathComponent("project.typz")
        try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:stage) }
        for (path,data) in files { try DocumentSession.writeDependency(data,path:path,root:contents) }
        var arguments = ["--typz-write",contents.path,entry,output.path]
        if let preview {
            let cached = stage.appendingPathComponent("Preview.pdf")
            try preview.write(to:cached); arguments.append(cached.path)
        } else if renderPreview { arguments.append("--render-preview") }
        _ = try run(arguments)
        return try Data(contentsOf:output)
    }
    static func run(_ arguments: [String]) throws -> String {
        let bundled = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("typst-compiler")
        let executable = FileManager.default.isExecutableFile(atPath:bundled.path) ? bundled : URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("target/release/typst-compiler")
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+30,execute:timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let entry = json["entry"] as? String else {
            let message = String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:message.isEmpty ? "The Typst document bundle helper stopped before finishing." : message])
        }
        return entry
    }
}

@MainActor extension DocumentSession {
    var documentURL: URL? { containerURL ?? root?.appendingPathComponent(entry) }
    var documentFormat: DocumentFormat { containerURL != nil ? .container : savesAsFolder ? .folder : .document }
    var containerDirectory: URL { AppController.dataDirectory.appendingPathComponent("containers/"+id) }
    func openContainer(_ url: URL) throws {
        let workspace = containerDirectory.appendingPathComponent(UUID().uuidString)
        let cachedPreview = containerDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        defer { try? FileManager.default.removeItem(at:cachedPreview) }
        try FileManager.default.createDirectory(at:containerDirectory,withIntermediateDirectories:true)
        do {
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 256*1024*1024 else { throw CocoaError(.fileReadTooLarge) }
            let baseline = try Data(contentsOf:url)
            let file = try TypstContainer.run(["--typz-read",url.path,workspace.path,cachedPreview.path])
            guard try Data(contentsOf:url) == baseline else { throw CocoaError(.fileReadUnknown) }
            try open(workspace,selectedEntry:file,rememberProject:false)
            containerURL = url.standardizedFileURL; containerBaseline = baseline
            assets = try projectSnapshot().filter { buffers[$0.key] == nil }
            if let data = try? Data(contentsOf:cachedPreview), let document = PDFDocument(data:data) {
                pdfData = data; pdf = document
            }
            installWatchers(); onTitle?()
        } catch { try? FileManager.default.removeItem(at:workspace); throw error }
    }
    // Include the complete selected project, including fonts and unused files.
    // A lone .typ only brings its known dependencies, never its sibling documents.
    func projectSnapshot() throws -> [String:Data] {
        var files: [String:Data] = [:]
        var total = 0
        func read(_ url: URL) throws -> Data {
            let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
            guard size <= 256*1024*1024-total, files.count < 10_000 else { throw CocoaError(.fileReadTooLarge) }
            total += size
            return try Data(contentsOf:url)
        }
        if let root {
            if containerURL != nil || ProjectSelection.isProject(root) {
                guard let enumerator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey]) else { throw CocoaError(.fileReadUnknown) }
                for case let url as URL in enumerator {
                    let values = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey])
                    guard values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
                    if values.isDirectory == true { continue }
                    guard values.isRegularFile == true else { throw CocoaError(.fileReadNoPermission) }
                    let path = try ProjectSelection.relative(url,root:root)
                    files[path] = try read(Self.dependencyTarget(path,root:root))
                }
            } else {
                for path in referencedAssets() where assets[path] == nil && buffers[path] == nil {
                    files[path] = try read(Self.dependencyTarget(path,root:root))
                }
            }
        }
        files.merge(assets) { _,new in new }
        files.merge(buffers.mapValues { Data($0.source.utf8) }) { _,new in new }
        guard files.count <= 10_000, files.values.reduce(0,{ $0+$1.count }) <= 256*1024*1024 else { throw CocoaError(.fileReadTooLarge) }
        return files
    }
    func checkContainerUnchanged() throws {
        guard let containerURL else { return }
        guard let disk = try? Data(contentsOf:containerURL), disk == containerBaseline else {
            persistRecovery()
            throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"This Typst project changed or was removed outside blank_. Your writing is retained in recovery. Reopen the file to use its current contents, or use Save As to keep your version separately."])
        }
    }
    func prepareContainerWrite(to url: URL,completion: @escaping (Error?) -> Void) {
        do {
            editor?.finishComposition()
            if containerURL?.standardizedFileURL == url.standardizedFileURL { try checkContainerUnchanged() }
            let files = try projectSnapshot(), current = revision, entry = entry
            let preview = compileRevision == current ? pdfData : nil
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                let result = Result { try TypstContainer.encode(files,entry:entry,preview:preview,renderPreview:preview == nil) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { completion(CocoaError(.userCancelled)); return }
                    guard self.revision == current else {
                        completion(ContainerWriteError.documentChanged); return
                    }
                    switch result {
                    case .failure(let error): completion(error)
                    case .success(let data):
                        self.preparedContainerWrite = PreparedContainerWrite(url:url,revision:current,files:files,data:data)
                        completion(nil)
                    }
                }
            }
        } catch { completion(error) }
    }
    func saveContainer(to url: URL, adopt: Bool = true) throws {
        if containerURL?.standardizedFileURL == url.standardizedFileURL { try checkContainerUnchanged() }
        let files: [String:Data], data: Data
        if let prepared = preparedContainerWrite, prepared.url == url, prepared.revision == revision {
            files = prepared.files; data = prepared.data
        } else {
            files = try projectSnapshot(); data = try TypstContainer.encode(files,entry:entry,preview:compileRevision == revision ? pdfData : nil)
        }
        preparedContainerWrite = nil
        // New containers adopt a private working copy before replacing the target.
        // Nothing in the model/history is re-created when saving an open .typz.
        var workspace = root
        if adopt && containerURL == nil {
            workspace = containerDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:containerDirectory,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:workspace!,withIntermediateDirectories:false)
        }
        if adopt, let workspace {
            for (path,data) in files {
                let target = try Self.dependencyTarget(path,root:workspace)
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try data.write(to:target,options:.atomic)
            }
        }
        if containerURL?.standardizedFileURL == url.standardizedFileURL { try checkContainerUnchanged() }
        do { try data.write(to:url,options:.atomic) }
        catch { if adopt && containerURL == nil, let workspace { try? FileManager.default.removeItem(at:workspace) }; throw error }
        guard adopt else { return }
        let identityChanged = containerURL?.standardizedFileURL != url.standardizedFileURL
        containerURL = url.standardizedFileURL; containerBaseline = data; root = workspace
        assets = files.filter { buffers[$0.key] == nil }
        bases = buffers.mapValues(\.source); dirty = false
        if identityChanged { revision += 1 }
        installWatchers(); onTitle?(); persistRecovery()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        NotificationCenter.default.post(name:.blankDocumentSaved,object:self)
    }
    func saveFormatted(to url: URL,format: DocumentFormat) throws {
        editor?.finishComposition(); saveWork?.cancel()
        switch format {
        case .container: try saveContainer(to:url)
        case .folder:
            let files = try projectSnapshot()
            guard !FileManager.default.fileExists(atPath:url.path) else { throw CocoaError(.fileWriteFileExists) }
            let staging = url.deletingLastPathComponent().appendingPathComponent(".blank-project-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
            defer { try? FileManager.default.removeItem(at:staging) }
            for (path,data) in files { try Self.writeDependency(data,path:path,root:staging) }
            try FileManager.default.moveItem(at:staging,to:url)
            containerURL = nil; containerBaseline = nil; root = url; savesAsFolder = true
            ProjectSelection.remember(root:url,entry:entry,project:true)
            bases = buffers.mapValues(\.source); dirty = false; revision += 1
            installWatchers(); onTitle?(); persistRecovery()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            NotificationCenter.default.post(name:.blankDocumentSaved,object:self)
        case .document: try saveSingleDocument(to:url)
        }
    }
    func saveSingleDocument(to url: URL) throws {
        let files = try projectSnapshot()
        // All formats share the same project-relative hierarchy. Only the entry
        // adopts the selected filename; assets/, chapters/ and custom folders
        // keep their names instead of acquiring a filename-derived prefix.
        let names = Dictionary(uniqueKeysWithValues:files.keys.map { ($0,$0 == entry ? url.lastPathComponent : $0) })
        let destinations = names.values.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        let unique = Set(destinations)
        guard unique.count == names.count,
              !destinations.contains(where:{ name in
                  var parent = (name as NSString).deletingLastPathComponent
                  while !parent.isEmpty {
                      if unique.contains(parent) { return true }
                      parent = (parent as NSString).deletingLastPathComponent
                  }
                  return false
              }) else { throw CocoaError(.fileWriteFileExists) }
        var output = files
        func relocated(_ source: String,_ initial: EditSelection,_ path: String) -> (String,EditSelection) {
            var text = source, selection = initial
            for reference in literalFileReferences(source,ParsedSource.parse(source)).sorted(by:{ $0.source.start > $1.source.start }) {
                guard !reference.path.hasPrefix("@"), let original = projectAssetPath(reference.path,file:path), let mapped = names[original], let newFile = names[path] else { continue }
                if original == mapped && (reference.path.hasPrefix("/") || (path as NSString).deletingLastPathComponent == (newFile as NSString).deletingLastPathComponent) { continue }
                let replacement = typstStringLiteral(reference.path.hasPrefix("/") ? "/"+mapped : relativeAssetPath(mapped,file:newFile))
                if replacement == source.bytes(reference.source) { continue }
                func position(_ value: Int) -> Int {
                    value <= reference.source.start ? value : value >= reference.source.end ? value+replacement.utf8.count-reference.source.count : reference.source.start+replacement.utf8.count
                }
                selection = EditSelection(position(selection.anchor),position(selection.focus))
                text = text.replacingBytes(reference.source,with:replacement)
            }
            return (text,selection)
        }
        // A .typ export can rename/relocate the entry itself. Computed paths
        // may refer to that file too, so retain conservative preflight rather
        // than guessing at expression rewrites. Folder/bundle saves keep it.
        for (path,data) in files where path.lowercased().hasSuffix(".typ") {
            guard let source = String(data:data,encoding:.utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            if files.count > 1 && hasComputedFileReferences(source,ParsedSource.parse(source)) {
                throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"This project uses computed file paths. Choose Typst project folder or Typst document bundle (.typz) to preserve them."])
            }
            output[path] = Data(relocated(source,buffers[path]?.selection ?? EditSelection(0,0),path).0.utf8)
        }
        let destination = url.deletingLastPathComponent()
        // Preflight every dependency before any destination write.
        for (path,data) in output where path != entry {
            let target = try Self.dependencyTarget(names[path]!,root:destination)
            if FileManager.default.fileExists(atPath:target.path), try Data(contentsOf:target) != data { throw CocoaError(.fileWriteFileExists) }
        }
        for (path,data) in output where path != entry { try Self.writeDependency(data,path:names[path]!,root:destination) }
        try output[entry]!.write(to:url,options:.atomic)
        let oldEntry = entry, oldBuffers = buffers
        buffers = [:]
        for (path,model) in oldBuffers {
            if path.lowercased().hasSuffix(".typ") { model.relocateSource { relocated($0,$1,path) } }
            let next = names[path]!; buffers[next] = model; remapReferenceHistory(from:path,to:next)
        }
        assets = Dictionary(uniqueKeysWithValues:output.filter { oldBuffers[$0.key] == nil }.map { (names[$0.key]!,$0.value) })
        active = names[active] ?? url.lastPathComponent; entry = names[oldEntry]!
        root = destination; containerURL = nil; containerBaseline = nil; savesAsFolder = false
        bases = buffers.mapValues(\.source); dirty = false; revision += 1
        installWatchers(); onTitle?(); persistRecovery(); NSDocumentController.shared.noteNewRecentDocumentURL(url)
        NotificationCenter.default.post(name:.blankDocumentSaved,object:self)
    }
}
