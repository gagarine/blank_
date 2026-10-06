import Foundation

public enum SectionPlacement: Equatable { case before, after, inside }

public struct EditSelection: Codable, Equatable {
    public var anchor: Int
    public var focus: Int
    public init(_ anchor: Int, _ focus: Int) { self.anchor = anchor; self.focus = focus }
    public var span: ByteSpan { ByteSpan(min(anchor, focus), max(anchor, focus)) }
}
public struct SourcePatch: Codable, Equatable {
    public var start: Int
    public var removed: String
    public var inserted: String
    public var oldSpan: ByteSpan { ByteSpan(start, start + removed.utf8.count) }
    public var newSpan: ByteSpan { ByteSpan(start, start + inserted.utf8.count) }
    public var inverse: SourcePatch { SourcePatch(start: start, removed: inserted, inserted: removed) }
    public static func difference(_ old: String, _ new: String) -> SourcePatch? {
        guard old != new else { return nil }
        let a = Array(old.utf8), b = Array(new.utf8)
        var prefix = 0
        while prefix < min(a.count,b.count) && a[prefix] == b[prefix] { prefix += 1 }
        while prefix > 0 && prefix < a.count && a[prefix] & 0xC0 == 0x80 { prefix -= 1 }
        var suffix = 0
        while suffix < min(a.count-prefix,b.count-prefix) && a[a.count-1-suffix] == b[b.count-1-suffix] { suffix += 1 }
        while suffix > 0 && (a[a.count-suffix] & 0xC0 == 0x80 || b[b.count-suffix] & 0xC0 == 0x80) { suffix -= 1 }
        return SourcePatch(start: prefix, removed: String(decoding: a[prefix..<a.count-suffix], as: UTF8.self), inserted: String(decoding: b[prefix..<b.count-suffix], as: UTF8.self))
    }
}
private struct HistoryStep {
    var patches: [SourcePatch]
    var before: EditSelection
    var after: EditSelection
    var group: String
    var time: TimeInterval
    var bytes: Int { patches.reduce(0) { $0 + $1.removed.utf8.count + $1.inserted.utf8.count } }
}
public struct RichFragment: Codable {
    public var source: String
    public var plain: String
    public var block: Bool
    public init(source: String, plain: String, block: Bool) { self.source = source; self.plain = plain; self.block = block }
}
public final class DocumentBuffer {
    public private(set) var source: String
    private var parsedCache: ParsedSource?
    private var hasSyntaxErrors = false
    public private(set) var includes: [LiteralInclude] = []
    public private(set) var imports: [LiteralInclude] = []
    private var countsRevision = -1
    private var countsCache = TextCounts()
    public var counts: TextCounts {
        if countsRevision == revision { return countsCache }
        var counts = TextCounts()
        func add(_ text: String) { let next = TextCounts.count(text); counts.words += next.words; counts.characters += next.characters }
        for block in projection.blocks {
            if block.editable { add(block.text); if block.kind == "heading" { counts.headings += 1 } }
            else if block.kind == "table" { for cell in block.tableCells { add(DocumentBuffer(source.bytes(cell)).projection.text) } }
        }
        countsCache = counts; countsRevision = revision; return countsCache
    }
    public var parsed: ParsedSource {
        if let cache = parsedCache { return cache }
        let parsed = ParsedSource.parse(source); parsedCache = parsed; return parsed
    }
    public private(set) var lastEditWasLocal = false
    private var collapsedSourceStarts = Set<Int>()
    private var referencePresentations: [ReferencePresentation] = []
    public var renderedReferences: [ReferencePresentation] { referencePresentations }
    public private(set) var presentationRevision = 0
    public private(set) var projection: Projection
    public private(set) var revision: Int = 0
    public var selection = EditSelection(0, 0)
    private var undoSteps: [HistoryStep] = [], redoSteps: [HistoryStep] = []
    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    public var historyBytes: Int { (undoSteps + redoSteps).reduce(0) { $0+$1.bytes } }
    public init(_ text: String = "") {
        source = text; let parsed = ParsedSource.parse(text); parsedCache = parsed; hasSyntaxErrors = parsed.erroneous; projection = Projection(source: text, parsed: parsed)
        includes = literalIncludes(text,parsed)
        imports = literalIncludes(text,parsed,kind:"ModuleImport")
    }
    public func editingCopy() -> DocumentBuffer {
        let copy = DocumentBuffer(source)
        copy.referencePresentations = referencePresentations; copy.collapsedSourceStarts = collapsedSourceStarts
        copy.projection = projection; copy.selection = selection
        return copy
    }
    public func breakUndoGroup() { if !undoSteps.isEmpty { undoSteps[undoSteps.count-1].group = "" } }
    @discardableResult public func moveInclude(_ from: Int, before target: Int) -> Bool {
        moveInclude(from,target:target,after:false)
    }
    @discardableResult public func moveInclude(_ from: Int, after target: Int) -> Bool {
        moveInclude(from,target:target,after:true)
    }
    private func moveInclude(_ from: Int,target: Int,after: Bool) -> Bool {
        guard includes.indices.contains(from), includes.indices.contains(target), from != target else { return false }
        let bytes = Array(source.utf8)
        func line(_ include: LiteralInclude) -> ByteSpan? {
            var start = include.source.start, end = include.source.end
            while start > 0 && bytes[start-1] != 10 { start -= 1 }
            while end < bytes.count && bytes[end] != 10 { end += 1 }
            if end > start && bytes[end-1] == 13 { end -= 1 }
            let prefix = source.bytes(ByteSpan(start,include.source.start)), suffix = source.bytes(ByteSpan(include.source.end,end)).trimmingCharacters(in:.whitespaces)
            guard prefix.trimmingCharacters(in:.whitespaces).isEmpty, suffix.isEmpty || suffix.hasPrefix("//") else { return nil }
            return ByteSpan(start,end)
        }
        let rows = includes.compactMap(line)
        guard rows.count == includes.count else { return false }
        var contents = rows.map { source.bytes($0) }
        let moved = contents.remove(at:from), boundary = target+(after ? 1 : 0)
        let destination = boundary > from ? boundary-1 : boundary
        contents.insert(moved,at:destination)
        // Rotate only include-line contents. Every intervening newline, blank
        // line and separate comment remains byte-for-byte in its original slot.
        var text = source
        for i in rows.indices.reversed() { text = text.replacingBytes(rows[i],with:contents[i]) }
        let at = rows[destination].start+(0..<destination).reduce(0) { $0+contents[$1].utf8.count-rows[$1].count }
        return commit(text,selection:EditSelection(at,at))
    }
    @discardableResult public func commit(_ text: String, selection after: EditSelection, group: String = "", now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> Bool {
        guard let patch = SourcePatch.difference(source, text) else { selection = after; return false }
        let before = selection
        let merge = !group.isEmpty && redoSteps.isEmpty && undoSteps.last?.group == group && now-(undoSteps.last?.time ?? 0) < 0.8 && undoSteps.last?.after == before
        if merge {
            undoSteps[undoSteps.count-1].patches.append(patch); undoSteps[undoSteps.count-1].after = after; undoSteps[undoSteps.count-1].time = now
        } else { undoSteps.append(HistoryStep(patches: [patch], before: before, after: after, group: group, time: now)) }
        redoSteps.removeAll()
        while undoSteps.count > 1 && (undoSteps.count > 200 || historyBytes > 8*1024*1024) { undoSteps.removeFirst() }
        assign(text,patch:patch); selection = after; return true
    }
    public func loadExternal(_ text: String) {
        guard text != source else { return }; referencePresentations.removeAll(); collapsedSourceStarts.removeAll(); projection = Projection(source:source,parsed:parsed); undoSteps.removeAll(); redoSteps.removeAll(); assign(text)
        selection = EditSelection(min(selection.anchor, source.utf8.count), min(selection.focus, source.utf8.count))
    }
    private func assign(_ text: String, patch: SourcePatch? = nil) {
        if let change = patch ?? SourcePatch.difference(source,text) {
            referencePresentations = referencePresentations.compactMap { reference in
                if change.oldSpan.end <= reference.source.start { return reference.shifted(by:change.inserted.utf8.count-change.removed.utf8.count) }
                if change.start >= reference.source.end { return reference }
                return nil
            }
        }
        if let change = patch ?? SourcePatch.difference(source,text) {
            collapsedSourceStarts = Set(projection.blocks.filter { $0.collapsed }.compactMap { block in
                if change.start+change.removed.utf8.count <= block.source.start {
                    return block.source.start+change.inserted.utf8.count-change.removed.utf8.count
                }
                if change.start >= block.source.end { return block.source.start }
                return nil
            })
        }
        lastEditWasLocal = false
        // Conservative local reparse: one text block, no newline or structural
        // boundary change. Unknown code and cross-block edits always take the full path.
        if referencePresentations.isEmpty, !projection.blocks.contains(where:{ $0.inlines.flatMap(\.runs).contains(where: \.atomic) }), !hasSyntaxErrors, let patch, !patch.inserted.contains("\n"), !patch.removed.contains("\n"),
           let index = projection.blocks.firstIndex(where:{ $0.editable && patch.start >= $0.body.start && patch.start+patch.removed.utf8.count <= $0.body.end }) {
            let old = projection.blocks[index], delta = patch.inserted.utf8.count-patch.removed.utf8.count
            let raw = text.bytes(ByteSpan(old.source.start,old.source.end+delta))
            if !raw.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !raw.contains("#include") && !source.bytes(old.source).contains("#include") {
                let parsed = ParsedSource.parse(raw), local = Projection(source:raw,parsed:parsed)
                if !parsed.erroneous, local.blocks.count == 1, local.blocks[0].kind == old.kind, local.blocks[0].level == old.level {
                    var blocks = projection.blocks
                    blocks[index] = local.blocks[0].shifted(by:old.source.start)
                    for i in blocks.indices where i > index { blocks[i] = blocks[i].shifted(by:delta) }
                    source = text; parsedCache = nil; projection = Projection(blocks:blocks)
                    includes = includes.map { item in var item = item; if item.source.start >= patch.start { item.source = ByteSpan(item.source.start+delta,item.source.end+delta) }; return item }
                    imports = imports.map { item in var item = item; if item.source.start >= patch.start { item.source = ByteSpan(item.source.start+delta,item.source.end+delta) }; return item }
                    revision += 1; lastEditWasLocal = true; return
                }
            }
        }
        source = text; let fresh = ParsedSource.parse(text); parsedCache = fresh; hasSyntaxErrors = fresh.erroneous
        includes = literalIncludes(text,fresh)
        imports = literalIncludes(text,fresh,kind:"ModuleImport")
        projection = folded(Projection(source:text,parsed:fresh,references:referencePresentations)); revision += 1
    }
    public func undo() {
        guard let step = undoSteps.popLast() else { return }
        var text = source
        for p in step.patches.reversed() { text = text.replacingBytes(p.newSpan, with: p.removed) }
        assign(text); selection = step.before; redoSteps.append(step)
    }
    public func redo() {
        guard let step = redoSteps.popLast() else { return }
        var text = source
        for p in step.patches { text = text.replacingBytes(p.oldSpan, with: p.inserted) }
        assign(text); selection = step.after; undoSteps.append(step)
    }
    public func editSource(_ range: NSRange, text: String, group: String = "source") {
        let span = ByteSpan(source.byteOffset(utf16: range.location), source.byteOffset(utf16: NSMaxRange(range)))
        let end = span.start+text.utf8.count
        commit(source.replacingBytes(span, with: text), selection: EditSelection(end,end), group: text.contains("\n") ? "" : group)
    }
    public func editWrite(_ range: NSRange, text: String, raw: Bool = false, group: String = "write", styleOverride: TextStyle? = nil) {
        let range = projection.atomicRange(range)
        if editCell(range,group:group,operation:{ model,range in model.editWrite(range,text:text,raw:raw,group:group,styleOverride:styleOverride) }) { return }
        if range.length > 0, projection.blocks.contains(where:{ !$0.cellRanges.isEmpty && range.location <= NSMaxRange($0.display) && NSMaxRange(range) >= $0.display.location }) {
            // Cell separators cannot be deleted as ordinary source characters.
            // A selection across cells edits their contents as one transaction;
            // a whole-table selection replaces the complete source block.
            let draft = editingCopy()
            var regions: [(NSRange,Int?)] = []
            for (index,block) in projection.blocks.enumerated() {
                let overlap = NSIntersectionRange(block.display,range)
                guard overlap.length > 0 else { continue }
                if !block.cellRanges.isEmpty && overlap == block.display { regions.append((overlap,index)) }
                else if !block.cellRanges.isEmpty {
                    for cell in block.cellRanges {
                        let intersection = NSIntersectionRange(NSRange(location:block.display.location+cell.location,length:cell.length),range)
                        if intersection.length > 0 { regions.append((intersection,nil)) }
                    }
                } else { regions.append((overlap,nil)) }
            }
            var caret = selection.focus
            for (offset,region) in regions.enumerated().reversed() {
                let inserted = offset == 0 ? text : ""
                if let index = region.1 {
                    let span = draft.projection.blocks[index].source, replacement = raw ? inserted : escapeTypst(inserted)
                    draft.commit(draft.source.replacingBytes(span,with:replacement),selection:EditSelection(span.start+replacement.utf8.count,span.start+replacement.utf8.count))
                } else { draft.editWrite(region.0,text:inserted,raw:raw,group:"",styleOverride:styleOverride) }
                caret = draft.selection.focus
            }
            commit(draft.source,selection:EditSelection(caret,caret)); return
        }
        let first = projection.blockIndex(at: range.location), last = projection.blockIndex(at: NSMaxRange(range))
        let a = projection.blocks[first], b = projection.blocks[last]
        let from = max(0, range.location-a.display.location), to = min(b.display.length, max(0, NSMaxRange(range)-b.display.location))
        if !a.editable || !b.editable {
            let start = projection.sourceOffset(at: range.location), end = projection.sourceOffset(at: NSMaxRange(range))
            let insert = raw ? text : text
            commit(source.replacingBytes(ByteSpan(start,end), with: insert), selection: EditSelection(start+insert.utf8.count,start+insert.utf8.count), group: group)
            return
        }
        // Removing the complete contents of a mark removes its empty wrapper
        // as well. Keep partial edits, neighboring syntax and custom expressions.
        if first == last, !raw, text.isEmpty, from < to,
           let span = emptiedMarkSpan(a.inlines,from:from,to:to) {
            commit(source.replacingBytes(span,with:""),selection:EditSelection(span.start,span.start),group:group)
            return
        }
        // A replacement inside one literal run keeps its existing wrappers in
        // place. Splitting a bold run into adjacent *...* chunks is not valid
        // Typst markup at every word boundary.
        if first == last, !raw, !text.contains("\n"), !text.contains("\r") {
            var offset = 0
            for run in a.inlines.flatMap(\.runs) {
                let end = offset+run.text.utf16.count
                if run.literal, from >= offset, to <= end, styleOverride == nil || (styleOverride!.bold == run.style.bold && styleOverride!.italic == run.style.italic) {
                    let start = run.source.start+run.text.byteOffset(utf16:from-offset)
                    let finish = run.source.start+run.text.byteOffset(utf16:to-offset), inserted = escapeTypst(text)
                    let caret = start+inserted.utf8.count
                    commit(source.replacingBytes(ByteSpan(start,finish),with:inserted),selection:EditSelection(caret,caret),group:group)
                    return
                }
                offset = end
            }
        }
        let prefix = sliceInlines(a.inlines, 0, min(from,a.display.length), source: source)
        let suffix = sliceInlines(b.inlines, to, b.display.length, source: source)
        var inserted = raw ? text : escapeTypst(text)
        if !raw {
            // Native paste paragraphs use the same split/list semantics as Return.
            inserted = inserted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let delimiter = a.kind == "bullet" ? "\n- " : a.kind == "number" ? "\n+ " : "\n\n"
            inserted = inserted.replacingOccurrences(of: "\n", with: delimiter)
            if !text.contains("\n"), let style = styleOverride ?? styleAt(a, offset: from), !text.isEmpty {
                if style.italic { inserted = styleOverride == nil ? "_"+inserted+"_" : "#emph["+inserted+"]" }
                if style.bold { inserted = styleOverride == nil ? "*"+inserted+"*" : "#strong["+inserted+"]" }
            }
        }
        var replacement = prefix + inserted + suffix
        let expectedText = (a.text as NSString).substring(to:min(from,a.display.length))+text+(b.text as NSString).substring(from:to)
        if styleOverride != nil && (ParsedSource.parse(replacement).erroneous || first == last && Projection(source:replacement,parsed:ParsedSource.parse(replacement)).text != expectedText) {
            replacement = sliceInlines(a.inlines,0,min(from,a.display.length),source:source,explicitMarks:true)+inserted+sliceInlines(b.inlines,to,b.display.length,source:source,explicitMarks:true)
        }
        let span = ByteSpan(a.body.start,b.body.end)
        let prefixLength = replacement == prefix+inserted+suffix ? prefix.utf8.count : sliceInlines(a.inlines,0,min(from,a.display.length),source:source,explicitMarks:true).utf8.count
        let caret = span.start + prefixLength + inserted.utf8.count
        commit(source.replacingBytes(span, with: replacement), selection: EditSelection(caret,caret), group: text.contains("\n") || raw ? "" : group)
    }
    private func emptiedMarkSpan(_ nodes: [Inline],from: Int,to: Int) -> ByteSpan? {
        var offset = 0
        for node in nodes {
            if case let .group(span,prefix,_,children) = node,
               from >= offset, to <= offset+node.length {
                if from == offset, to == offset+node.length,
                   ["*","_","`","#strong[","#emph["].contains(prefix) { return span }
                if let span = emptiedMarkSpan(children,from:from-offset,to:to-offset) { return span }
            }
            offset += node.length
        }
        return nil
    }
    private func editCell(_ range: NSRange, group: String = "", operation: (DocumentBuffer,NSRange) -> Void) -> Bool {
        guard let cell = projection.tableCell(at:range) else { return false }
        let model = DocumentBuffer(source.bytes(cell.source)), local = NSRange(location:range.location-cell.display.location,length:range.length)
        model.setReferencePresentations(referencePresentations.filter { $0.source.start >= cell.source.start && $0.source.end <= cell.source.end }.map { $0.shifted(by:-cell.source.start) })
        model.selection = EditSelection(model.projection.sourceOffset(at:local.location),model.projection.sourceOffset(at:NSMaxRange(local)))
        operation(model,local)
        commit(source.replacingBytes(cell.source,with:model.source),selection:EditSelection(cell.source.start+model.selection.anchor,cell.source.start+model.selection.focus),group:group.isEmpty ? "" : "table:\(cell.block):\(cell.cell):\(group)")
        return true
    }
    private func styleAt(_ b: ProjectedBlock, offset: Int) -> TextStyle? {
        var at = 0
        for r in b.inlines.flatMap(\.runs) {
            if offset > at && offset <= at+r.text.utf16.count { return r.style }
            at += r.text.utf16.count
        }
        return nil
    }
    public func split(_ range: NSRange) {
        if editCell(range,operation:{ $0.split($1) }) { return }
        if range.length > 0 {
            let draft = editingCopy(); draft.selection = selection
            draft.editWrite(range,text:"",group:"")
            draft.split(NSRange(location:draft.projection.displayOffset(at:draft.selection.focus),length:0))
            commit(draft.source,selection:draft.selection); return
        }
        let caret = projection.displayOffset(at: selection.focus)
        let index = projection.blockIndex(at: caret), b = projection.blocks[index]
        if ["bullet", "number"].contains(b.kind) && b.text.trimmingCharacters(in: .whitespaces).isEmpty {
            commit(source.replacingBytes(b.source, with: "\n"), selection: EditSelection(b.source.start+1,b.source.start+1)); return
        }
        if !b.editable {
            let at = caret <= b.display.location ? b.source.start : b.source.end
            commit(source.replacingBytes(ByteSpan(at,at), with: "\n\n"), selection: EditSelection(at+2,at+2)); return
        }
        editWrite(NSRange(location: caret,length: 0), text: "\n", group: "")
    }
    public func lineBreak(_ range: NSRange) {
        editWrite(range,text:"\\ ",raw:true,group:"")
    }
    public func format(_ range: NSRange, italic: Bool) {
        let range = projection.atomicRange(range)
        guard range.length > 0 else { return }
        if editCell(range,operation:{ $0.format($1,italic:italic) }) { return }
        if projection.blocks.contains(where:{ !$0.cellRanges.isEmpty && NSIntersectionRange($0.display,range).length > 0 }) {
            let draft = editingCopy()
            for block in projection.blocks.reversed() {
                let regions = block.cellRanges.isEmpty ? [block.display] : block.cellRanges.map { NSRange(location:block.display.location+$0.location,length:$0.length) }
                for region in regions.reversed() {
                    let intersection = NSIntersectionRange(region,range)
                    if intersection.length > 0 { draft.format(intersection,italic:italic) }
                }
            }
            commit(draft.source,selection:selection)
            selection = EditSelection(projection.sourceOffset(at:range.location),projection.sourceOffset(at:NSMaxRange(range)))
            if !undoSteps.isEmpty { undoSteps[undoSteps.count-1].after = selection }
            return
        }
        let start = projection.blockIndex(at: range.location), end = projection.blockIndex(at: NSMaxRange(range))
        var text = source
        for index in (start...end).reversed() {
            let b = projection.blocks[index]; guard b.editable else { continue }
            let a = max(0,range.location-b.display.location), z = min(b.display.length,NSMaxRange(range)-b.display.location)
            guard z > a else { continue }
            let wrapper = italic ? "_" : "*"
            var offset = 0
            let selectedRuns = b.inlines.flatMap(\.runs).filter { run in
                defer { offset += run.text.utf16.count }
                return offset < z && offset+run.text.utf16.count > a
            }
            let remove = !selectedRuns.isEmpty && selectedRuns.allSatisfy { italic ? $0.style.italic : $0.style.bold }
            let unmarked = sliceInlines(b.inlines,a,z,source:source,removingMark:italic ? 2 : 1)
            let styled = remove ? unmarked : wrapper+unmarked+wrapper
            var replacement = sliceInlines(b.inlines,0,a,source:source)+styled+sliceInlines(b.inlines,z,b.display.length,source:source)
            let styledParsed = ParsedSource.parse(replacement)
            if styledParsed.erroneous || Projection(source:replacement,parsed:styledParsed).text != b.text {
                let explicit = remove ? unmarked : (italic ? "#emph[" : "#strong[")+unmarked+"]"
                replacement = sliceInlines(b.inlines,0,a,source:source,explicitMarks:true)+explicit+sliceInlines(b.inlines,z,b.display.length,source:source,explicitMarks:true)
            }
            text = text.replacingBytes(b.body,with:replacement)
        }
        let oldStart = projection.sourceOffset(at: range.location), oldEnd = projection.sourceOffset(at: NSMaxRange(range))
        commit(text, selection: EditSelection(oldStart,oldEnd))
        let newStart = projection.sourceOffset(at: range.location), newEnd = projection.sourceOffset(at: NSMaxRange(range))
        selection = EditSelection(newStart,newEnd)
        if !undoSteps.isEmpty { undoSteps[undoSteps.count-1].after = selection }
    }
    public func setKind(_ index: Int, kind: String, level: Int = 0) {
        guard projection.blocks.indices.contains(index) else { return }
        let b = projection.blocks[index]; guard b.editable else { return }
        let prefix = kind == "heading" ? String(repeating:"=",count:max(1,level))+" " : kind == "bullet" ? "- " : kind == "number" ? "+ " : kind == "quote" ? "#quote(block: true)[" : ""
        let suffix = kind == "quote" ? "]" : ""
        let body = source.bytes(b.body)
        var leading = "", trailing = ""
        if kind == "paragraph", body.isEmpty {
            // A removed list marker must leave an actual empty paragraph slot,
            // including between items separated by only one source newline.
            if index > 0, !source.bytes(ByteSpan(projection.blocks[index-1].source.end,b.source.start)).contains("\n\n") { leading = "\n" }
            if index+1 < projection.blocks.count, !source.bytes(ByteSpan(b.source.end,projection.blocks[index+1].source.start)).contains("\n\n") { trailing = "\n" }
        }
        let text = source.replacingBytes(b.source,with:leading+prefix+body+suffix+trailing)
        let at = b.source.start+leading.utf8.count+prefix.utf8.count+min(max(0,selection.focus-b.body.start),body.utf8.count)
        commit(text,selection:EditSelection(at,at))
    }
    public func setKind(at range: NSRange, kind: String, level: Int = 0) {
        if editCell(range,operation:{ model,local in model.setKind(at:local,kind:kind,level:level) }) { return }
        setKind(projection.blockIndex(at:range.location),kind:kind,level:level)
    }
    public func blockAction(_ index: Int, action: String) {
        guard projection.blocks.indices.contains(index) else { return }
        let b = projection.blocks[index]
        if action == "duplicate" {
            let insert = "\n\n"+source.bytes(b.source)
            commit(source.replacingBytes(ByteSpan(b.source.end,b.source.end),with:insert),selection:EditSelection(b.source.end+2,b.source.end+2))
        } else {
            var end = b.source.end
            if index+1 < projection.blocks.count { end = projection.blocks[index+1].source.start }
            commit(source.replacingBytes(ByteSpan(b.source.start,end),with:""),selection:EditSelection(b.source.start,b.source.start))
        }
    }
    public func moveBlock(_ index: Int, before target: Int) {
        guard projection.blocks.indices.contains(index), target >= 0, target <= projection.blocks.count, index != target, index+1 != target else { return }
        let blocks = projection.blocks, b = blocks[index]
        let end = index+1 < blocks.count ? blocks[index+1].source.start : source.utf8.count
        let removed = ByteSpan(b.source.start,end)
        var insert = source.bytes(removed)
        if !insert.hasSuffix("\n\n") { insert += "\n\n" }
        var at = target < blocks.count ? blocks[target].source.start : source.utf8.count
        var text = source.replacingBytes(removed,with:"")
        if at > removed.start { at -= removed.count }
        if at > 0 && !text.bytes(ByteSpan(0,at)).hasSuffix("\n\n") { insert = "\n\n"+insert }
        text = text.replacingBytes(ByteSpan(at,at),with:insert)
        commit(text,selection:EditSelection(at,at))
    }
    // Resolve a drop once in source coordinates, shared by the outline and edit.
    // An inside drop appends to a parent; sibling drops include the whole subtree.
    public func sectionMove(_ index: Int,target: Int,placement: SectionPlacement) -> (span: ByteSpan,at: Int)? {
        let blocks = projection.blocks
        guard blocks.indices.contains(index), blocks.indices.contains(target), index != target,
              blocks[index].kind == "heading", blocks[target].kind == "heading" else { return nil }
        let level = blocks[index].level, targetLevel = blocks[target].level
        switch placement {
        case .inside: guard targetLevel < level else { return nil }
        case .before, .after: guard targetLevel == level else { return nil }
        }
        let end = blocks.dropFirst(index+1).first { $0.kind == "heading" && $0.level <= level }?.source.start ?? source.utf8.count
        let span = ByteSpan(blocks[index].source.start,end)
        // A parent cannot be dropped into, or relative to, its own descendants.
        guard blocks[target].source.start < span.start || blocks[target].source.start >= span.end else { return nil }
        let at = placement == .before ? blocks[target].source.start :
            blocks.dropFirst(target+1).first { $0.kind == "heading" && $0.level <= targetLevel }?.source.start ?? source.utf8.count
        guard at < span.start || at > span.end else { return nil }
        return (span,at)
    }
    @discardableResult public func moveSection(_ index: Int,before target: Int) -> Bool {
        moveSection(index,target:target,placement:.before)
    }
    @discardableResult public func moveSection(_ index: Int,after target: Int) -> Bool {
        moveSection(index,target:target,placement:.after)
    }
    @discardableResult public func moveSection(_ index: Int,into target: Int) -> Bool {
        moveSection(index,target:target,placement:.inside)
    }
    @discardableResult public func moveSection(_ index: Int,target: Int,placement: SectionPlacement) -> Bool {
        guard let move = sectionMove(index,target:target,placement:placement) else { return false }
        let span = move.span
        var at = move.at
        let raw = source.bytes(span)
        var text = source.replacingBytes(span,with:"")
        if at >= span.end { at -= span.count }
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        func separator(after value: String) -> String {
            value.hasSuffix(newline+newline) ? "" : value.hasSuffix(newline) ? newline : newline+newline
        }
        let prefix = at > 0 ? separator(after:text.bytes(ByteSpan(0,at))) : ""
        text = text.replacingBytes(ByteSpan(at,at),with:prefix+raw+separator(after:raw))
        return commit(text,selection:EditSelection(at+prefix.utf8.count,at+prefix.utf8.count))
    }
    public func copy(_ range: NSRange) -> RichFragment {
        let range = projection.atomicRange(range)
        if let cell = projection.tableCell(at:range) {
            let model = DocumentBuffer(source.bytes(cell.source))
            model.setReferencePresentations(referencePresentations.filter { $0.source.start >= cell.source.start && $0.source.end <= cell.source.end }.map { $0.shifted(by:-cell.source.start) })
            return model.copy(NSRange(location:range.location-cell.display.location,length:range.length))
        }
        let first = projection.blockIndex(at:range.location), last = projection.blockIndex(at:NSMaxRange(range))
        var pieces: [String] = []
        for index in first...last {
            let b = projection.blocks[index]
            let a = max(0,range.location-b.display.location), z = min(b.display.length,NSMaxRange(range)-b.display.location)
            if a == 0 && z == b.display.length { pieces.append(source.bytes(b.source)) }
            else if !b.cellRanges.isEmpty {
                for (cell,display) in b.cellRanges.enumerated() {
                    let selected = NSIntersectionRange(NSRange(location:b.display.location+display.location,length:display.length),range)
                    if selected.length > 0 {
                        let model = DocumentBuffer(source.bytes(b.tableCells[cell]))
                        let span = b.tableCells[cell]
                        model.setReferencePresentations(referencePresentations.filter { $0.source.start >= span.start && $0.source.end <= span.end }.map { $0.shifted(by:-span.start) })
                        pieces.append(model.copy(NSRange(location:selected.location-b.display.location-display.location,length:selected.length)).source)
                    }
                }
            } else { pieces.append(sliceInlines(b.inlines,a,z,source:source)) }
        }
        var plain = (projection.text as NSString).substring(with:range)
        if projection.blocks.contains(where:{ $0.collapsed && NSIntersectionRange($0.display,range).length > 0 }) {
            let expanded = Projection(source:source,parsed:parsed,references:referencePresentations)
            let a = expanded.displayOffset(at:projection.sourceOffset(at:range.location)), z = expanded.displayOffset(at:projection.sourceOffset(at:NSMaxRange(range)))
            plain = (expanded.text as NSString).substring(with:NSRange(location:a,length:max(0,z-a)))
        }
        let entire = range.location == projection.blocks[first].display.location && NSMaxRange(range) == NSMaxRange(projection.blocks[last].display)
        return RichFragment(source:pieces.joined(separator:"\n\n"),plain:plain,block:entire)
    }
    public func paste(_ fragment: RichFragment, range: NSRange) {
        let range = projection.atomicRange(range)
        if editCell(range,operation:{ model,range in model.editWrite(range,text:fragment.source,raw:true,group:"") }) { return }
        let index = projection.blockIndex(at:range.location), b = projection.blocks[index]
        if fragment.block && range.location == b.display.location && range.length >= b.display.length {
            let at = b.source.start
            commit(source.replacingBytes(ByteSpan(at,projection.blocks[projection.blockIndex(at:NSMaxRange(range))].source.end),with:fragment.source),selection:EditSelection(at+fragment.source.utf8.count,at+fragment.source.utf8.count))
        } else if fragment.block && range.length == 0 {
            let offset = range.location-b.display.location
            if b.editable && offset > 0 && offset < b.display.length {
                let prefix = source.bytes(ByteSpan(b.source.start,b.body.start)), suffix = source.bytes(ByteSpan(b.body.end,b.source.end))
                let left = prefix+sliceInlines(b.inlines,0,offset,source:source)+suffix
                let right = (b.kind == "heading" ? "" : prefix)+sliceInlines(b.inlines,offset,b.display.length,source:source)+(b.kind == "heading" ? "" : suffix)
                let inserted = left+"\n\n"+fragment.source+"\n\n"+right
                let caret = b.source.start+left.utf8.count+2+fragment.source.utf8.count
                commit(source.replacingBytes(b.source,with:inserted),selection:EditSelection(caret,caret)); return
            }
            let before = range.location == b.display.location
            let at = before ? b.source.start : b.source.end
            let inserted = (before ? "" : "\n\n")+fragment.source+(before ? "\n\n" : "")
            commit(source.replacingBytes(ByteSpan(at,at),with:inserted),selection:EditSelection(at+inserted.utf8.count,at+inserted.utf8.count))
        } else { editWrite(range,text:fragment.source,raw:true,group:"") }
    }
}


extension DocumentBuffer {
    private func folded(_ original: Projection) -> Projection {
        var blocks = original.blocks
        for index in blocks.indices where blocks[index].kind == "source" && collapsedSourceStarts.contains(blocks[index].source.start) {
            let raw = source.bytes(blocks[index].source)
            let lines = raw.components(separatedBy:"\n")
            let summary = String((lines.first ?? "Typst code").prefix(70))+"  …  \(lines.count) lines"
            blocks[index].inlines = [.text(summary,blocks[index].source,TextStyle(),false)]
            blocks[index].collapsed = true
        }
        return Projection(blocks:blocks)
    }
    public func setReferencePresentations(_ references: [ReferencePresentation]) {
        guard referencePresentations != references else { return }
        referencePresentations = references
        projection = folded(Projection(source:source,parsed:parsed,references:references))
        presentationRevision += 1; lastEditWasLocal = false
    }
    public func setSourceCollapsed(_ index: Int,_ collapsed: Bool) {
        guard projection.blocks.indices.contains(index), projection.blocks[index].kind == "source" else { return }
        let start = projection.blocks[index].source.start
        if collapsed { collapsedSourceStarts.insert(start) } else { collapsedSourceStarts.remove(start) }
        projection = folded(Projection(source:source,parsed:parsed,references:referencePresentations)); presentationRevision += 1
        lastEditWasLocal = false
    }

    /// Insert/delete a row or column without regenerating cell contents, options or comments.
    @discardableResult public func changeTable(_ index: Int,cell: Int,column: Bool,action: String) -> Bool {
        guard projection.blocks.indices.contains(index) else { return false }
        let block = projection.blocks[index], cols = block.columns, count = block.tableCells.count
        guard cols > 0, count > 0, count % cols == 0, cell >= 0, cell < count,
              let call = parsed.tree.descendants("FuncCall").first(where:{ $0.start == block.source.start+1 }),
              let table = nativeTableArguments(call,source:source) else { return false }
        let args = table.args, cells = table.cells, number = table.columns
        guard cells.count == count else { return false }
        let dimension = column ? cols : count/cols, position = column ? cell%cols : cell/cols
        guard ["before","after","delete"].contains(action), action != "delete" || dimension > 1 else { return false }
        var edits: [(ByteSpan,String)] = []
        if action == "delete" {
            let removing = cells.indices.filter { column ? $0%cols == position : $0/cols == position }
            let commas = args.children.filter { $0.kind == "Comma" }
            var removedCommas = Set<Int>()
            for at in removing {
                edits.append((cells[at].span,""))
                if let comma = commas.first(where:{ $0.start >= cells[at].end }) ?? commas.last(where:{ $0.end <= cells[at].start }), removedCommas.insert(comma.start).inserted { edits.append((comma.span,"")) }
            }
        } else if column {
            for row in 0..<count/cols {
                let argument = cells[row*cols+position]
                let at = action == "before" ? argument.start : argument.end
                edits.append((ByteSpan(at,at),action == "before" ? "[], " : ", []"))
            }
        } else {
            let at = action == "before" ? cells[position*cols].start : cells[(position+1)*cols-1].end
            let blanks = Array(repeating:"[]",count:cols).joined(separator:", ")
            edits.append((ByteSpan(at,at),action == "before" ? blanks+",\n  " : ",\n  "+blanks))
        }
        if column { edits.append((number.span,String(cols+(action == "delete" ? -1 : 1)))) }
        var next = source
        for (range,text) in edits.sorted(by:{ $0.0.start > $1.0.start }) { next = next.replacingBytes(range,with:text) }
        let parsedNext = ParsedSource.parse(next)
        guard !parsedNext.erroneous else { return false }
        let projected = Projection(source:next,parsed:parsedNext), updated = projected.blocks[index]
        let row = cell/cols+(column ? 0 : action == "after" ? 1 : 0)
        let col = cell%cols+(column && action == "after" ? 1 : 0)
        let target = min(row,updated.tableCells.count/updated.columns-1)*updated.columns+min(col,updated.columns-1)
        let range = updated.cellRanges[target]
        let a = projected.sourceOffset(at:updated.display.location+range.location)
        let z = projected.sourceOffset(at:updated.display.location+NSMaxRange(range))
        return commit(next,selection:EditSelection(a,z))
    }
}
