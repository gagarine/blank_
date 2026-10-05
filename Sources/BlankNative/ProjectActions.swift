import AppKit
import BlankCore

@MainActor extension DocumentSession {
    func refreshIncludes() {
        var seen = Set<String>(), added = false
        func visit(_ path: String) {
            guard !seen.contains(path) else { return }; seen.insert(path)
            if buffers[path] == nil, let root {
                do {
                    let target = try Self.dependencyTarget(path,root:root)
                    if FileManager.default.fileExists(atPath:target.path) {
                        let text = try String(contentsOf:target,encoding:.utf8)
                        buffers[path] = DocumentBuffer(text); bases[path] = text; added = true
                    }
                } catch { self.error = "Could not open included chapter \(path): "+error.localizedDescription }
            }
            guard let model = buffers[path] else { return }
            for include in model.includes+model.imports where !include.path.hasPrefix("@") { if let child = projectAssetPath(include.path,file:path) { visit(child) } }
        }
        visit(entry)
        if added { revision += 1; installWatchers() }
    }
    @discardableResult func moveChapter(_ from: String,before target: String,after: Bool = false) -> Bool {
        guard requestEditing() else { return false }
        guard from != target, from != entry, target != entry else { return false }
        for parent in includes {
            guard let model = buffers[parent] else { continue }
            let paths = model.includes.map { projectAssetPath($0.path,file:parent) }
            let origins = paths.indices.filter { paths[$0] == from }, destinations = paths.indices.filter { paths[$0] == target }
            guard origins.count == 1, destinations.count == 1 else { continue }
            guard after ? model.moveInclude(origins[0],after:destinations[0]) : model.moveInclude(origins[0],before:destinations[0]) else { return false }
            changed(); projectUndoPath = parent; return true
        }
        return false
    }
    func projectAssetPath(_ literal: String, file: String? = nil) -> String? {
        let base = URL(fileURLWithPath:"/project").appendingPathComponent(((file ?? active) as NSString).deletingLastPathComponent)
        let target = base.appendingPathComponent(literal).standardizedFileURL
        guard !literal.hasPrefix("/"), target.path.hasPrefix("/project/") else { return nil }
        return String(target.path.dropFirst("/project/".count))
    }
    func relativeAssetPath(_ path: String) -> String {
        let from = (active as NSString).deletingLastPathComponent.split(separator:"/").map(String.init), to = path.split(separator:"/").map(String.init)
        var common = 0; while common < min(from.count,to.count) && from[common] == to[common] { common += 1 }
        return (Array(repeating:"..",count:from.count-common)+to.dropFirst(common)).joined(separator:"/")
    }
    func saveCopy(to url: URL,removing original: URL? = nil,adopt: Bool = true,overwritingSnapshot: Bool = false) throws {
        guard !overwritingSnapshot || !adopt else { throw CocoaError(.fileWriteNoPermission) }
        let destination = url.deletingLastPathComponent(), newEntry = url.lastPathComponent
        guard newEntry == entry || buffers[newEntry] == nil else { throw CocoaError(.fileWriteFileExists) }
        let entryModel = buffers[entry]!
        var entrySource = entryModel.source, entrySelection = entryModel.selection
        if !(entry as NSString).deletingLastPathComponent.isEmpty {
            // Save As relocates the entry to the chosen filename. Rebase only
            // literal file arguments; preserve comments and custom expressions.
            for reference in literalFileReferences(entryModel.source,entryModel.parsed).sorted(by:{ $0.source.start > $1.source.start }) {
                guard !reference.path.hasPrefix("@"), let path = projectAssetPath(reference.path,file:entry), path != reference.path else { continue }
                let replacement = typstStringLiteral(path)
                func mapped(_ position: Int) -> Int {
                    if position <= reference.source.start { return position }
                    if position >= reference.source.end { return position+replacement.utf8.count-reference.source.count }
                    return reference.source.start+replacement.utf8.count
                }
                entrySelection = EditSelection(mapped(entrySelection.anchor),mapped(entrySelection.focus))
                entrySource = entrySource.replacingBytes(reference.source,with:replacement)
            }
        }
        var dependencies = assets
        if let root {
            for path in referencedAssets() where dependencies[path] == nil {
                dependencies[path] = try Data(contentsOf:Self.dependencyTarget(path,root:root))
            }
        }
        for (path,model) in buffers where path != entry { dependencies[path] = Data(model.source.utf8) }
        if includes.count > 1 || root.map({ FileManager.default.fileExists(atPath:$0.appendingPathComponent("writer.json").path) }) == true {
            var config = root.flatMap { try? Data(contentsOf:$0.appendingPathComponent("writer.json")) }.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] } ?? [:]
            config["entry"] = newEntry; dependencies["writer.json"] = try JSONSerialization.data(withJSONObject:config,options:[.prettyPrinted,.sortedKeys])
        }
        // All collisions are checked before creating any destination files.
        for (path,data) in dependencies {
            let target = try Self.dependencyTarget(path,root:destination)
            guard target != url else { throw CocoaError(.fileWriteFileExists) }
            if !overwritingSnapshot, FileManager.default.fileExists(atPath:target.path), try Data(contentsOf:target) != data { throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"\(path) already exists with different content. Choose an empty folder."]) }
        }
        for (path,data) in dependencies {
            if overwritingSnapshot {
                let target = try Self.dependencyTarget(path,root:destination)
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try data.write(to:target,options:.atomic)
            } else { try Self.writeDependency(data,path:path,root:destination) }
        }
        try Data(entrySource.utf8).write(to:url,options:.atomic)
        if let original {
            // Do not delete a file changed by another writer during relocation.
            guard try String(contentsOf:original,encoding:.utf8) == entryModel.source else { throw CocoaError(.fileWriteUnknown) }
            if let tags = try? original.resourceValues(forKeys:[.tagNamesKey]) {
                var destinationURL = url; try destinationURL.setResourceValues(tags)
            }
            try FileManager.default.removeItem(at:original)
        }
        guard adopt else { return }
        let identityChanged = entry != newEntry || root?.path != destination.path || entryModel.source != entrySource
        entryModel.commit(entrySource,selection:entrySelection)
        let old = entry; buffers[newEntry] = buffers.removeValue(forKey:old)
        if active == old { active = newEntry }; entry = newEntry; root = destination; bases = buffers.mapValues(\.source); dirty = false
        if identityChanged { revision += 1 }
        installWatchers(); onTitle?(); persistRecovery(); NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if identityChanged && mode == .preview { compile() }
    }
    func moveEntry(to url: URL) throws {
        editor?.finishComposition(); saveWork?.cancel()
        guard let root else { try saveCopy(to:url); return }
        let original = try Self.dependencyTarget(entry,root:root)
        if original.standardizedFileURL == url.standardizedFileURL { return }
        guard !FileManager.default.fileExists(atPath:url.path) else { throw CocoaError(.fileWriteFileExists) }
        if original.deletingLastPathComponent().standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL {
            try renameEntry(url.lastPathComponent); return
        }
        try saveToDisk()
        guard ensureRecovery() else { throw CocoaError(.fileWriteUnknown) }
        var coordinationError: NSError?, writeError: (any Error)?
        NSFileCoordinator(filePresenter:window?.windowController?.document as? NSFilePresenter).coordinate(writingItemAt:original,options:.forMoving,writingItemAt:url,options:.forReplacing,error:&coordinationError) { from,to in
            do { try saveCopy(to:to,removing:from) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
    }
    func renameEntry(_ requested: String) throws {
        let name = requested.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains(where:{ "/\\\0".contains($0) }) else { throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"Choose a filename without folders."]) }
        let leaf = name.lowercased().hasSuffix(".typ") ? name : name+".typ"
        let next = (entry as NSString).deletingLastPathComponent.isEmpty ? leaf : (entry as NSString).deletingLastPathComponent+"/"+leaf
        guard next != entry else { return }
        guard buffers[next] == nil else { throw CocoaError(.fileWriteFileExists) }
        if let root {
            try saveToDisk()
            let from = try Self.dependencyTarget(entry,root:root), to = try Self.dependencyTarget(next,root:root)
            try FileManager.default.linkItem(at:from,to:to)
            let configURL = root.appendingPathComponent("writer.json"), config = try? Data(contentsOf:configURL)
            do {
                if let config, var object = try JSONSerialization.jsonObject(with:config) as? [String:Any], object["entry"] as? String == entry {
                    object["entry"] = next
                    try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:configURL,options:.atomic)
                }
                try FileManager.default.removeItem(at:from)
            } catch {
                try? FileManager.default.removeItem(at:to)
                if let config { try? config.write(to:configURL,options:.atomic) }
                throw error
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(to)
        }
        let old = entry; buffers[next] = buffers.removeValue(forKey:old); bases[next] = bases.removeValue(forKey:old)
        if active == old { active = next }; entry = next; revision += 1; installWatchers(); persistRecovery(); onTitle?()
    }

}
