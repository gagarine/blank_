import AppKit
import SwiftUI
import BlankCore

// A literal citation exposes its common controls. Replace only changed values,
// preserving comments and every other argument byte for byte.
struct CitationFieldEdit {
    let original: String
    let keySpan: ByteSpan
    let locatorSpan: ByteSpan?
    let formSpan: ByteSpan?
    let args: SyntaxNode?
    let shorthand: Bool
    let key: String
    let locator: String
    let form: String

    init?(_ source: String) {
        let parsed = ParsedSource.parse(source)
        guard !parsed.erroneous else { return nil }
        let nodes = parsed.tree.children.filter { !["Space","Parbreak"].contains($0.kind) }
        var keyNode: SyntaxNode, supplement: SyntaxNode?, display: SyntaxNode?, arguments: SyntaxNode?
        var short = false, name: String
        if nodes.count == 1, let ref = nodes.first, ref.kind == "Ref", let marker = ref.children.first(where:{ $0.kind == "RefMarker" }) {
            short = true; keyNode = marker; name = String(source.bytes(marker.span).dropFirst())
            supplement = ref.children.first { $0.kind == "ContentBlock" }
        } else {
            guard nodes.count == 2, nodes[0].kind == "Hash", nodes[1].kind == "FuncCall",
                  nodes[1].children.first.map({ source.bytes($0.span) }) == "cite",
                  let values = nodes[1].children.first(where:{ $0.kind == "Args" }) else { return nil }
            arguments = values
            let positional = values.children.filter { !["LeftParen","RightParen","Space","LineComment","BlockComment","Comma","Named"].contains($0.kind) }
            guard positional.count == 1, let first = positional.first else { return nil }
            keyNode = first
            if first.kind == "Label" { name = String(source.bytes(first.span).dropFirst().dropLast()) }
            else if first.kind == "FuncCall", first.children.first.map({ source.bytes($0.span) }) == "label", let literal = first.descendants("Str").first?.stringValue { name = literal }
            else { return nil }
            for named in values.children where named.kind == "Named" {
                let children = named.children.filter { !["Space","LineComment","BlockComment"].contains($0.kind) }
                guard children.count == 3 else { continue }
                switch source.bytes(children[0].span) {
                case "supplement": guard supplement == nil else { return nil }; supplement = children[2]
                case "form": guard display == nil else { return nil }; display = children[2]
                default: break
                }
            }
        }
        var page = ""
        if let supplement {
            guard supplement.kind == "ContentBlock", let markup = supplement.markup,
                  markup.children.allSatisfy({ ["Text","Space","Escape"].contains($0.kind) }) else { return nil }
            for node in markup.children {
                let raw = source.bytes(node.span); page += node.kind == "Escape" ? String(raw.dropFirst()) : raw
            }
        }
        let form = display?.stringValue ?? "normal"
        guard display == nil || display?.kind == "Str", ["normal","prose","author","year"].contains(form) else { return nil }
        self.original = source; self.keySpan = keyNode.span; self.locatorSpan = supplement?.span
        self.formSpan = display?.span; self.args = arguments; self.shorthand = short
        self.key = name; self.locator = page; self.form = form
    }
    func applying(key: String,locator: String,form: String) -> String {
        guard key != self.key || locator != self.locator || form != self.form else { return original }
        let ref = ZoteroReference(key:"",library:"",title:"",author:"",year:"",citeKey:key)
        if shorthand { return citationSource([ref],locator:locator,form:form) }
        var patches: [(ByteSpan,String)] = [], additions: [String] = []
        if key != self.key { patches.append((keySpan,safeLabel(key) == key && !key.isEmpty ? "<\(key)>" : "label(\(typstStringLiteral(key)))")) }
        if locator != self.locator {
            let value = "[\(escapeTypst(locator))]"
            if let locatorSpan { patches.append((locatorSpan,value)) } else { additions.append("supplement: "+value) }
        }
        if form != self.form {
            let value = typstStringLiteral(form)
            if let formSpan { patches.append((formSpan,value)) } else { additions.append("form: "+value) }
        }
        if !additions.isEmpty, let args, let close = args.children.last(where:{ $0.kind == "RightParen" }) {
            let previous = args.children.last { !["RightParen","Space","LineComment","BlockComment"].contains($0.kind) }
            patches.append((ByteSpan(close.start,close.start),(previous?.kind == "Comma" ? " " : ", ")+additions.joined(separator:", ")))
        }
        return patches.sorted { $0.0.start > $1.0.start }.reduce(original) { $0.replacingBytes($1.0,with:$1.1) }
    }
}

struct CitationFieldEditor: View {
    @ObservedObject var session: DocumentSession
    let edit: CitationFieldEdit
    @NativeState private var key = ""
    @NativeState private var locator = ""
    @NativeState private var form = "normal"
    var body: some View {
        SheetFrame(title:"Edit Citation",width:500,dismiss:{ session.sheet = nil }) {
            TextField("Reference",text:$key).textFieldStyle(.roundedBorder)
            TextField("Page / locator",text:$locator).textFieldStyle(.roundedBorder)
            Picker("Citation display",selection:$form) {
                Text("Standard citation").tag("normal"); Text("In a sentence").tag("prose")
                Text("Author only").tag("author"); Text("Year only").tag("year")
            }
            HStack {
                Spacer()
                Button("Cancel") { session.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Apply") { _ = session.applyObjectSource(edit.applying(key:key,locator:locator,form:form)) }.keyboardShortcut(.defaultAction).disabled(key.isEmpty)
            }
        }.onAppear { key = edit.key; locator = edit.locator; form = edit.form }
    }
}
