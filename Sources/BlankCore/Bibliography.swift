import Foundation

public struct BibliographyInput {
    public var span: ByteSpan
    public var expression: ByteSpan
    public var path: String?
    public var embedded: String?
    public var format: String
    public init(span: ByteSpan,path: String? = nil,embedded: String? = nil,format: String,expression: ByteSpan? = nil) {
        self.span = span; self.expression = expression ?? span; self.path = path; self.embedded = embedded; self.format = format
    }
}
public struct BibliographyCall {
    public var span: ByteSpan
    public var inputs: [BibliographyInput]
    public var style: ByteSpan?
    public var argsEnd: Int
}
public func bibliographyCalls(_ source: String,_ parsed: ParsedSource) -> [BibliographyCall] {
    let trivia = Set(["Space","LineComment","BlockComment","LeftParen","RightParen","Comma"])
    let bindings = parsed.tree.children.filter { $0.kind == "LetBinding" }.reduce(into:[String:SyntaxNode]()) { bindings,node in
        if let name = node.children.first(where:{ $0.kind == "Ident" }), let value = node.children.last(where:{ !["Space","LineComment","BlockComment"].contains($0.kind) }) { bindings[source.bytes(name.span)] = value }
    }
    func input(_ node: SyntaxNode,_ seen: Set<String> = []) -> BibliographyInput? {
        if node.kind == "Ident" {
            let name = source.bytes(node.span)
            if !seen.contains(name), let value = bindings[name] { return input(value,seen.union([name])) }
        }
        if node.kind == "Str", let value = node.stringValue { return BibliographyInput(span:node.span,path:value,format:(value as NSString).pathExtension.lowercased()) }
        if node.kind == "FuncCall", node.children.first.map({ source.bytes($0.span) }) == "bytes",
           let args = node.children.first(where:{ $0.kind == "Args" }) {
            let values = args.children.filter { !trivia.contains($0.kind) }
            var valueNode = values.first
            var visited = seen
            while let node = valueNode, node.kind == "Ident", let value = bindings[source.bytes(node.span)], !visited.contains(source.bytes(node.span)) {
                visited.insert(source.bytes(node.span)); valueNode = value
            }
            if values.count == 1, let valueNode, let value = valueNode.stringValue { return BibliographyInput(span:valueNode.span,embedded:value,format:["@","%"].contains(where:{ value.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix($0) }) ? "bib" : "yaml",expression:node.span) }
            if values.count == 1, let valueNode, valueNode.kind == "FieldAccess", source.bytes(valueNode.span).hasSuffix(".text"), let raw = valueNode.descendants("Raw").first, let text = raw.rawText {
                return BibliographyInput(span:valueNode.span,embedded:text,format:raw.children.contains(where:{ $0.kind == "RawLang" && ["bib","bibtex","biblatex"].contains(source.bytes($0.span)) }) || ["@","%"].contains(where:{ text.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix($0) }) ? "bib" : "yaml",expression:node.span)
            }
        }
        return nil
    }
    return parsed.tree.descendants("FuncCall").compactMap { call in
        guard call.children.first.map({ source.bytes($0.span) }) == "bibliography", let args = call.children.first(where:{ $0.kind == "Args" }) else { return nil }
        let values = args.children.filter { !trivia.contains($0.kind) && $0.kind != "Named" }
        let inputs = values.flatMap { node -> [BibliographyInput] in
            let nodes = node.kind == "Array" ? node.children.filter { !trivia.contains($0.kind) } : [node]
            return nodes.map { input($0) ?? BibliographyInput(span:$0.span,format:"computed") }
        }
        let style = args.children.first { $0.kind == "Named" && $0.children.first.map({ source.bytes($0.span) }) == "style" }?.children.last?.span
        return BibliographyCall(span:call.span,inputs:inputs,style:style,argsEnd:args.end-1)
    }
}

public struct BibliographyEntry {
    public var key: String
    public var type: ByteSpan
    public var declarations: [String:ByteSpan]
    public var separators: [String:ByteSpan]
    public var span: ByteSpan
    public var fields: [String:ByteSpan]
    public var insertion: Int
    public func value(_ name: String,in text: String) -> String? {
        guard let span = fields[name] else { return nil }
        let value = text.bytes(span).trimmingCharacters(in:.whitespacesAndNewlines)
        if (value.hasPrefix("{") && value.hasSuffix("}")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) { return String(value.dropFirst().dropLast()) }
        return value
    }
}

// Ranges address the original bytes. Never serialize a whole bibliography:
// comments, string macros, unrelated entries and user fields keep their spelling.
public enum BibLaTeX {
    public static func entries(_ text: String) -> [BibliographyEntry] {
        let b = Array(text.utf8); var i = 0, result: [BibliographyEntry] = []
        func skip(_ at: inout Int) {
            while at < b.count {
                if [9,10,13,32].contains(b[at]) { at += 1 }
                else if b[at] == 37 { while at < b.count && b[at] != 10 { at += 1 } }
                else { break }
            }
        }
        func token(_ at: inout Int) -> String {
            let start = at
            while at < b.count && (b[at] >= 65 && b[at] <= 90 || b[at] >= 97 && b[at] <= 122 || b[at] >= 48 && b[at] <= 57 || [45,95,58,46].contains(b[at])) { at += 1 }
            return String(decoding:b[start..<at],as:UTF8.self)
        }
        while i < b.count {
            skip(&i); guard i < b.count else { break }
            guard b[i] == 64 else { i += 1; continue }
            let start = i; i += 1; let kind = token(&i).lowercased(); let type = ByteSpan(start+1,i); skip(&i)
            guard i < b.count && [123,40].contains(b[i]) else { continue }
            let close: UInt8 = b[i] == 123 ? 125 : 41; i += 1
            let content = i; var depth = 0, quoted = false, escaped = false
            while i < b.count {
                let c = b[i]
                if escaped { escaped = false; i += 1; continue }
                if c == 92 { escaped = true; i += 1; continue }
                if c == 37 && !quoted { while i < b.count && b[i] != 10 { i += 1 }; continue }
                if c == 34 && depth == 0 { quoted.toggle() }
                if !quoted {
                    if c == close && depth == 0 { break }
                    if c == 123 { depth += 1 }; if c == 125 { depth -= 1 }
                }
                i += 1
            }
            guard i < b.count else { break }
            let end = i; i += 1
            guard !["comment","preamble","string"].contains(kind), !kind.isEmpty else { continue }
            var at = content; skip(&at); let keyStart = at
            while at < end && b[at] != 44 { at += 1 }
            guard at < end else { continue }
            let key = String(decoding:b[keyStart..<at],as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines); at += 1
            var fields: [String:ByteSpan] = [:], declarations: [String:ByteSpan] = [:], separators: [String:ByteSpan] = [:]
            while at < end {
                skip(&at); if at < end && b[at] == 44 { at += 1; continue }
                let declarationStart = at
                let name = token(&at).lowercased(); skip(&at)
                guard !name.isEmpty, at < end, b[at] == 61 else { break }
                at += 1; skip(&at); let valueStart = at
                var d = 0, q = false, e = false, valueEnd = at
                while at < end {
                    let c = b[at]
                    if e { e = false; at += 1; valueEnd = at; continue }
                    if c == 92 { e = true; at += 1; valueEnd = at; continue }
                    if c == 37 && d == 0 && !q { while at < end && b[at] != 10 { at += 1 }; continue }
                    if c == 34 && d == 0 { q.toggle() }
                    if !q { if c == 123 { d += 1 }; if c == 125 { d -= 1 }; if c == 44 && d == 0 { break } }
                    at += 1
                    if ![9,10,13,32].contains(c) { valueEnd = at }
                }
                while valueEnd > valueStart && [9,10,13,32].contains(b[valueEnd-1]) { valueEnd -= 1 }
                fields[name] = ByteSpan(valueStart,valueEnd); declarations[name] = ByteSpan(declarationStart,valueEnd)
                if at < end { separators[name] = ByteSpan(at,at+1); at += 1 }
            }
            result.append(BibliographyEntry(key:key,type:type,declarations:declarations,separators:separators,span:ByteSpan(start,i),fields:fields,insertion:end))
        }
        return result
    }
    public static func merge(_ text: String,key: String,exported: String) throws -> String {
        guard let fresh = entries(exported).first, fresh.key == key else { throw failure("Invalid BibLaTeX export.") }
        let matches = entries(text).filter { $0.key == key }
        guard matches.count <= 1 else { throw failure("The bibliography contains duplicate citation keys.") }
        guard let old = matches.first else { return text+(text.hasSuffix("\n") ? "\n" : "\n\n")+exported.trimmingCharacters(in:.newlines)+"\n" }
        var result = text
        // Update only exported fields; preserve unknown/custom fields and comments.
        var replacements = fresh.fields.compactMap { name,span -> (ByteSpan,String)? in old.fields[name].map { ($0,exported.bytes(span)) } }
        replacements.append((old.type,exported.bytes(fresh.type)))
        let managed = old.value("x-blank-zotero-fields",in:text)?.split(separator:",").map(String.init) ?? []
        for name in managed where fresh.fields[name] == nil {
            if let span = old.declarations[name] { replacements.append((span,"")) }
            if let comma = old.separators[name] { replacements.append((comma,"")) }
        }
        let added = fresh.fields.keys.sorted().filter { old.fields[$0] == nil }.map { "  \($0) = \(exported.bytes(fresh.fields[$0]!))" }
        if !added.isEmpty {
            let prefix = text.bytes(ByteSpan(old.span.start,old.insertion)).trimmingCharacters(in:.whitespacesAndNewlines)
            result = result.replacingBytes(ByteSpan(old.insertion,old.insertion),with:(prefix.hasSuffix(",") ? "" : ",")+"\n"+added.joined(separator:",\n")+"\n")
        }
        for (span,value) in replacements.sorted(by:{ $0.0.start > $1.0.start }) { result = result.replacingBytes(span,with:value) }
        return result
    }
    public static func linked(_ text: String) -> [(BibliographyEntry,String,String)] {
        entries(text).compactMap { entry in
            guard let key = entry.value("x-blank-zotero-key",in:text), let library = entry.value("x-blank-zotero-library",in:text) else { return nil }
            return (entry,key,library)
        }
    }
    public static func annotate(_ exported: String,key: String,library: String) throws -> String {
        guard let entry = entries(exported).first, key.range(of:"^[A-Z0-9]{8}$",options:.regularExpression) != nil,
              library == "personal" || library.range(of:"^(users|groups)/[0-9]+$",options:.regularExpression) != nil else { throw failure("Invalid Zotero linkage.") }
        return exported.replacingBytes(ByteSpan(entry.insertion,entry.insertion),with:(exported.bytes(ByteSpan(entry.span.start,entry.insertion)).trimmingCharacters(in:.whitespacesAndNewlines).hasSuffix(",") ? "" : ",")+"\n  x-blank-zotero-key = {\(key)},\n  x-blank-zotero-library = {\(library)},\n  x-blank-zotero-fields = {\(entry.fields.keys.filter { !$0.hasPrefix("x-blank-") }.sorted().joined(separator:","))}\n")
    }
    static func failure(_ message: String) -> NSError { NSError(domain:"Bibliography",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
}
