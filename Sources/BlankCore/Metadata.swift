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
func literalIncludes(_ source: String,_ parsed: ParsedSource) -> [LiteralInclude] {
    parsed.tree.descendants("ModuleInclude").compactMap { node in
        guard let argument = node.children.first(where:{ $0.kind == "Str" }), let path = try? JSONDecoder().decode(String.self,from:Data(source.bytes(argument.span).utf8)) else { return nil }
        let hash = node.start > 0 && source.bytes(ByteSpan(node.start-1,node.start)) == "#"
        return LiteralInclude(path:path,source:ByteSpan(node.start-(hash ? 1 : 0),node.end))
    }
}
