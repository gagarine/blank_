import Foundation

// Common controls for literal image figures. Keep the original call and patch
// only changed values; custom expressions retain the exact-source editor.
public struct FigureFieldEdit {
    public let original: String
    public let path: String
    public let caption: String
    public let alt: String
    public let width: Double?
    private let pathSpan: ByteSpan
    private let captionSpan: ByteSpan?
    private let altSpan: ByteSpan?
    private let widthArgument: SyntaxNode?
    private let figureArgs: SyntaxNode?
    private let imageArgs: SyntaxNode
    public var supportsCaption: Bool { figureArgs != nil }
    private static let trivia = Set(["Space","Parbreak","LineComment","BlockComment"])

    public init?(_ source: String) {
        let parsed = ParsedSource.parse(source)
        guard !parsed.erroneous else { return nil }
        let nodes = parsed.tree.children.filter { !Self.trivia.contains($0.kind) }
        guard nodes.count >= 2, nodes[0].kind == "Hash", nodes[1].kind == "FuncCall",
              nodes.dropFirst(2).allSatisfy({ $0.kind == "Label" }),
              let outerCall = nodes.dropFirst().first else { return nil }
        let outer = Self.arguments(outerCall,name:"figure",source:source)
        guard outer == nil || outer?.positional.count == 1,
              let inner = Self.arguments(outer?.positional.first ?? outerCall,name:"image",source:source),
              inner.positional.count == 1, let literal = inner.positional.first,
              literal.kind == "Str", let path = literal.stringValue else { return nil }
        let widthNode = inner.named["width"]
        var width: Double?
        if let widthNode, source.bytes(widthNode.span) != "auto" {
            let value = source.bytes(widthNode.span)
            guard widthNode.kind == "Numeric", value.hasSuffix("%"), let percent = Double(value.dropLast()), percent.isFinite, percent > 0, percent <= 100 else { return nil }
            width = percent
        }
        let altNode = inner.named["alt"]
        guard altNode == nil || (altNode?.kind == "Str" && altNode?.stringValue != nil) else { return nil }
        let captionNode = outer?.named["caption"]
        var caption = ""
        if let captionNode {
            guard captionNode.kind == "ContentBlock", let markup = captionNode.markup else { return nil }
            for node in markup.children {
                let raw = source.bytes(node.span)
                switch node.kind {
                case "Text","Space": caption += raw
                case "Escape":
                    guard raw.first == "\\", raw.unicodeScalars.count == 2,
                          "\\#@*_$[]<>`=-+".contains(raw.last!) else { return nil }
                    caption += String(raw.dropFirst())
                default: return nil
                }
            }
        }
        self.original = source; self.path = path; self.caption = caption; self.alt = altNode?.stringValue ?? ""; self.width = width
        pathSpan = literal.span; captionSpan = captionNode?.span; altSpan = altNode?.span; widthArgument = inner.args.children.first { $0.kind == "Named" && $0.children.first.map { source.bytes($0.span) } == "width" }
        figureArgs = outer?.args; imageArgs = inner.args
    }
    private static func arguments(_ call: SyntaxNode,name: String,source: String) -> (args: SyntaxNode,positional: [SyntaxNode],named: [String:SyntaxNode])? {
        guard call.kind == "FuncCall", call.children.first?.kind == "Ident",
              call.children.first.map({ source.bytes($0.span) }) == name,
              let args = call.children.first(where:{ $0.kind == "Args" }),
              args.children.first?.kind == "LeftParen", args.children.last?.kind == "RightParen" else { return nil }
        var named: [String:SyntaxNode] = [:], positional: [SyntaxNode] = []
        for node in args.children where !trivia.contains(node.kind) && !["LeftParen","RightParen","Comma"].contains(node.kind) {
            if node.kind == "Spread" { return nil }
            if node.kind == "Named" {
                let parts = node.children.filter { !trivia.contains($0.kind) }
                guard parts.count == 3, parts[0].kind == "Ident", parts[1].kind == "Colon" else { return nil }
                let key = source.bytes(parts[0].span)
                guard named[key] == nil else { return nil }; named[key] = parts[2]
            } else { positional.append(node) }
        }
        return (args,positional,named)
    }
    public static func widthLiteral(_ width: Double) -> String {
        String(format:"%.8g",locale:Locale(identifier:"en_US_POSIX"),width)+"%"
    }
    public func applying(path: String,caption: String,alt: String,width: Double?) -> String {
        var patches: [(ByteSpan,String)] = []
        var imageAdditions: [String] = [], figureAdditions: [String] = []
        if !path.utf8.elementsEqual(self.path.utf8) { patches.append((pathSpan,typstStringLiteral(path))) }
        if !caption.utf8.elementsEqual(self.caption.utf8) {
            let value = "[\(escapeTypst(caption))]"
            if let captionSpan { patches.append((captionSpan,value)) } else { figureAdditions.append("caption: "+value) }
        }
        if !alt.utf8.elementsEqual(self.alt.utf8) {
            let value = typstStringLiteral(alt)
            if let altSpan { patches.append((altSpan,value)) } else { imageAdditions.append("alt: "+value) }
        }
        if width != self.width {
            if let width {
                let value = Self.widthLiteral(width)
                if let widthArgument, let node = widthArgument.children.last(where:{ !Self.trivia.contains($0.kind) }) { patches.append((node.span,value)) }
                else { imageAdditions.append("width: "+value) }
            } else if let widthArgument, let index = imageArgs.children.firstIndex(where:{ $0.span == widthArgument.span }) {
                // Remove only argument tokens and one separator; comments survive.
                for node in widthArgument.children where !Self.trivia.contains(node.kind) { patches.append((node.span,"")) }
                let before = imageArgs.children[..<index].last { !Self.trivia.contains($0.kind) }
                let after = imageArgs.children.dropFirst(index+1).first { !Self.trivia.contains($0.kind) }
                if let comma = before?.kind == "Comma" ? before : after?.kind == "Comma" ? after : nil { patches.append((comma.span,"")) }
            }
        }
        func add(_ values: [String],to args: SyntaxNode) {
            guard !values.isEmpty, let close = args.children.last else { return }
            let previous = args.children.last { !["RightParen","Space","Parbreak","LineComment","BlockComment"].contains($0.kind) }
            patches.append((ByteSpan(close.start,close.start),(previous?.kind == "Comma" ? " " : ", ")+values.joined(separator:", ")))
        }
        add(imageAdditions,to:imageArgs); if let figureArgs { add(figureAdditions,to:figureArgs) }
        return patches.sorted { $0.0.start > $1.0.start }.reduce(original) { $0.replacingBytes($1.0,with:$1.1) }
    }
}
