import Foundation

public enum InlineMark: Int {
    case bold = 1, italic, underline, strikethrough, superscript, subscripted, code
    public var keyPath: WritableKeyPath<TextStyle,Bool> {
        switch self {
        case .bold: return \.bold
        case .italic: return \.italic
        case .underline: return \.underline
        case .strikethrough: return \.strikethrough
        case .superscript: return \.superscript
        case .subscripted: return \.subscripted
        case .code: return \.code
        }
    }
    public var function: String {
        switch self {
        case .bold: return "strong"
        case .italic: return "emph"
        case .underline: return "underline"
        case .strikethrough: return "strike"
        case .superscript: return "super"
        case .subscripted: return "sub"
        case .code: return "raw"
        }
    }
    var wrapper: String { self == .bold ? "*" : self == .italic ? "_" : "#"+function+"[" }
    var suffix: String { self == .bold ? "*" : self == .italic ? "_" : "]" }
}
public struct TextStyle: Codable, Equatable {
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var superscript = false
    public var subscripted = false
    public var color: String? = nil
    public var highlight: String? = nil
    public var code = false
    public var link: String? = nil
    public init() {}
    private enum CodingKeys: String, CodingKey { case bold, italic, underline, strikethrough, superscript, subscripted, color, highlight, code, link }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        bold = try values.decodeIfPresent(Bool.self,forKey:.bold) ?? false
        italic = try values.decodeIfPresent(Bool.self,forKey:.italic) ?? false
        underline = try values.decodeIfPresent(Bool.self,forKey:.underline) ?? false
        strikethrough = try values.decodeIfPresent(Bool.self,forKey:.strikethrough) ?? false
        superscript = try values.decodeIfPresent(Bool.self,forKey:.superscript) ?? false
        subscripted = try values.decodeIfPresent(Bool.self,forKey:.subscripted) ?? false
        color = try values.decodeIfPresent(String.self,forKey:.color)
        highlight = try values.decodeIfPresent(String.self,forKey:.highlight)
        code = try values.decodeIfPresent(Bool.self,forKey:.code) ?? false
        link = try values.decodeIfPresent(String.self,forKey:.link)
    }
}
public struct ReferenceFormat: Equatable {
    public var range: NSRange
    public var bold: Bool
    public var italic: Bool
    public init(range: NSRange, bold: Bool = false, italic: Bool = false) { self.range = range; self.bold = bold; self.italic = italic }
}
public struct ReferencePresentation: Equatable {
    public var source: ByteSpan
    public var text: String
    public var kind: String
    public var formats: [ReferenceFormat]
    public init(source: ByteSpan, text: String, kind: String = "citation", formats: [ReferenceFormat] = []) { self.source = source; self.text = text; self.kind = kind; self.formats = formats }
    public func shifted(by delta: Int) -> ReferencePresentation { ReferencePresentation(source:ByteSpan(source.start+delta,source.end+delta),text:text,kind:kind,formats:formats) }
}
public struct TextRun {
    public var text: String
    public var source: ByteSpan
    public var style: TextStyle
    public var literal: Bool
    public var atomic: Bool = false
}
public indirect enum Inline {
    case text(String, ByteSpan, TextStyle, Bool)
    case reference(String, ByteSpan, TextStyle)
    case group(ByteSpan, String, String, [Inline])
    public var length: Int {
        switch self {
        case let .text(t, _, _, _), let .reference(t, _, _): return t.utf16.count
        case let .group(_, _, _, nodes): return nodes.reduce(0) { $0 + $1.length }
        }
    }
    public func shifted(by delta: Int) -> Inline {
        switch self {
        case let .text(t,s,style,literal): return .text(t,ByteSpan(s.start+delta,s.end+delta),style,literal)
        case let .reference(t,s,style): return .reference(t,ByteSpan(s.start+delta,s.end+delta),style)
        case let .group(s,prefix,suffix,nodes): return .group(ByteSpan(s.start+delta,s.end+delta),prefix,suffix,nodes.map { $0.shifted(by:delta) })
        }
    }
    public var runs: [TextRun] {
        switch self {
        case let .text(t, s, style, literal): return [TextRun(text: t, source: s, style: style, literal: literal)]
        case let .reference(t,s,style): return [TextRun(text:t,source:s,style:style,literal:false,atomic:true)]
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
        case let .reference(_,span,_): return source.bytes(span)
        case let .group(span, prefix, suffix, nodes):
            if start == 0 && end == length && removingMark == nil && !explicitMarks { return source.bytes(span) }
            let body = sliceInlines(nodes, start, end, source: source, removingMark: removingMark,explicitMarks:explicitMarks)
            let mark = removingMark.flatMap(InlineMark.init(rawValue:))
            let remove = mark.map { $0 == .code ? prefix.hasPrefix("`") : prefix == $0.wrapper || prefix.hasPrefix("#"+$0.function+"[") || prefix.hasPrefix("#"+$0.function+"(") } ?? (removingMark == 100 ? isNativeColorWrapper(prefix,function:"text") : removingMark == 101 ? isNativeColorWrapper(prefix,function:"highlight") : removingMark == 102 ? prefix.hasPrefix("#link(") : false)
            let head = explicitMarks && prefix == "*" ? "#strong[" : explicitMarks && prefix == "_" ? "#emph[" : prefix
            let tail = explicitMarks && (prefix == "*" || prefix == "_") ? "]" : suffix
            return body.isEmpty ? "" : remove ? (mark == .code ? escapeTypst((nodes.flatMap(\.runs).map(\.text).joined() as NSString).substring(with:NSRange(location:start,length:end-start))) : body) : head + body + tail
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
    public var alignment: String? = nil
    public var unalignedSource: ByteSpan? = nil
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
    // Presentation metadata from the parser, retained by localized reparses.
    public var labelSpans: [ByteSpan] = []
    public var columns: Int = 0
    public var text: String { inlines.flatMap(\.runs).map(\.text).joined() }
    public func shifted(by delta: Int) -> ProjectedBlock {
        var copy = self
        copy.source = ByteSpan(source.start+delta,source.end+delta)
        copy.body = ByteSpan(body.start+delta,body.end+delta)
        if let unalignedSource { copy.unalignedSource = ByteSpan(unalignedSource.start+delta,unalignedSource.end+delta) }
        copy.inlines = inlines.map { $0.shifted(by:delta) }
        copy.labelSpans = labelSpans.map { ByteSpan($0.start+delta,$0.end+delta) }
        copy.tableCells = tableCells.map { ByteSpan($0.start+delta,$0.end+delta) }
        return copy
    }
    public var editable: Bool { !["source", "table", "image", "equation", "bibliography"].contains(kind) }
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
    public init(source: String, parsed: ParsedSource, references: [ReferencePresentation] = []) {
        var result: [ProjectedBlock] = [], pending: [SyntaxNode] = []
        func block(_ n: SyntaxNode, kind: String, body: SyntaxNode? = nil, level: Int = 0) -> ProjectedBlock {
            let body = body ?? n
            return ProjectedBlock(kind: kind, level: level, source: n.span, body: body.span,
                inlines: body.span.count == 0 ? [] : inline(body.children.isEmpty ? [body] : body.children, source: source, references:references))
        }
        func flush() {
            if pending.allSatisfy({ source.bytes($0.span).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { pending.removeAll(); return }
            while let n = pending.first, ["Text", "Space"].contains(n.kind), source.bytes(n.span).contains("\n") && source.bytes(n.span).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pending.removeFirst() }
            while let n = pending.last, ["Text", "Space"].contains(n.kind), source.bytes(n.span).contains("\n") && source.bytes(n.span).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pending.removeLast() }
            guard let first = pending.first, let last = pending.last else { return }
            let span = ByteSpan(first.start, last.end)
            result.append(ProjectedBlock(kind: "paragraph", source: span, body: span, inlines: inline(pending, source: source, references:references)))
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
                if references.contains(where:{ $0.kind == "citation" && $0.source.start <= n.start && $0.source.end >= n.end }) {
                    pending.append(n); i += 1; continue
                }
                flush(); result.append(ProjectedBlock(kind: "source", source: n.span, body: n.span,
                    inlines: [.text(source.bytes(n.span), n.span, TextStyle(), true)])); i += 1; continue
            }
            if n.kind == "Raw", source.bytes(n.span).hasPrefix("```"), source.bytes(n.span).contains("\n"), let body = rawBody(n,source:source) {
                flush(); var style = TextStyle(); style.code = true
                result.append(ProjectedBlock(kind:"raw",source:n.span,body:body,inlines:[.text(source.bytes(body),body,style,true)]))
                i += 1; continue
            }
            if n.kind == "Hash", i+1 < nodes.count {
                let next = nodes[i+1]
                let span = ByteSpan(n.start, next.end)
                if next.kind == "FuncCall", let name = next.children.first, ["align","par"].contains(source.bytes(name.span)), let content = next.descendants("ContentBlock").first?.markup {
                    let prefix = source.bytes(ByteSpan(n.start,content.start))
                    let alignment = ["left","center","right"].first { prefix == "#align("+$0+")[" } ?? (prefix == "#par(justify: true)[" ? "justified" : nil)
                    if let alignment {
                        let inner = source.bytes(content.span), projected = Projection(source:inner,parsed:ParsedSource.parse(inner),references:references.filter { $0.source.start >= content.start && $0.source.end <= content.end }.map { $0.shifted(by:-content.start) })
                        if projected.blocks.count == 1, var b = projected.blocks.first, b.editable {
                            flush(); b = b.shifted(by:content.start); b.unalignedSource = b.source; b.source = span; b.alignment = alignment
                            result.append(b); i += 2; continue
                        }
                    }
                }
                if next.kind == "FuncCall", let name = next.children.first, ["strong","emph","underline","strike","super","sub","text","highlight","link","footnote","cite","ref"].contains(source.bytes(name.span)) {
                    pending += [n,next]; i += 2; continue
                }
                let before = source.bytes(ByteSpan(0, n.start)).components(separatedBy: "\n").last ?? ""
                let after = source.bytes(ByteSpan(next.end, source.utf8.count)).components(separatedBy: "\n").first ?? ""
                if before.trimmingCharacters(in: .whitespaces).isEmpty && after.trimmingCharacters(in: .whitespaces).isEmpty {
                    flush(); n.start = span.start; n.end = span.end; n.children = next.children
                    let raw = source.bytes(span)
                    var b = ProjectedBlock(kind: raw.hasPrefix("#table(") ? "table" : raw.hasPrefix("#image(") || raw.hasPrefix("#figure(") ? "image" : "source",
                        source: span, body: span, inlines: [.text(raw, span, TextStyle(), true)])
                    if raw.hasPrefix("#bibliography(") {
                        b.kind = "bibliography"
                        b.inlines = [.reference(references.first { $0.source == span && $0.kind == "bibliography" }?.text ?? "Bibliography",span,TextStyle())]
                    }
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
                            let raw = source.bytes(span), cell = Projection(source:raw,parsed:ParsedSource.parse(raw),references:references.filter { $0.source.start >= span.start && $0.source.end <= span.end }.map { $0.shifted(by:-span.start) })
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
        var labelBlock = 0
        for label in parsed.markupLabelSpans {
            while labelBlock < result.count && result[labelBlock].source.end <= label.start { labelBlock += 1 }
            if labelBlock < result.count, result[labelBlock].source.start <= label.start, label.end <= result[labelBlock].source.end {
                result[labelBlock].labelSpans.append(label)
            }
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
    public var atomicRanges: [NSRange] {
        blocks.flatMap { block in
            var at = block.display.location
            return block.inlines.flatMap(\.runs).compactMap { run in
                defer { at += run.text.utf16.count }
                return run.atomic ? NSRange(location:at,length:run.text.utf16.count) : nil
            }
        }
    }
    public func atomicRange(_ proposed: NSRange) -> NSRange {
        var range = proposed
        for atomic in atomicRanges {
            if range.length > 0 && NSIntersectionRange(range,atomic).length > 0 { range = NSUnionRange(range,atomic) }
            else if range.length == 0 && range.location > atomic.location && range.location < NSMaxRange(atomic) { range.location = NSMaxRange(atomic) }
        }
        return range
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
private func inline(_ nodes: [SyntaxNode], source: String, style: TextStyle = TextStyle(), references: [ReferencePresentation] = []) -> [Inline] {
    var out: [Inline] = [], i = 0
    while i < nodes.count {
        let n = nodes[i], raw = source.bytes(n.span)
        if let reference = references.first(where:{ $0.kind == "citation" && $0.source.start == n.start && $0.source.end <= (nodes.last?.end ?? n.end) }) {
            out.append(.reference(reference.text,reference.source,style))
            while i+1 < nodes.count && nodes[i+1].start < reference.source.end { i += 1 }
        } else if n.kind == "Ref", raw.hasPrefix("@zotero-") {
            out.append(.reference("Citation",n.span,style))
        } else if ["Strong", "Emph"].contains(n.kind), let body = n.markup {
            var s = style
            if n.kind == "Strong" { s.bold = true } else { s.italic = true }
            out.append(.group(n.span, source.bytes(ByteSpan(n.start, body.start)), source.bytes(ByteSpan(body.end, n.end)), inline(body.children, source: source, style: s, references:references)))
        } else if n.kind == "Hash", i+1 < nodes.count {
            let next = nodes[i+1], span = ByteSpan(n.start, nodes[i+1].end), raw = source.bytes(span)
            // Literal content of native links, footnotes and inline styles.
            let function = next.kind == "FuncCall" ? next.children.first.map { source.bytes($0.span) } : nil
            if next.kind == "FuncCall", next.children.first.map({ source.bytes($0.span) }) == "cite" {
                out.append(.reference("Citation",span,style))
            } else if let content = next.descendants("ContentBlock").first?.markup,
               ["link", "footnote", "strong", "emph", "underline", "strike", "super", "sub", "text", "highlight"].contains(function ?? "") {
                var s = style
                if raw.hasPrefix("#strong") { s.bold = true }
                if raw.hasPrefix("#emph") { s.italic = true }
                if function == "underline" { s.underline = true }
                if function == "strike" { s.strikethrough = true }
                if function == "super" { s.superscript = true; s.subscripted = false }
                if function == "sub" { s.subscripted = true; s.superscript = false }
                if function == "text" || function == "highlight" {
                    let prefix = source.bytes(ByteSpan(span.start,content.start))
                    if isNativeColorWrapper(prefix,function:function!), let match = prefix.range(of:"#[0-9a-fA-F]{6}",options:.regularExpression) {
                        if function == "text" { s.color = String(prefix[match]) } else { s.highlight = String(prefix[match]) }
                    }
                }
                if function == "link", let url = next.descendants("Str").first?.stringValue { s.link = url }
                out.append(.group(span, source.bytes(ByteSpan(span.start, content.start)), source.bytes(ByteSpan(content.end, span.end)), inline(content.children, source: source, style: s, references:references)))
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
        else if n.kind == "Raw", let body = rawBody(n,source:source) {
            var s = style; s.code = true
            out.append(.group(n.span, source.bytes(ByteSpan(n.start,body.start)), source.bytes(ByteSpan(body.end,n.end)), [.text(source.bytes(body),body,s,true)]))
        } else { out.append(.text(raw, n.span, style, true)) }
        i += 1
    }
    return out
}

// Fences grow to retain literal backticks, Unicode and newlines without escaping.
public func rawTypst(_ text: String, block: Bool = false) -> String {
    var longest = 0, current = 0
    for character in text { if character == "`" { current += 1; longest = max(longest,current) } else { current = 0 } }
    let count = block || longest > 0 ? max(3,longest+1) : 1
    let fence = String(repeating:"`",count:count)
    return block ? fence+"\n"+text+"\n"+fence : count == 1 ? fence+text+fence : fence+" "+text+(text.trimmingCharacters(in:.whitespacesAndNewlines).hasSuffix("`") ? " " : "")+fence
}

private func rawBody(_ node: SyntaxNode,source: String) -> ByteSpan? {
    guard let text = node.rawText, let first = node.children.first(where:{ $0.kind == "RawDelim" }), let last = node.children.last(where:{ $0.kind == "RawDelim" }) else { return nil }
    let start = node.descendants("RawLang").last?.end ?? first.end
    let region = ByteSpan(start,max(start,last.start)), body = source.bytes(region)
    if text.isEmpty {
        let padding = body.hasPrefix("\r\n") ? 2 : body.hasPrefix("\n") || body.hasPrefix(" ") ? 1 : 0
        return ByteSpan(start+padding,start+padding)
    }
    // Official raw text trims fence padding. Retain its exact contiguous body
    // for native mapping; dedented/custom raw remains available as source.
    let match = (body as NSString).range(of:text,options:.literal)
    guard match.location != NSNotFound else { return nil }
    let a = start+body.byteOffset(utf16:match.location), z = start+body.byteOffset(utf16:NSMaxRange(match))
    return source.bytes(ByteSpan(a,z)) == text ? ByteSpan(a,z) : nil
}

private func isNativeColorWrapper(_ prefix: String,function: String) -> Bool {
    prefix.range(of:"^#"+function+"\\(fill: rgb\\(\"#[0-9a-fA-F]{6}\"\\)\\)\\[$",options:.regularExpression) != nil
}
