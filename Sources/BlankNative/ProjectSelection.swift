import AppKit
import BlankCore

struct ProjectEntryChoice: Error { let root: URL; let candidates: [String] }

@MainActor enum ProjectSelection {
    // This index belongs to the app, never to a portable Typst project.
    private static var stateURL: URL { AppController.dataDirectory.appendingPathComponent("project-selections.json") }
    private static var selections: [String:String] {
        (try? JSONDecoder().decode([String:String].self,from:Data(contentsOf:stateURL))) ?? [:]
    }
    private static var rootsURL: URL { AppController.dataDirectory.appendingPathComponent("project-roots.json") }
    private static var folderRoots: Set<String> { Set((try? JSONDecoder().decode([String].self,from:Data(contentsOf:rootsURL))) ?? []) }
    static func isProject(_ root: URL) -> Bool { folderRoots.contains(root.standardizedFileURL.path) }
    static func remember(root: URL,entry: String,project: Bool = false) {
        var index = selections; index[root.standardizedFileURL.path] = entry
        do {
            try FileManager.default.createDirectory(at:stateURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(index).write(to:stateURL,options:.atomic)
            if project {
                var roots = folderRoots; roots.insert(root.standardizedFileURL.path)
                try JSONEncoder().encode(roots.sorted()).write(to:rootsURL,options:.atomic)
            }
        } catch { NSLog("Project selection: %@",error.localizedDescription) }
    }
    static func relative(_ url: URL,root: URL) throws -> String {
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path+"/") else { throw CocoaError(.fileReadNoPermission) }
        return String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count+1))
    }
    static func root(for file: URL) -> URL {
        let known = folderRoots.filter { file.standardizedFileURL.path.hasPrefix($0+"/") }.max { $0.count < $1.count }
        return known.map { URL(fileURLWithPath:$0,isDirectory:true) } ?? file.deletingLastPathComponent().standardizedFileURL
    }
    static func entry(in root: URL) throws -> String {
        if let selected = selections[root.standardizedFileURL.path], selected.lowercased().hasSuffix(".typ"),
           let target = try? DocumentSession.dependencyTarget(selected,root:root), FileManager.default.fileExists(atPath:target.path) { return selected }
        let files = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey],options:.skipsHiddenFiles)?.allObjects as? [URL] ?? []
        let candidates = try files.filter {
            guard $0.pathExtension.lowercased() == "typ" else { return false }
            return try $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true
        }.map { try relative($0,root:root) }.sorted()
        guard !candidates.isEmpty else { throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"This folder contains no .typ documents."]) }
        let session = DocumentSession(); session.root = root
        var dependencies = Set<String>()
        for file in candidates {
            guard let text = try? String(contentsOf:DocumentSession.dependencyTarget(file,root:root),encoding:.utf8) else { continue }
            for reference in literalFileReferences(text,ParsedSource.parse(text)) where reference.path.lowercased().hasSuffix(".typ") {
                if let path = session.projectAssetPath(reference.path,file:file) { dependencies.insert(path) }
            }
        }
        let mains = candidates.filter { !dependencies.contains($0) }
        if mains.count == 1 { return mains[0] }
        throw ProjectEntryChoice(root:root,candidates:mains.isEmpty ? candidates : mains)
    }
    static func create(at folder: URL) throws -> DocumentSession {
        guard !FileManager.default.fileExists(atPath:folder.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        do {
            try Data().write(to:folder.appendingPathComponent("main.typ"),options:.withoutOverwriting)
            let session = DocumentSession(); try session.open(folder,selectedEntry:"main.typ"); return session
        } catch { _ = Darwin.rmdir(folder.path); throw error }
    }
}
