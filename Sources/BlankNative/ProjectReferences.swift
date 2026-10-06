import AppKit
import BlankCore

struct ReferenceDestination: Identifiable {
    let file: String
    let input: BibliographyInput?
    var id: String { input?.path != nil ? "external:"+file : file+":"+String(input?.span.start ?? -1) }
    var label: String { input?.path ?? "Embedded bibliography in \(file)" }
    var format: String { input?.format ?? "bib" }
}
@MainActor extension DocumentSession {
    var projectFiles: Set<String> {
        var seen = Set<String>()
        func visit(_ path: String) {
            guard let model = buffers[path], seen.insert(path).inserted else { return }
            for ref in literalFileReferences(model.source,model.parsed) where ref.path.lowercased().hasSuffix(".typ") {
                if let child = projectAssetPath(ref.path,file:path) { visit(child) }
            }
        }
        visit(entry); return seen
    }
    func referenceDestinations() throws -> [ReferenceDestination] {
        var result: [ReferenceDestination] = [], external = Set<String>()
        if bibliographyRevision == revision {
            for record in evaluatedBibliographies {
                guard let file = record["file"] as? String, let inputs = record["inputs"] as? [[String:Any]] else { continue }
                let start = record["start"] as? Int, end = record["end"] as? Int
                let staticCall = buffers[file].flatMap { model in bibliographyCalls(model.source,model.parsed).first { $0.span.start == start && $0.span.end == end } }
                for (index,input) in inputs.enumerated() {
                    if let path = input["path"] as? String {
                        guard ["bib","yaml","yml"].contains((path as NSString).pathExtension.lowercased()) else { throw ZoteroIntegration.failure("Unsupported bibliography format.") }
                        if external.insert(path).inserted { result.append(ReferenceDestination(file:path,input:BibliographyInput(span:ByteSpan(start ?? 0,end ?? 0),path:path,format:(path as NSString).pathExtension.lowercased()))) }
                    } else if input["embedded"] as? Bool == true, let call = staticCall, call.inputs.indices.contains(index), call.inputs[index].embedded != nil {
                        let literal = call.inputs[index]
                        if !result.contains(where:{ $0.file == file && $0.input?.span == literal.span }) { result.append(ReferenceDestination(file:file,input:literal)) }
                    } else { throw ZoteroIntegration.failure("This bibliography uses computed bytes or a package file. Edit its data in Source.") }
                }
            }
            return result.isEmpty ? [ReferenceDestination(file:entry,input:nil)] : result
        }
        for file in projectFiles.sorted() {
            guard let model = buffers[file] else { continue }
            for call in bibliographyCalls(model.source,model.parsed) {
                guard !call.inputs.isEmpty else { throw ZoteroIntegration.failure("This bibliography uses a computed input. Edit it in Source to choose an insertion destination.") }
                for input in call.inputs {
                    guard ["bib","yaml","yml"].contains(input.format) else { throw ZoteroIntegration.failure("Unsupported bibliography input. Edit it in Source.") }
                    if let literal = input.path {
                        guard let path = projectAssetPath(literal,file:file) else { throw ZoteroIntegration.failure("Bibliography path is outside the project.") }
                        if external.insert(path).inserted { result.append(ReferenceDestination(file:path,input:input)) }
                    } else { result.append(ReferenceDestination(file:file,input:input)) }
                }
            }
        }
        return result.isEmpty ? [ReferenceDestination(file:entry,input:nil)] : result
    }
    func loadBibliographies() {
        guard let destinations = try? referenceDestinations(), let root else { return }
        for destination in destinations where destination.input?.path != nil && buffers[destination.file] == nil {
            do {
                let text = try String(contentsOf:Self.dependencyTarget(destination.file,root:root),encoding:.utf8)
                buffers[destination.file] = DocumentBuffer(text); bases[destination.file] = text
            } catch { self.error = "Could not read bibliography \(destination.file): "+error.localizedDescription }
        }
    }
    func referenceText(_ destination: ReferenceDestination) throws -> String {
        if let embedded = destination.input?.embedded { return embedded }
        if destination.input == nil { return "" }
        guard let buffer = buffers[destination.file] else { throw ZoteroIntegration.failure("Cannot read \(destination.file). Repair its path before inserting references.") }
        return buffer.source
    }
    func commitReferences(_ texts: [String:String],selections: [String:EditSelection] = [:],undoPath: String) {
        var ids: [String:UUID] = [:]
        for (path,text) in texts {
            let model = buffers[path] ?? DocumentBuffer(); buffers[path] = model
            var selection = selections[path] ?? model.selection
            if selections[path] == nil, let patch = SourcePatch.difference(model.source,text) { selection = selection.mapped(through:patch) }
            if model.commit(text,selection:selection), let id = model.undoID { ids[path] = id }
        }
        guard !ids.isEmpty else { return }
        for id in ids.values { referenceTransactions[id] = ids }
        changed(); projectUndoPath = undoPath == active ? nil : undoPath
    }
    func prepareProjectCopy(_ completion: @escaping (Error?) -> Void) {
        editor?.finishComposition()
        guard let root, dependencyRevision != revision else { completion(nil); return }
        let current = revision
        compiler.compile(root:root,entry:entry,files:buffers.mapValues(\.source),revision:current) { [weak self] response in
            guard let self else { completion(CocoaError(.userCancelled)); return }
            guard self.revision == current else { completion(ZoteroIntegration.failure("Document changed while preparing its dependencies. Save again.")); return }
            switch response {
            case let .failure(error): completion(error)
            case let .success(result):
                self.dependencyRevision = current; self.compiledDependencies = Set(result.dependencies)
                if result.data != nil { self.evaluatedBibliographies = result.bibliographies; self.bibliographyRevision = current }
                completion(nil)
            }
        }
    }
    func remapReferenceHistory(from old: String,to next: String) {
        referenceTransactions = referenceTransactions.mapValues { paths in
            var paths = paths; if let id = paths.removeValue(forKey:old) { paths[next] = id }; return paths
        }
        if projectUndoPath == old { projectUndoPath = next }
    }
    static func embeddedBibliography(_ text: String,format: String = "bib") -> String {
        // Choose a delimiter absent from the data, keeping quotes, backslashes,
        // Unicode and multiline BibLaTeX completely readable in Source.
        var fence = "```"; while text.contains(fence) { fence += "`" }
        return fence+format+"\n"+text.trimmingCharacters(in:.newlines)+"\n"+fence+".text"
    }
    func referenceSource(_ text: String,destination: ReferenceDestination,source: String? = nil) -> String {
        let original = source ?? buffers[destination.file]!.source
        if let input = destination.input, input.embedded != nil {
            if text == input.embedded { return original }
            let raw = original.bytes(input.span).hasSuffix(".text")
            return original.replacingBytes(input.span,with:raw ? Self.embeddedBibliography(text,format:destination.format) : typstStringLiteral(text))
        }
        if destination.input == nil { return original+"\n\n#bibliography(bytes(\n"+Self.embeddedBibliography(text)+"\n), style: \"apa\")\n" }
        return text
    }
}

struct BibliographyLocation: Identifiable {
    let file: String
    let call: BibliographyCall
    var id: String { file+":"+String(call.span.start) }
    var label: String { file+" · "+(call.inputs.first?.path ?? "Embedded bibliography") }
}
@MainActor extension DocumentSession {
    var bibliographyLocations: [BibliographyLocation] {
        projectFiles.sorted().flatMap { file in bibliographyCalls(buffers[file]!.source,buffers[file]!.parsed).map { BibliographyLocation(file:file,call:$0) } }
    }
    func setBibliographyStyle(_ style: String,locationID: String) throws {
        guard let location = bibliographyLocations.first(where:{ $0.id == locationID }) else { throw ZoteroIntegration.failure("Choose a bibliography to style.") }
        let model = buffers[location.file]!, call = location.call
        let range = call.style ?? ByteSpan(call.argsEnd,call.argsEnd)
        let replacement = (call.style == nil ? ", style: " : "")+typstStringLiteral(style)
        let text = model.source.replacingBytes(range,with:replacement)
        func mapped(_ position: Int) -> Int {
            if position <= range.start { return position }
            if position >= range.end { return position+replacement.utf8.count-range.count }
            return range.start+replacement.utf8.count
        }
        commitReferences([location.file:text],selections:[location.file:EditSelection(mapped(model.selection.anchor),mapped(model.selection.focus))],undoPath:location.file)
    }
}
