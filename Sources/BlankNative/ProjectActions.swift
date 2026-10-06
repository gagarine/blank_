import AppKit
import BlankCore

@MainActor extension DocumentSession {
    func refreshIncludes(createMissing: Bool = false) {
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
            for reference in literalFileReferences(model.source,model.parsed) where reference.path.lowercased().hasSuffix(".typ") && !reference.path.hasPrefix("@") {
                if let child = projectAssetPath(reference.path,file:path) {
                    if createMissing, !model.parsed.erroneous, model.includes.contains(where:{ $0.path == reference.path }), buffers[child] == nil,
                       root == nil || root.flatMap({ try? Self.dependencyTarget(child,root:$0) }).map({ !FileManager.default.fileExists(atPath:$0.path) }) == true {
                        buffers[child] = DocumentBuffer(); added = true
                    }
                    visit(child)
                }
            }
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
        guard !literal.hasPrefix("@"), !literal.contains("\\") else { return nil }
        let base = URL(fileURLWithPath:"/project").appendingPathComponent(literal.hasPrefix("/") ? "" : ((file ?? active) as NSString).deletingLastPathComponent)
        let target = base.appendingPathComponent(literal.hasPrefix("/") ? String(literal.dropFirst()) : literal).standardizedFileURL
        guard target.path.hasPrefix("/project/") else { return nil }
        return String(target.path.dropFirst("/project/".count))
    }
    func relativeAssetPath(_ path: String,file: String? = nil) -> String {
        let from = ((file ?? active) as NSString).deletingLastPathComponent.split(separator:"/").map(String.init), to = path.split(separator:"/").map(String.init)
        var common = 0; while common < min(from.count,to.count) && from[common] == to[common] { common += 1 }
        return (Array(repeating:"..",count:from.count-common)+to.dropFirst(common)).joined(separator:"/")
    }
    func saveCopy(to url: URL,removing original: URL? = nil,adopt: Bool = true,overwritingSnapshot: Bool = false) throws {
        guard !overwritingSnapshot || !adopt else { throw CocoaError(.fileWriteNoPermission) }
        let destination = url.deletingLastPathComponent(), newEntry = url.lastPathComponent
        guard newEntry == entry || buffers[newEntry] == nil else { throw CocoaError(.fileWriteFileExists) }
        let entryModel = buffers[entry]!
        var entrySource = entryModel.source, entrySelection = entryModel.selection
        let nested = !(entry as NSString).deletingLastPathComponent.isEmpty
        let consumers = Set(["image","read","csv","json","yaml","xml","cbor"])
        let computed = entryModel.parsed.tree.descendants("FuncCall").contains { call in
            guard let name = call.children.first, consumers.contains(entryModel.source.bytes(name.span)), let args = call.children.first(where:{ $0.kind == "Args" }), let argument = args.children.first(where:{ !["Space","LeftParen","RightParen","Comma","LineComment","BlockComment","Named"].contains($0.kind) }) else { return false }
            return argument.kind != "Str"
        } || ["ModuleInclude","ModuleImport"].contains { kind in entryModel.parsed.tree.descendants(kind).contains { !$0.children.contains(where:{ $0.kind == "Str" }) } } || bibliographyCalls(entryModel.source,entryModel.parsed).contains { $0.inputs.contains { $0.format == "computed" } }
        let retainNestedEntry = nested && computed
        if retainNestedEntry {
            // An ordinary include wrapper keeps computed relative paths rooted
            // at their original source file, without rewriting custom code.
            entrySource = "#include \(typstStringLiteral(entry))\n"; entrySelection = EditSelection(0,0)
        } else if nested {
            // Save As relocates the entry to the chosen filename. Rebase only
            // literal file arguments; preserve comments and custom expressions.
            for reference in literalFileReferences(entryModel.source,entryModel.parsed).sorted(by:{ $0.source.start > $1.source.start }) {
                guard !reference.path.hasPrefix("@"), !reference.path.hasPrefix("/"), let path = projectAssetPath(reference.path,file:entry), path != reference.path else { continue }
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
        if retainNestedEntry { dependencies[entry] = Data(entryModel.source.utf8) }
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
        let wasProject = root.map { ProjectSelection.isProject($0) } ?? false
        let identityChanged = entry != newEntry || root?.path != destination.path || entryModel.source != entrySource
        let old = entry
        if retainNestedEntry { buffers[newEntry] = DocumentBuffer(entrySource) }
        else {
            entryModel.commit(entrySource,selection:entrySelection)
            buffers[newEntry] = buffers.removeValue(forKey:old); remapReferenceHistory(from:old,to:newEntry)
            if active == old { active = newEntry }
        }
        entry = newEntry; root = destination; bases = buffers.mapValues(\.source); dirty = false
        ProjectSelection.remember(root:destination,entry:newEntry,project:wasProject)
        if identityChanged { revision += 1 }
        installWatchers(); onTitle?(); persistRecovery(); NSDocumentController.shared.noteNewRecentDocumentURL(url)
        NotificationCenter.default.post(name:.blankDocumentSaved,object:self)
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
            do { try FileManager.default.removeItem(at:from) }
            catch { try? FileManager.default.removeItem(at:to); throw error }
            NSDocumentController.shared.noteNewRecentDocumentURL(to)
        }
        let old = entry; buffers[next] = buffers.removeValue(forKey:old); bases[next] = bases.removeValue(forKey:old)
        remapReferenceHistory(from:old,to:next)
        if active == old { active = next }; entry = next; revision += 1; installWatchers(); persistRecovery(); onTitle?()
        if let root { ProjectSelection.remember(root:root,entry:next) }
        NotificationCenter.default.post(name:.blankDocumentSaved,object:self)
    }

}
