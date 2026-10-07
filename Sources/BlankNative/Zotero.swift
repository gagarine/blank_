import Foundation
import BlankCore

struct ZoteroReference: Codable, Identifiable {
    var key: String
    var library: String
    var title: String
    var author: String
    var year: String
    var citeKey: String
    var id: String { citeKey }
}
enum ZoteroIntegration {
    static func path(_ library: String) throws -> String {
        if library == "personal" || library.isEmpty { return "users/0" }
        if library.range(of:"^(users|groups)/[0-9]+$",options:.regularExpression) != nil { return library }
        throw failure("Choose personal or a Zotero group such as groups/123.")
    }
    static func failure(_ text: String) -> NSError { NSError(domain:"Zotero",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
    static func request(_ path: String, completion: @escaping (Result<Data,Error>)->Void) {
        guard let url = URL(string:"http://localhost:23119/api/"+path) else { completion(.failure(failure("Invalid Zotero URL"))); return }
        var request = URLRequest(url:url,timeoutInterval:8); request.setValue("3",forHTTPHeaderField:"Zotero-API-Version")
        URLSession.shared.dataTask(with:request) { data,response,error in
            if let data, let response = response as? HTTPURLResponse, response.statusCode == 200 { completion(.success(data)) }
            else { completion(.failure(failure("Cannot access Zotero. Open Zotero → Settings → Advanced and enable ‘Allow other applications on this computer to communicate with Zotero’. \(error?.localizedDescription ?? "Check the selected library.")"))) }
        }.resume()
    }
    static func search(query: String,library: String,completion: @escaping (Result<[ZoteroReference],Error>)->Void) {
        do {
            let p = try path(library)
            let q = query.addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed.subtracting(CharacterSet(charactersIn:"&+#="))) ?? ""
            request(p+"/items/top?limit=40&includeTrashed=0&q="+q+"&qmode=titleCreatorYear") { response in
                let result = response.flatMap { data -> Result<[ZoteroReference],Error> in
                    do {
                        let items = try JSONSerialization.jsonObject(with:data) as? [[String:Any]] ?? []
                        let refs = items.compactMap { item -> ZoteroReference? in
                            guard let key = item["key"] as? String, let fields = item["data"] as? [String:Any], !["attachment","note"].contains(fields["itemType"] as? String ?? "") else { return nil }
                            let authors = (fields["creators"] as? [[String:Any]] ?? []).compactMap { $0["lastName"] as? String ?? $0["name"] as? String }.joined(separator:", ")
                            let date = fields["date"] as? String ?? "", year = date.range(of:"[0-9]{4}",options:.regularExpression).map { String(date[$0]) } ?? ""
                            let info = item["library"] as? [String:Any]
                            let identifier = (info?["id"] as? NSNumber)?.stringValue ?? info?["id"] as? String
                            let actualLibrary = identifier.map { (info?["type"] as? String == "group" ? "groups/" : "users/")+$0 } ?? p
                            return ZoteroReference(key:key,library:actualLibrary,title:fields["title"] as? String ?? "Untitled",author:authors,year:year,citeKey:"zotero-"+actualLibrary.replacingOccurrences(of:"/",with:"-")+"-"+key)
                        }
                        return .success(refs)
                    } catch { return .failure(error) }
                }
                DispatchQueue.main.async { completion(result) }
            }
        } catch { completion(.failure(error)) }
    }
    static func bib(_ ref: ZoteroReference, completion: @escaping (Result<String,Error>)->Void) {
        do {
            let p = try path(ref.library)
            guard ref.key.range(of:"^[A-Z0-9]{8}$",options:.regularExpression) != nil else { throw failure("Invalid Zotero item key") }
            request(p+"/items/"+ref.key+"?format=biblatex") { response in
                completion(response.flatMap { data in
                    guard let text = String(data:data,encoding:.utf8), let brace = text.firstIndex(of:"{"), let comma = text[brace...].firstIndex(of:",") else { return .failure(failure("Zotero did not return BibLaTeX.")) }
                    return .success(String(text[...brace])+ref.citeKey+String(text[comma...])+"\n")
                })
            }
        } catch { completion(.failure(error)) }
    }
    static func collect(_ refs: [ZoteroReference],completion: @escaping (Result<[String],Error>)->Void) {
        if refs.isEmpty { completion(.success([])); return }
        // Sequential requests keep Zotero load bounded and maintain stable metadata ordering.
        bib(refs[0]) { result in
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(entry): collect(Array(refs.dropFirst())) { completion($0.map { [entry]+$0 }) }
            }
        }
    }
    @MainActor static func linked(_ text: String,format: String) throws -> [ZoteroReference] {
        let links = format == "bib" ? BibLaTeX.linked(text).map { ($0.0.key,$0.1,$0.2) } : try Hayagriva.linked(text)
        return links.map { cite,key,library in ZoteroReference(key:key,library:library,title:"",author:"",year:"",citeKey:cite) }
    }
    @MainActor static func merge(_ text: String,refs: [ZoteroReference],entries: [String],format: String,compiler: TypstCompiler,completion: @escaping (Result<String,Error>) -> Void) {
        guard let ref = refs.first, let entry = entries.first else { completion(.success(text)); return }
        func next(_ result: Result<String,Error>) {
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(text): merge(text,refs:Array(refs.dropFirst()),entries:Array(entries.dropFirst()),format:format,compiler:compiler,completion:completion)
            }
        }
        if format == "bib" {
            next(Result { try BibLaTeX.merge(text,key:ref.citeKey,exported:BibLaTeX.annotate(entry,key:ref.key,library:path(ref.library))) })
        } else {
            compiler.hayagriva(entry) { result in
                next(result.flatMap { yaml in Result { try Hayagriva.merge(text,key:ref.citeKey,exported:yaml,itemKey:ref.key,library:path(ref.library)) } })
            }
        }
    }
    @MainActor static func insert(_ refs: [ZoteroReference],session: DocumentSession,anchor: EditSelection,locator: String,form: String,destinationID: String? = nil,completion: @escaping (Error?)->Void) {
        guard !refs.isEmpty else { completion(failure("Select a reference.")); return }
        session.editor?.finishComposition()
        if refs.allSatisfy({ $0.key.isEmpty }) {
            guard session.requestEditing() else { completion(failure("The document is locked.")); return }
            session.insertionAnchor = anchor
            session.insertSource(citationSource(refs,locator:locator,form:form))
            completion(nil); return
        }
        if session.root != nil, session.dependencyRevision != session.revision {
            session.prepareProjectCopy { error in
                if let error { completion(error); return }
                insert(refs,session:session,anchor:anchor,locator:locator,form:form,destinationID:destinationID,completion:completion)
            }
            return
        }
        session.loadBibliographies()
        let destination: ReferenceDestination, oldText: String, selected: [ZoteroReference], imports: [ZoteroReference]
        do {
            let options = try session.referenceDestinations()
            guard let choice = destinationID.flatMap({ id in options.first { $0.id == id } }) ?? (options.count == 1 ? options[0] : nil) else { throw failure("Choose a bibliography destination before inserting.") }
            destination = choice; oldText = try session.referenceText(choice)
            let existing = try linked(oldText,format:choice.format)
            var used = Set<String>()
            for option in options {
                let text = try session.referenceText(option)
                used.formUnion(option.format == "bib" ? BibLaTeX.entries(text).map(\.key) : try Hayagriva.entries(text).map(\.key))
            }
            selected = refs.map { ref in
                var ref = ref
                if ref.key.isEmpty { return ref }
                if let saved = existing.first(where:{ $0.key == ref.key && (try? path($0.library)) == (try? path(ref.library)) }) { ref.citeKey = saved.citeKey }
                else {
                    let base = ref.citeKey; var suffix = 2
                    while used.contains(ref.citeKey) { ref.citeKey = base+"-\(suffix)"; suffix += 1 }
                }
                used.insert(ref.citeKey); return ref
            }
            imports = selected.filter { ref in !ref.key.isEmpty && !existing.contains(where:{ $0.citeKey == ref.citeKey && $0.key == ref.key && (try? path($0.library)) == (try? path(ref.library)) }) }
        } catch { completion(error); return }
        let revision = session.revision, active = session.active
        collect(imports) { response in DispatchQueue.main.async {
            switch response {
            case let .failure(error): completion(error)
            case let .success(entries):
                merge(oldText,refs:imports,entries:entries,format:destination.format,compiler:session.compiler) { result in
                    guard session.revision == revision, session.active == active else { completion(failure("Document changed while fetching references. Try again.")); return }
                    do {
                        let bibliography = try result.get()
                        guard session.requestEditing() else { throw failure("The document is locked.") }
                        let original = session.buffer.source
                        var texts = [destination.file:session.referenceSource(bibliography,destination:destination)]
                        var source = texts[active] ?? original
                        var start = anchor.span.start, end = anchor.span.end
                        if active == destination.file, let patch = SourcePatch.difference(original,source) {
                            if patch.oldSpan.end <= start && patch.start < start { let delta = patch.inserted.utf8.count-patch.removed.utf8.count; start += delta; end += delta }
                            else if patch.start < end && patch.oldSpan.end > start { throw failure("Place the citation outside the bibliography data.") }
                        }
                        let cites = citationSource(selected,locator:locator,form:form)
                        source = source.replacingBytes(ByteSpan(start,end),with:cites); texts[active] = source
                        let caret = start+cites.utf8.count
                        session.commitReferences(texts,selections:[active:EditSelection(caret,caret)],undoPath:active)
                        completion(nil)
                    } catch { completion(error) }
                }
            }
        } }
    }
    @MainActor static func refresh(_ session: DocumentSession,completion: ((Error?) -> Void)? = nil) {
        session.editor?.finishComposition()
        if session.root != nil, session.dependencyRevision != session.revision {
            session.prepareProjectCopy { error in
                if let error { session.error = error.localizedDescription; completion?(error); return }
                refresh(session,completion:completion)
            }
            return
        }
        session.loadBibliographies()
        let revision = session.revision
        var work: [(ReferenceDestination,String,[ZoteroReference])] = []
        do {
            for destination in try session.referenceDestinations() where destination.input != nil {
                let text = try session.referenceText(destination), refs = try linked(text,format:destination.format)
                if !refs.isEmpty { work.append((destination,text,refs)) }
            }
            guard !work.isEmpty else { throw failure("No linked Zotero entries in the document’s bibliographies.") }
        } catch { session.error = error.localizedDescription; completion?(error); return }
        var replacements: [(ReferenceDestination,String)] = []
        func next(_ index: Int) {
            guard index < work.count else {
                guard session.revision == revision else { let error = failure("Document changed while refreshing references. Try again."); session.error = error.localizedDescription; completion?(error); return }
                guard session.requestEditing() else { completion?(failure("The document is locked.")); return }
                var texts: [String:String] = [:], selections: [String:EditSelection] = [:]
                for (destination,text) in replacements.sorted(by:{ ($0.0.input?.span.start ?? 0) > ($1.0.input?.span.start ?? 0) }) {
                    let original = texts[destination.file] ?? session.buffers[destination.file]!.source
                    let updated = session.referenceSource(text,destination:destination,source:original)
                    var selection = selections[destination.file] ?? session.buffers[destination.file]!.selection
                    if let patch = SourcePatch.difference(original,updated) { selection = selection.mapped(through:patch) }
                    texts[destination.file] = updated; selections[destination.file] = selection
                }
                let undoPath = texts[session.active] != nil ? session.active : work[0].0.file
                session.commitReferences(texts,selections:selections,undoPath:undoPath); completion?(nil); return
            }
            let (destination,text,refs) = work[index]
            collect(refs) { response in DispatchQueue.main.async {
                switch response {
                case let .failure(error): session.error = error.localizedDescription; completion?(error)
                case let .success(entries):
                    merge(text,refs:refs,entries:entries,format:destination.format,compiler:session.compiler) { result in
                        switch result {
                        case let .failure(error): session.error = error.localizedDescription; completion?(error)
                        case let .success(updated): replacements.append((destination,updated)); next(index+1)
                        }
                    }
                }
            } }
        }
        next(0)
    }
}

func citationSource(_ refs: [ZoteroReference],locator: String,form: String) -> String {
    refs.map { ref in
        ("#cite("+(safeLabel(ref.citeKey) == ref.citeKey && !ref.citeKey.isEmpty ? "<\(ref.citeKey)>" : "label(\(typstStringLiteral(ref.citeKey)))"))+(locator.isEmpty ? "" : ", supplement: [\(escapeTypst(locator))]")+(form == "normal" ? "" : ", form: \(typstStringLiteral(form))")+")"
    }.joined(separator:" ")
}
