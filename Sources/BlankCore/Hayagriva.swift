import Foundation

// Localized editing for ordinary block-mapping Hayagriva files. Unsupported
// flow mappings/aliases remain compileable, but are never silently rewritten.
public enum Hayagriva {
    public struct Entry {
        public var key: String
        public var span: ByteSpan
        public var fields: [String:ByteSpan]
    }
    public static func entries(_ text: String) throws -> [Entry] {
        var rows: [(String,Int,Int)] = [], offset = 0
        for line in text.split(separator:"\n",omittingEmptySubsequences:false) {
            let value = String(line); rows.append((value,offset,offset+value.utf8.count)); offset += value.utf8.count+1
        }
        var result: [Entry] = []
        var fieldName: String?, fieldStart = 0, fieldEnd = 0, fieldIndent: Int?
        func flushField() {
            if let name = fieldName, !result.isEmpty { result[result.count-1].fields[name] = ByteSpan(fieldStart,fieldEnd) }
            fieldName = nil
        }
        for (line,start,end) in rows {
            let trimmed = line.trimmingCharacters(in:.whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" { continue }
            if let colon = trimmed.firstIndex(of:":") {
                let value = trimmed[trimmed.index(after:colon)...].trimmingCharacters(in:.whitespaces)
                if trimmed.hasPrefix("<<:") || value.hasPrefix("&") || value.hasPrefix("*") { throw BibLaTeX.failure("Hayagriva aliases remain editable in Source; Zotero will not rewrite them.") }
            }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                flushField()
                let pattern = #"^("(?:\.|[^"])*"|'(?:''|[^'])*'|[^:]+):\s*(?:#.*)?$"#
                let regex = try NSRegularExpression(pattern:pattern)
                guard let match = regex.firstMatch(in:line,range:NSRange(location:0,length:line.utf16.count)) else { throw BibLaTeX.failure("Zotero editing requires a block-mapping Hayagriva bibliography. Edit this YAML in Source.") }
                let keyText = (line as NSString).substring(with:match.range(at:1))
                fieldIndent = nil
                if !result.isEmpty { result[result.count-1].span.end = start }
                let raw = keyText; let key: String
                if raw.hasPrefix("\"") { guard let value = try? JSONDecoder().decode(String.self,from:Data(raw.utf8)) else { throw BibLaTeX.failure("Unsupported YAML citation key.") }; key = value }
                else if raw.hasPrefix("'") && raw.hasSuffix("'") { key = String(raw.dropFirst().dropLast()).replacingOccurrences(of:"''",with:"'") }
                else { key = raw }
                guard !result.contains(where:{ $0.key == key }) else { throw BibLaTeX.failure("Duplicate YAML citation keys.") }
                result.append(Entry(key:key,span:ByteSpan(start,text.utf8.count),fields:[:]))
            } else {
                let indent = line.prefix { $0 == " " }.count
                if fieldIndent == nil { fieldIndent = indent }
                if indent == fieldIndent, let colon = line.firstIndex(of:":") {
                    flushField(); fieldName = String(line[..<colon]).trimmingCharacters(in:.whitespaces); fieldStart = start; fieldEnd = min(end+1,text.utf8.count)
                } else { fieldEnd = min(end+1,text.utf8.count) }
            }
        }
        flushField(); return result
    }
    public static func linked(_ text: String) throws -> [(String,String,String)] {
        try entries(text).compactMap { entry in
            func value(_ name: String) -> String? {
                guard let range = entry.fields[name], let colon = text.bytes(range).firstIndex(of:":") else { return nil }
                let raw = String(text.bytes(range)[text.bytes(range).index(after:colon)...]).trimmingCharacters(in:.whitespacesAndNewlines)
                return (try? JSONDecoder().decode(String.self,from:Data(raw.utf8))) ?? raw
            }
            guard let key = value("x-blank-zotero-key"), let library = value("x-blank-zotero-library") else { return nil }
            return (entry.key,key,library)
        }
    }
    public static func merge(_ text: String,key: String,exported: String,itemKey: String,library: String) throws -> String {
        let managed = try entries(exported).first?.fields.keys.sorted().joined(separator:",") ?? ""
        let freshText = exported.trimmingCharacters(in:.newlines)+"\n  x-blank-zotero-key: \(typstStringLiteral(itemKey))\n  x-blank-zotero-library: \(typstStringLiteral(library))\n  x-blank-zotero-fields: \(typstStringLiteral(managed))\n"
        guard let fresh = try entries(freshText).first, fresh.key == key else { throw BibLaTeX.failure("Invalid Hayagriva export.") }
        guard let old = try entries(text).first(where:{ $0.key == key }) else { return text+"\n"+freshText }
        var result = text
        let indent = old.fields.values.min(by:{ $0.start < $1.start }).map { text.bytes($0).prefix { $0 == " " }.count } ?? 2
        func adjusted(_ source: String) -> String {
            source.split(separator:"\n",omittingEmptySubsequences:false).map { line in
                line.hasPrefix("  ") ? String(repeating:" ",count:indent)+line.dropFirst(2) : String(line)
            }.joined(separator:"\n")
        }
        var added = fresh.fields.keys.sorted().filter { old.fields[$0] == nil }.map { adjusted(freshText.bytes(fresh.fields[$0]!)) }.joined()
        if !added.isEmpty, !text.bytes(ByteSpan(0,old.span.end)).hasSuffix("\n") { added = "\n"+added }
        result = result.replacingBytes(ByteSpan(old.span.end,old.span.end),with:added)
        var replacements = fresh.fields.keys.compactMap { name -> (ByteSpan,String)? in
            guard let span = old.fields[name] else { return nil }
            let comments = text.bytes(span).split(separator:"\n",omittingEmptySubsequences:false).filter { $0.trimmingCharacters(in:.whitespaces).hasPrefix("#") }.joined(separator:"\n")
            return (span,adjusted(freshText.bytes(fresh.fields[name]!))+(comments.isEmpty ? "" : comments+"\n"))
        }
        if let span = old.fields["x-blank-zotero-fields"], let colon = text.bytes(span).firstIndex(of:":") {
            let value = String(text.bytes(span)[text.bytes(span).index(after:colon)...]).trimmingCharacters(in:.whitespacesAndNewlines)
            let managed = (try? JSONDecoder().decode(String.self,from:Data(value.utf8))) ?? value
            for name in managed.split(separator:",").map(String.init) where fresh.fields[name] == nil {
                if let span = old.fields[name] {
                    let comments = text.bytes(span).split(separator:"\n").filter { $0.trimmingCharacters(in:.whitespaces).hasPrefix("#") }.joined(separator:"\n")
                    replacements.append((span,comments.isEmpty ? "" : comments+"\n"))
                }
            }
        }
        for (span,value) in replacements.sorted(by:{ $0.0.start > $1.0.start }) { result = result.replacingBytes(span,with:value) }
        return result
    }
}
