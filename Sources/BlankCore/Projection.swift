import Foundation

public struct TextStyle: Codable, Equatable {
    public var bold = false
    public var italic = false
    public var code = false
    public var link: String? = nil
    public init() {}
}
public struct TextRun {
    public var text: String
    public var source: ByteSpan
    public var style: TextStyle
    public var literal: Bool
}
public indirect enum Inline {
    case text(String, ByteSpan, TextStyle, Bool)
    case group(ByteSpan, String, String, [Inline])
    public var length: Int {
        switch self {
        case let .text(t, _, _, _): return t.utf16.count
        case let .group(_, _, _, nodes): return nodes.reduce(0) { $0 + $1.length }
        }
    }
    public func shifted(by delta: Int) -> Inline {
        switch self {
        case let .text(t,s,style,literal): return .text(t,ByteSpan(s.start+delta,s.end+delta),style,literal)
        case let .group(s,prefix,suffix,nodes): return .group(ByteSpan(s.start+delta,s.end+delta),prefix,suffix,nodes.map { $0.shifted(by:delta) })
        }
    }
    public var runs: [TextRun] {
        switch self {
        case let .text(t, s, style, literal): return [TextRun(text: t, source: s, style: style, literal: literal)]
        case let .group(_, _, _, nodes): return nodes.flatMap(\.runs)
        }
    }
    // Slice only affected inline syntax. Completely retained nodes keep their original bytes.
    public func slice(_ start: Int, _ end: Int, source: String, removingMark: Int? = nil, explicitMarks: Bool = false) -> String {
        guard start < end else { return "" }
        switch self {
        case let .text(t, span, _, literal):
            if start == 0 && end == length { return source.bytes(span) }
            if literal {
                let a = t.byteOffset(utf16: start), b = t.byteOffset(utf16: end)
                return source.bytes(ByteSpan(span.start + a, span.start + b))
            }
            return escapeTypst((t as NSString).substring(with: NSRange(location: start, length: end-start)))
        case let .group(span, prefix, suffix, nodes):
            if start == 0 && end == length && removingMark == nil && !explicitMarks { return source.bytes(span) }
            let body = sliceInlines(nodes, start, end, source: source, removingMark: removingMark,explicitMarks:explicitMarks)
            let remove = removingMark == 1 && (prefix == "*" || prefix.hasPrefix("#strong")) || removingMark == 2 && (prefix == "_" || prefix.hasPrefix("#emph"))
            let head = explicitMarks && prefix == "*" ? "#strong[" : explicitMarks && prefix == "_" ? "#emph[" : prefix
            let tail = explicitMarks && (prefix == "*" || prefix == "_") ? "]" : suffix
            return body.isEmpty ? "" : remove ? body : head + body + tail
        }
    }
}
public func sliceInlines(_ nodes: [Inline], _ start: Int, _ end: Int, source: String, removingMark: Int? = nil, explicitMarks: Bool = false) -> String {
    var offset = 0, result = ""
    for node in nodes {
        let a = max(0, start-offset), b = min(node.length, end-offset)
        if b > a { result += node.slice(a, b, source: source, removingMark: removingMark,explicitMarks:explicitMarks) }
        offset += node.length
    }
    return result
}
public struct ProjectedBlock {
    public var kind: String
    public var level: Int = 0
    public var source: ByteSpan
    public var body: ByteSpan
    public var inlines: [Inline]
    public var display: NSRange = NSRange(location: 0, length: 0)
    public var tableCells: [ByteSpan] = []
    // Each cell retains its own lossless projection. Native text tables use
    // paragraph terminators between cells, which are layout, not source bytes.
    public var cellProjections: [Projection] = []
    public var cellRanges: [NSRange] = []
    public var collapsed = false
    public var columns: Int = 0
    public var text: String { inlines.flatMap(\.runs).map(\.text).joined() }
    public func shifted(by delta: Int) -> ProjectedBlock {
        var copy = self
        copy.source = ByteSpan(source.start+delta,source.end+delta)
        copy.body = ByteSpan(body.start+delta,body.end+delta)
        copy.inlines = inlines.map { $0.shifted(by:delta) }
        copy.tableCells = tableCells.map { ByteSpan($0.start+delta,$0.end+delta) }
        return copy
    }
    public var editable: Bool { !["source", "table", "image", "equation"].contains(kind) }
    public func sourceOffset(_ position: Int, endBias: Bool = false) -> Int {
        if let cell = cellRanges.lastIndex(where:{ $0.location <= position }) {
            return tableCells[cell].start + cellProjections[cell].sourceOffset(at:min(position-cellRanges[cell].location,cellRanges[cell].length),endBias:endBias)
        }
        var at = 0
        for run in inlines.flatMap(\.runs) {
            let length = run.text.utf16.count
            if position < at + length || (position == at + length && !endBias) {
                let relative = max(0, min(position-at, length))
                if run.literal { return run.source.start + run.text.byteOffset(utf16: relative) }
                return relative == 0 ? run.source.start : run.source.end
            }
            at += length
        }
        return body.end
    }
}
public struct Projection {
    public var blocks: [ProjectedBlock]
    public var text: String
    public init(blocks: [ProjectedBlock]) {
        var blocks = blocks, text = "", offset = 0
        for index in blocks.indices {
            if index > 0 { text += "\n"; offset += 1 }
            let body = blocks[index].text, length = body.utf16.count
            blocks[index].display = NSRange(location:offset,length:length)
            text += body; offset += length
        }
        self.blocks = blocks; self.text = text
    }
    public init(source: String, parsed: ParsedSource) {
        var result: [ProjectedBlock] = [], pending: [SyntaxNode] = []
        func block(_ n: SyntaxNode, kind: String, body: SyntaxNode? = nil, level: Int = 0) -> ProjectedBlock {
            let body = body ?? n
            return ProjectedBlock(kind: kind, level: level, source: n.span, body: body.span,
                inlines: body.span.count == 0 ? [] : inline(body.children.isEmpty ? [body] : body.children, source: source))
        }
        func flush() {
            if pending.allSatisfy({ source.bytes($0.span).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { pending.removeAll(); return }
            while let n = pending.first, ["Text", "Space"].contains(n.kind), source.bytes(n.span).contains("\n") && source.bytes(n.span).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pending.removeFirst() }
            while let n = pending.last, ["Text", "Space"].contains(n.kind), source.bytes(n.span).contains("\n") && source.bytes(n.span).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pending.removeLast() }
            guard let first = pending.first, let last = pending.last else { return }
            let span = ByteSpan(first.start, last.end)
            result.append(ProjectedBlock(kind: "paragraph", source: span, body: span, inlines: inline(pending, source: source)))
            pending.removeAll()
        }
        let nodes = parsed.tree.children
        var i = 0
        while i < nodes.count {
            var n = nodes[i]
            if n.kind == "Parbreak" {
                flush()
                if result.isEmpty { result.append(ProjectedBlock(kind:"paragraph",source:ByteSpan(n.start,n.start),body:ByteSpan(n.start,n.start),inlines:[])) }
                let whitespace = Array(source.bytes(n.span).utf8)
                let newlines = whitespace.indices.filter { whitespace[$0] == 10 }
                // Each Return inserts two source newlines. Retain its empty
                // editing slot even when Typst folds adjacent paragraph breaks.
                if newlines.count >= 4 {
                    for pair in 1..<(newlines.count/2) {
                        let at = n.start+newlines[pair*2-1]+1
                        result.append(ProjectedBlock(kind:"paragraph",source:ByteSpan(at,at),body:ByteSpan(at,at),inlines:[]))
                    }
                }
                i += 1; continue
            }
            if ["Heading", "ListItem", "EnumItem"].contains(n.kind), let body = n.markup {
                flush()
                let level = source.bytes(n.span).prefix { $0 == "=" }.count
                var projected = block(n, kind: n.kind == "Heading" ? "heading" : n.kind == "ListItem" ? "bullet" : "number", body: body, level: level)
                // An empty marker's padding can belong to the following
                // Parbreak (rather than Space). Include it in the block so the
                // body insertion point maps here, not into the next paragraph.
                if body.span.count == 0 {
                    let padding = source.bytes(ByteSpan(n.end,source.utf8.count)).prefix { $0 == " " || $0 == "\t" }.utf8.count
                    projected.source.end += padding
                    projected.body = ByteSpan(body.start+padding,body.end+padding)
                } else if i+1 < nodes.count, nodes[i+1].kind == "Space" {
                    let spaces = String(source.bytes(nodes[i+1].span).prefix { $0 == " " || $0 == "\t" }), padding = spaces.utf8.count
                    projected.source.end += padding
                    if body.span.count == 0 { projected.body = ByteSpan(body.start+padding,body.end+padding) }
                    else if padding > 0 {
                        projected.body.end += padding
                        if body.children.last?.kind == "Linebreak", case let .text(text,span,style,literal) = projected.inlines.last, text == "\u{2028}" {
                            projected.inlines[projected.inlines.count-1] = .text(text,ByteSpan(span.start,n.end+padding),style,literal)
                        } else { projected.inlines.append(.text(spaces,ByteSpan(n.end,n.end+padding),TextStyle(),true)) }
                    }
                }
                result.append(projected)
                i += 1; continue
            }
            if ["LineComment", "BlockComment"].contains(n.kind) {
                flush(); result.append(ProjectedBlock(kind: "source", source: n.span, body: n.span,
                    inlines: [.text(source.bytes(n.span), n.span, TextStyle(), true)])); i += 1; continue
            }
            if n.kind == "Hash", i+1 < nodes.count {
                let next = nodes[i+1]
                let span = ByteSpan(n.start, next.end)
                if next.kind == "FuncCall", let name = next.children.first, ["strong","emph","link","footnote"].contains(source.bytes(name.span)) {
                    pending += [n,next]; i += 2; continue
                }
                let before = source.bytes(ByteSpan(0, n.start)).components(separatedBy: "\n").last ?? ""
                let after = source.bytes(ByteSpan(next.end, source.utf8.count)).components(separatedBy: "\n").first ?? ""
                if before.trimmingCharacters(in: .whitespaces).isEmpty && after.trimmingCharacters(in: .whitespaces).isEmpty {
                    flush(); n.start = span.start; n.end = span.end; n.children = next.children
                    let raw = source.bytes(span)
                    var b = ProjectedBlock(kind: raw.hasPrefix("#table(") ? "table" : raw.hasPrefix("#image(") || raw.hasPrefix("#figure(") ? "image" : "source",
                        source: span, body: span, inlines: [.text(raw, span, TextStyle(), true)])
                    if raw.hasPrefix("#quote"), let content = next.descendants("ContentBlock").first?.markup {
                        b = block(n, kind: "quote", body: content)
                    }
                    if b.kind == "table", let table = nativeTableArguments(next,source:source) {
                        b.tableCells = table.cells.compactMap { $0.markup?.span }
                        b.columns = Int(source.bytes(table.columns.span)) ?? 0
                    }
                    if b.kind == "table" && b.columns > 0 && !b.tableCells.isEmpty && b.tableCells.count % b.columns == 0 {
                        b.inlines = []
                        var offset = 0
                        for span in b.tableCells {
                            let raw = source.bytes(span), cell = Projection(source:raw,parsed:ParsedSource.parse(raw))
                            b.cellProjections.append(cell)
                            b.cellRanges.append(NSRange(location:offset,length:cell.text.utf16.count))
                            for (index,part) in cell.blocks.enumerated() {
                                if index > 0 { b.inlines.append(.text("\n",ByteSpan(span.start+part.source.start,span.start+part.source.start),TextStyle(),false)) }
                                b.inlines += part.inlines.map { $0.shifted(by:span.start) }
                            }
                            b.inlines.append(.text("\n",ByteSpan(span.end,span.end),TextStyle(),false))
                            offset += cell.text.utf16.count+1
                        }
                    } else if b.kind == "image" {
                        b.inlines = [.text("\u{FFFC}", span, TextStyle(), false)]
                    }
                    // Adjacent setup/custom expressions remain one opaque source region.
                    if b.kind == "source", let last = result.last, last.kind == "source",
                       source.bytes(ByteSpan(last.source.end, b.source.start)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let merged = ByteSpan(last.source.start, b.source.end)
                        result[result.count-1] = ProjectedBlock(kind: "source", source: merged, body: merged,
                            inlines: [.text(source.bytes(merged), merged, TextStyle(), true)])
                    } else { result.append(b) }
                    i += 2; continue
                }
                pending += [n, next]; i += 2; continue
            }
            if n.kind == "Equation", source.bytes(n.span).hasPrefix("$ ") {
                flush(); result.append(ProjectedBlock(kind: "equation", source: n.span, body: n.span,
                    inlines: [.text(source.bytes(n.span), n.span, TextStyle(), true)])); i += 1; continue
            }
            pending.append(n); i += 1
        }
        flush()
        // Preserve real insertion slots after Return, including a document ending in code.
        if result.isEmpty { result = [ProjectedBlock(kind: "paragraph", source: ByteSpan(0, source.utf8.count), body: ByteSpan(0, source.utf8.count), inlines: [])] }
        else if source.hasSuffix("\n\n") {
            let end = source.utf8.count
            result.append(ProjectedBlock(kind: "paragraph", source: ByteSpan(end, end), body: ByteSpan(end, end), inlines: []))
        }
        self.init(blocks:result)
    }
    public func blockIndex(at utf16: Int) -> Int {
        blocks.lastIndex { $0.display.location <= utf16 } ?? 0
    }
    public func sourceOffset(at utf16: Int, endBias: Bool = false) -> Int {
        let b = blocks[blockIndex(at: utf16)]
        return b.sourceOffset(max(0, min(utf16-b.display.location, b.display.length)), endBias: endBias)
    }
    public func tableCell(at range: NSRange) -> (block: Int, cell: Int, source: ByteSpan, display: NSRange)? {
        let index = blockIndex(at:range.location), block = blocks[index]
        guard let cell = block.cellRanges.lastIndex(where:{ block.display.location+$0.location <= range.location }) else { return nil }
        let local = block.cellRanges[cell], display = NSRange(location:block.display.location+local.location,length:local.length)
        guard NSMaxRange(range) <= NSMaxRange(display) else { return nil }
        return (index,cell,block.tableCells[cell],display)
    }
    public func displayOffset(at byte: Int) -> Int {
        guard let b = blocks.first(where: { byte <= $0.source.end }) ?? blocks.last else { return 0 }
        if !b.cellRanges.isEmpty {
            let cell = b.tableCells.firstIndex(where:{ byte <= $0.end }) ?? b.tableCells.count-1
            return b.display.location+b.cellRanges[cell].location+b.cellProjections[cell].displayOffset(at:max(0,byte-b.tableCells[cell].start))
        }
        var at = b.display.location
        for r in b.inlines.flatMap(\.runs) {
            if byte <= r.source.end {
                return at + (r.literal ? r.text.utf16Offset(byte: max(0, byte-r.source.start)) : byte <= r.source.start ? 0 : r.text.utf16.count)
            }
            at += r.text.utf16.count
        }
        return NSMaxRange(b.display)
    }
}
private func inline(_ nodes: [SyntaxNode], source: String, style: TextStyle = TextStyle()) -> [Inline] {
    var out: [Inline] = [], i = 0
    while i < nodes.count {
        let n = nodes[i], raw = source.bytes(n.span)
        if ["Strong", "Emph"].contains(n.kind), let body = n.markup {
            var s = style
            if n.kind == "Strong" { s.bold = true } else { s.italic = true }
            out.append(.group(n.span, source.bytes(ByteSpan(n.start, body.start)), source.bytes(ByteSpan(body.end, n.end)), inline(body.children, source: source, style: s)))
        } else if n.kind == "Hash", i+1 < nodes.count {
            let next = nodes[i+1], span = ByteSpan(n.start, nodes[i+1].end), raw = source.bytes(span)
            // Literal content of native link/footnote/strong/emphasis expressions.
            if let content = next.descendants("ContentBlock").first?.markup,
               ["#link", "#footnote", "#strong", "#emph"].contains(where: { raw.hasPrefix($0) }) {
                var s = style
                if raw.hasPrefix("#strong") { s.bold = true }
                if raw.hasPrefix("#emph") { s.italic = true }
                if raw.hasPrefix("#link"), let a = raw.firstIndex(of: "\""), let b = raw[raw.index(after: a)...].firstIndex(of: "\"") { s.link = String(raw[raw.index(after: a)..<b]) }
                out.append(.group(span, source.bytes(ByteSpan(span.start, content.start)), source.bytes(ByteSpan(content.end, span.end)), inline(content.children, source: source, style: s)))
            } else { out.append(.text(raw, span, style, true)) }
            i += 1
        } else if n.kind == "Escape" {
            out.append(.text(String(raw.dropFirst()), n.span, style, false))
        } else if n.kind == "Linebreak" {
            var span = n.span
            if i+1 < nodes.count, nodes[i+1].kind == "Space" { span.end = nodes[i+1].end; i += 1 }
            // Native line separators wrap within a paragraph; newlines mark
            // projected block boundaries and receive paragraph spacing.
            out.append(.text("\u{2028}", span, style, false))
        }
        else if n.kind == "Raw", raw.hasPrefix("`"), !raw.hasPrefix("```") {
            var s = style; s.code = true
            out.append(.group(n.span, "`", "`", [.text(String(raw.dropFirst().dropLast()), ByteSpan(n.start+1, n.end-1), s, true)]))
        } else { out.append(.text(raw, n.span, style, true)) }
        i += 1
    }
    return out
}
