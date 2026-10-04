import Foundation

public struct LiteralInclude {
    public var path: String
    public var source: ByteSpan
}
public struct TextCounts {
    public var words = 0
    public var characters = 0
    public var headings = 0
    public init() {}
    public static func count(_ text: String) -> TextCounts {
        var result = TextCounts(); result.characters = text.unicodeScalars.count
        text.enumerateSubstrings(in:text.startIndex..<text.endIndex,options:.byWords) { _,_,_,_ in result.words += 1 }
        return result
    }
}
func literalIncludes(_ source: String,_ parsed: ParsedSource,kind: String = "ModuleInclude") -> [LiteralInclude] {
    // Expand unconditional top-level statements only. Includes inside functions,
    // conditionals or content blocks belong to Typst's evaluation, not our editor.
    parsed.tree.children.filter { $0.kind == kind }.compactMap { node in
        guard let argument = node.children.first(where:{ $0.kind == "Str" }), let path = try? JSONDecoder().decode(String.self,from:Data(source.bytes(argument.span).utf8)) else { return nil }
        let hash = node.start > 0 && source.bytes(ByteSpan(node.start-1,node.start)) == "#"
        return LiteralInclude(path:path,source:ByteSpan(node.start-(hash ? 1 : 0),node.end))
    }
}
public func literalAssetPaths(_ source: String,_ parsed: ParsedSource) -> [String] {
    var paths: [String] = []
    func string(_ node: SyntaxNode) -> String? { try? JSONDecoder().decode(String.self,from:Data(source.bytes(node.span).utf8)) }
    for call in parsed.tree.descendants("FuncCall") {
        guard let name = call.children.first, ["image","read","bibliography"].contains(source.bytes(name.span)), let args = call.children.first(where:{ $0.kind == "Args" }) else { continue }
        if let literal = args.children.first(where:{ $0.kind == "Str" }), let path = string(literal) { paths.append(path) }
        if source.bytes(name.span) == "bibliography" {
            for named in args.children where named.kind == "Named" {
                if let key = named.children.first, source.bytes(key.span) == "style", let value = named.children.first(where:{ $0.kind == "Str" }), let path = string(value), path.lowercased().hasSuffix(".csl") { paths.append(path) }
            }
        }
    }
    return paths
}
