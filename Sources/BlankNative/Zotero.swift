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
        if library.range(of:"^groups/[0-9]+$",options:.regularExpression) != nil { return library }
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
                            return ZoteroReference(key:key,library:library,title:fields["title"] as? String ?? "Untitled",author:authors,year:year,citeKey:"zotero-"+p.replacingOccurrences(of:"/",with:"-")+"-"+key)
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
    static func upsert(_ text: String,key: String,entry: String) -> String {
        guard let regex = try? NSRegularExpression(pattern:"(?m)@[A-Za-z]+\\s*\\{\\s*"+NSRegularExpression.escapedPattern(for:key)+"\\s*,"), let match = regex.firstMatch(in:text,range:NSRange(location:0,length:text.utf16.count)) else { return text+"\n"+entry }
        let ns = text as NSString
        var depth = 0, escaped = false
        for i in match.range.location..<ns.length {
            let ch = ns.character(at:i)
            if escaped { escaped = false; continue }
            if ch == 92 { escaped = true; continue }
            if ch == 123 { depth += 1 }; if ch == 125 { depth -= 1; if depth == 0 { return ns.replacingCharacters(in:NSRange(location:match.range.location,length:i+1-match.range.location),with:entry.trimmingCharacters(in:.newlines)) } }
        }
        return text
    }
    @MainActor static func insert(_ refs: [ZoteroReference],session: DocumentSession,anchor: EditSelection,locator: String,form: String,completion: @escaping (Error?)->Void) {
        guard !refs.isEmpty else { completion(failure("Select a reference.")); return }
        let revision = session.revision, active = session.active
        collect(refs) { response in
            DispatchQueue.main.async {
                guard session.revision == revision, session.active == active else { completion(failure("Document changed while fetching references. Try again.")); return }
                switch response {
                case let .failure(error): completion(error)
                case let .success(entries):
                    guard session.requestEditing() else { completion(failure("The document is locked.")); return }
                    var bib = session.buffers["writer-zotero.bib"]?.source ?? ""
                    var metadata = (session.buffers["writer-references.json"].flatMap { try? JSONDecoder().decode([String:ZoteroReference].self,from:Data($0.source.utf8)) }) ?? [:]
                    for (ref,entry) in zip(refs,entries) { bib = upsert(bib,key:ref.citeKey,entry:entry); metadata[ref.citeKey] = ref }
                    session.buffers["writer-zotero.bib"] = DocumentBuffer(bib)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                    session.buffers["writer-references.json"] = DocumentBuffer(String(data:try! encoder.encode(metadata),encoding:.utf8)!+"\n")
                    let cites = refs.map { ref -> String in
                        return "#cite(<\(ref.citeKey)>"+(locator.isEmpty ? "" : ", supplement: [\(escapeTypst(locator))]")+(form == "normal" ? "" : ", form: \(jsonString(form))")+")"
                    }.joined(separator:" ")
                    var text = session.buffer.source.replacingBytes(anchor.span,with:cites)
                    if active == session.entry && !text.contains("writer-zotero.bib") { text += "\n\n#bibliography(\"writer-zotero.bib\", style: \"apa\")\n" }
                    session.buffer.commit(text,selection:EditSelection(anchor.span.start+cites.utf8.count,anchor.span.start+cites.utf8.count))
                    if active != session.entry, let root = session.buffers[session.entry], !root.source.contains("writer-zotero.bib") { root.commit(root.source+"\n\n#bibliography(\"writer-zotero.bib\", style: \"apa\")\n",selection:root.selection) }
                    session.changed(); completion(nil)
                }
            }
        }
    }
    @MainActor static func refresh(_ session: DocumentSession) {
        guard let buffer = session.buffers["writer-references.json"], let refs = try? JSONDecoder().decode([String:ZoteroReference].self,from:Data(buffer.source.utf8)) else { session.error = "No saved Zotero references."; return }
        let ordered = refs.values.sorted { $0.citeKey < $1.citeKey }
        let revision = session.revision
        collect(ordered) { result in DispatchQueue.main.async {
            guard session.revision == revision else { session.error = "Document changed while refreshing references. Try again."; return }
            switch result {
            case let .failure(error): session.error = error.localizedDescription
            case let .success(entries):
                guard session.requestEditing() else { return }
                let bib = session.buffers["writer-zotero.bib"] ?? DocumentBuffer()
                var text = bib.source
                for (ref,entry) in zip(ordered,entries) { text = upsert(text,key:ref.citeKey,entry:entry) }
                bib.commit(text,selection:bib.selection); session.buffers["writer-zotero.bib"] = bib; session.changed()
            }
        } }
    }
}
