import Foundation
import CTypst

public struct ByteSpan: Codable, Equatable {
    public var start: Int
    public var end: Int
    public init(_ start: Int, _ end: Int) { self.start = start; self.end = end }
    public var count: Int { end - start }
}
public struct SyntaxNode: Codable {
    public var kind: String
    public var start: Int
    public var end: Int
    public var children: [SyntaxNode]
    public var stringValue: String? = nil
    public var rawText: String? = nil
    public var span: ByteSpan { ByteSpan(start, end) }
    public var markup: SyntaxNode? { children.first { $0.kind == "Markup" } }
    public func descendants(_ kind: String) -> [SyntaxNode] {
        self.kind == kind ? [self] : children.flatMap { $0.descendants(kind) }
    }
}
public struct SyntaxStyle: Codable {
    public var start: Int
    public var end: Int
    public var tag: String
}
public struct ParsedSource: Codable {
    public var tree: SyntaxNode
    public var styles: [SyntaxStyle]
    public var erroneous: Bool = false
    public static func parse(_ source: String) -> ParsedSource {
        // NUL is valid document content; JSON transport must not truncate it.
        if source.contains("\0") {
            return ParsedSource(tree: SyntaxNode(kind: "Markup", start: 0, end: source.utf8.count,
                children: [SyntaxNode(kind: "Text", start: 0, end: source.utf8.count, children: [])]), styles: [])
        }
        return source.withCString { input in
            guard let pointer = blank_parse(input) else { preconditionFailure("Typst parser failed") }
            defer { blank_string_free(pointer) }
            return try! JSONDecoder().decode(ParsedSource.self, from: Data(String(cString: pointer).utf8))
        }
    }
}

public extension String {
    func bytes(_ span: ByteSpan) -> String {
        var text = self
        return text.withUTF8 { b in
            guard span.start >= 0, span.end >= span.start, span.end <= b.count else { return "" }
            return String(decoding: b[span.start..<span.end], as: UTF8.self)
        }
    }
    func replacingBytes(_ span: ByteSpan, with text: String) -> String {
        let b = Array(utf8)
        return String(decoding: b[..<span.start], as: UTF8.self) + text + String(decoding: b[span.end...], as: UTF8.self)
    }
    func byteOffset(utf16 offset: Int) -> Int {
        let ns = self as NSString
        let o = max(0, min(offset, ns.length))
        // Clamp an interior surrogate to the beginning of its scalar.
        var safe = o
        if o > 0 && o < ns.length && (0xDC00...0xDFFF).contains(ns.character(at: o)) { safe -= 1 }
        return ns.substring(to: safe).utf8.count
    }
    func utf16Offset(byte offset: Int) -> Int { bytes(ByteSpan(0, min(max(0, offset), utf8.count))).utf16.count }
}
public func escapeTypst(_ text: String) -> String {
    var result = ""
    for character in text {
        // Write keeps markers visible until a shortcut or block conversion
        // explicitly turns them into structural source syntax.
        if "\\#@*_$[]<>`=-+".contains(character) { result += "\\" }
        result.append(character)
    }
    return result
}
public func typstStringLiteral(_ text: String) -> String {
    let encoder = JSONEncoder()
    // Typst treats an escaped slash as a backslash in file paths.
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(data:try! encoder.encode(text),encoding:.utf8)!
}

// Native tables require literal dimensions and positional content blocks.
// Computed/spread cells remain source so their compiler semantics stay intact.
func nativeTableArguments(_ call: SyntaxNode,source: String) -> (args: SyntaxNode,cells: [SyntaxNode],columns: SyntaxNode)? {
    guard call.kind == "FuncCall", let name = call.children.first, source.bytes(name.span) == "table",
          let args = call.children.first(where:{ $0.kind == "Args" }) else { return nil }
    let trivia = Set(["Space","LineComment","BlockComment"])
    guard args.children.allSatisfy({ trivia.contains($0.kind) || ["LeftParen","RightParen","Comma","Named","ContentBlock"].contains($0.kind) }) else { return nil }
    let named = args.children.filter { node in
        node.kind == "Named" && node.children.first(where:{ !trivia.contains($0.kind) }).map { source.bytes($0.span) == "columns" } == true
    }
    guard named.count == 1 else { return nil }
    let value = named[0].children.filter { !trivia.contains($0.kind) }
    guard value.count == 3, value[0].kind == "Ident", value[1].kind == "Colon", value[2].kind == "Int",
          let count = Int(source.bytes(value[2].span)), count > 0 else { return nil }
    let cells = args.children.filter { $0.kind == "ContentBlock" }
    guard !cells.isEmpty, cells.count % count == 0 else { return nil }
    return (args,cells,value[2])
}
