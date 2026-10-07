import Foundation
import BlankCore

// Read literal keys from the parser, never from comments, strings or raw code.
func literalCitationKeys(_ source: String,_ parsed: ParsedSource) -> Set<String> {
    var keys = Set<String>()
    for reference in parsed.tree.descendants("Ref") {
        let raw = source.bytes(reference.span)
        if raw.hasPrefix("@") { keys.insert(String(raw.dropFirst().prefix { !$0.isWhitespace && $0 != "[" })) }
    }
    for call in parsed.tree.descendants("FuncCall") where call.children.first.map({ source.bytes($0.span) }) == "cite" {
        guard let args = call.children.first(where:{ $0.kind == "Args" }),
              let value = args.children.first(where:{ !["LeftParen","RightParen","Space","LineComment","BlockComment","Comma","Named"].contains($0.kind) }) else { continue }
        if value.kind == "Label" { keys.insert(String(source.bytes(value.span).dropFirst().dropLast())) }
        else if value.kind == "FuncCall", value.children.first.map({ source.bytes($0.span) }) == "label",
                let string = value.descendants("Str").first?.stringValue { keys.insert(string) }
    }
    return keys
}

struct CitationChoices {
    var cited: [ZoteroReference] = []
    var keys: Set<String> { Set(cited.map(\.citeKey)) }
    func results(_ live: [ZoteroReference],query: String) -> [ZoteroReference] {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        let first = cited.filter { query.isEmpty || ($0.title+" "+$0.author+" "+$0.year+" "+$0.citeKey).localizedCaseInsensitiveContains(query) }
        var result = first, seen = Set(first.map(\.id))
        for var ref in live {
            // A linked reference can have a custom key in this document.
            if let saved = cited.first(where:{ !$0.key.isEmpty && $0.key == ref.key && (try? ZoteroIntegration.path($0.library)) == (try? ZoteroIntegration.path(ref.library)) }) { ref.citeKey = saved.citeKey }
            if seen.insert(ref.id).inserted { result.append(ref) }
        }
        // Live search can match metadata absent from the saved entry too.
        return result.filter { keys.contains($0.citeKey) }+result.filter { !keys.contains($0.citeKey) }
    }
}

@MainActor extension DocumentSession {
    func citationChoices() -> CitationChoices {
        var keys = Set<String>(), records: [String:ZoteroReference] = [:]
        let files = projectFiles.union([active]).union(dependencyRevision == revision ? compiledDependencies.filter { $0.hasSuffix(".typ") } : [])
        for file in files {
            if let model = buffers[file] { keys.formUnion(literalCitationKeys(model.source,model.parsed)) }
            else if let root, let url = try? Self.dependencyTarget(file,root:root), let text = try? String(contentsOf:url,encoding:.utf8) { keys.formUnion(literalCitationKeys(text,ParsedSource.parse(text))) }
        }
        for destination in (try? referenceDestinations()) ?? [] {
            guard let text = try? referenceText(destination) else { continue }
            let linked = (try? ZoteroIntegration.linked(text,format:destination.format)) ?? []
            func record(_ key: String,_ title: String?,_ author: String?,_ year: String?) {
                guard keys.contains(key), records[key] == nil else { return }
                var ref = linked.first { $0.citeKey == key } ?? ZoteroReference(key:"",library:"",title:"",author:"",year:"",citeKey:key)
                ref.title = title.flatMap { $0.isEmpty ? nil : $0 } ?? key; ref.author = author ?? ""; ref.year = year ?? ""
                records[key] = ref
            }
            if destination.format == "bib" {
                for entry in BibLaTeX.entries(text) { record(entry.key,entry.value("title",in:text),entry.value("author",in:text),entry.value("year",in:text) ?? entry.value("date",in:text)) }
            } else {
                for entry in (try? Hayagriva.entries(text)) ?? [] {
                    func value(_ name: String) -> String? {
                        guard let span = entry.fields[name] else { return nil }
                        let raw = text.bytes(span)
                        guard let colon = raw.firstIndex(of:":") else { return nil }
                        let value = String(raw[raw.index(after:colon)...]).trimmingCharacters(in:.whitespacesAndNewlines)
                        return (try? JSONDecoder().decode(String.self,from:Data(value.utf8))) ?? value
                    }
                    record(entry.key,value("title"),value("author"),value("date"))
                }
            }
        }
        return CitationChoices(cited:records.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }
}
