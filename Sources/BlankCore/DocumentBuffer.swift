import Foundation

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
    public private(set) var parsed: ParsedSource
    public private(set) var projection: Projection
    public private(set) var revision: Int = 0
    public var selection = EditSelection(0, 0)
    private var undoSteps: [HistoryStep] = [], redoSteps: [HistoryStep] = []
    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    public var historyBytes: Int { (undoSteps + redoSteps).reduce(0) { $0+$1.bytes } }
    public init(_ text: String = "") {
        source = text; parsed = ParsedSource.parse(text); projection = Projection(source: text, parsed: parsed)
    }
    public func breakUndoGroup() { if !undoSteps.isEmpty { undoSteps[undoSteps.count-1].group = "" } }
    @discardableResult public func commit(_ text: String, selection after: EditSelection, group: String = "", now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> Bool {
        guard let patch = SourcePatch.difference(source, text) else { selection = after; return false }
        let before = selection
        let merge = !group.isEmpty && redoSteps.isEmpty && undoSteps.last?.group == group && now-(undoSteps.last?.time ?? 0) < 0.8 && undoSteps.last?.after == before
        if merge {
            undoSteps[undoSteps.count-1].patches.append(patch); undoSteps[undoSteps.count-1].after = after; undoSteps[undoSteps.count-1].time = now
        } else { undoSteps.append(HistoryStep(patches: [patch], before: before, after: after, group: group, time: now)) }
        redoSteps.removeAll()
        while undoSteps.count > 1 && (undoSteps.count > 200 || historyBytes > 8*1024*1024) { undoSteps.removeFirst() }
        assign(text); selection = after; return true
    }
    public func loadExternal(_ text: String) {
        guard text != source else { return }; undoSteps.removeAll(); redoSteps.removeAll(); assign(text)
        selection = EditSelection(min(selection.anchor, source.utf8.count), min(selection.focus, source.utf8.count))
    }
    private func assign(_ text: String) { source = text; parsed = ParsedSource.parse(text); projection = Projection(source: text, parsed: parsed); revision += 1 }
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
    public func editWrite(_ range: NSRange, text: String, raw: Bool = false, group: String = "write") {
        let first = projection.blockIndex(at: range.location), last = projection.blockIndex(at: NSMaxRange(range))
        let a = projection.blocks[first], b = projection.blocks[last]
        let from = max(0, range.location-a.display.location), to = min(b.display.length, max(0, NSMaxRange(range)-b.display.location))
        if !a.editable || !b.editable {
            let start = projection.sourceOffset(at: range.location), end = projection.sourceOffset(at: NSMaxRange(range))
            let insert = raw ? text : text
            commit(source.replacingBytes(ByteSpan(start,end), with: insert), selection: EditSelection(start+insert.utf8.count,start+insert.utf8.count), group: group)
            return
        }
        let prefix = sliceInlines(a.inlines, 0, min(from,a.display.length), source: source)
        let suffix = sliceInlines(b.inlines, to, b.display.length, source: source)
        var inserted = raw ? text : escapeTypst(text)
        if !raw {
            // Native paste paragraphs use the same split/list semantics as Return.
            inserted = inserted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let delimiter = a.kind == "bullet" ? "\n- " : a.kind == "number" ? "\n+ " : "\n\n"
            inserted = inserted.replacingOccurrences(of: "\n", with: delimiter)
            if !text.contains("\n"), let style = styleAt(a, offset: from), !text.isEmpty {
                if style.italic { inserted = "_" + inserted + "_" }
                if style.bold { inserted = "*" + inserted + "*" }
            }
        }
        let replacement = prefix + inserted + suffix
        let span = ByteSpan(a.body.start,b.body.end)
        let caret = span.start + prefix.utf8.count + inserted.utf8.count
        commit(source.replacingBytes(span, with: replacement), selection: EditSelection(caret,caret), group: text.contains("\n") || raw ? "" : group)
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
        if range.length > 0 { editWrite(range, text: "", group: "") }
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
    public func format(_ range: NSRange, italic: Bool) {
        guard range.length > 0 else { return }
        let start = projection.blockIndex(at: range.location), end = projection.blockIndex(at: NSMaxRange(range))
        var text = source
        for index in (start...end).reversed() {
            let b = projection.blocks[index]; guard b.editable else { continue }
            let a = max(0,range.location-b.display.location), z = min(b.display.length,NSMaxRange(range)-b.display.location)
            guard z > a else { continue }
            let wrapper = italic ? "_" : "*"
            let middle = sliceInlines(b.inlines,a,z,source: source)
            let selectedRuns = b.inlines.flatMap(\.runs)
            let remove = selectedRuns.allSatisfy { italic ? $0.style.italic : $0.style.bold }
            let styled = remove && middle.hasPrefix(wrapper) && middle.hasSuffix(wrapper) ? String(middle.dropFirst().dropLast()) : wrapper+middle+wrapper
            let replacement = sliceInlines(b.inlines,0,a,source:source)+styled+sliceInlines(b.inlines,z,b.display.length,source:source)
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
        let text = source.replacingBytes(b.source,with:prefix+body+suffix)
        let at = b.source.start+prefix.utf8.count+min(max(0,selection.focus-b.body.start),body.utf8.count)
        commit(text,selection:EditSelection(at,at))
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
    public func moveSection(_ index: Int, before target: Int) {
        let blocks = projection.blocks
        guard blocks.indices.contains(index), blocks.indices.contains(target), blocks[index].kind == "heading", blocks[target].kind == "heading", blocks[index].level == blocks[target].level else { return }
        let level = blocks[index].level
        let end = blocks.dropFirst(index+1).first { $0.kind == "heading" && $0.level <= level }?.source.start ?? source.utf8.count
        let span = ByteSpan(blocks[index].source.start,end)
        var at = blocks[target].source.start
        guard at < span.start || at >= span.end else { return }
        let raw = source.bytes(span)
        var text = source.replacingBytes(span,with:"")
        if at >= span.end { at -= span.count }
        text = text.replacingBytes(ByteSpan(at,at),with:raw.hasSuffix("\n\n") ? raw : raw+"\n\n")
        commit(text,selection:EditSelection(at,at))
    }
    public func copy(_ range: NSRange) -> RichFragment {
        let first = projection.blockIndex(at:range.location), last = projection.blockIndex(at:NSMaxRange(range))
        var pieces: [String] = []
        for index in first...last {
            let b = projection.blocks[index]
            let a = max(0,range.location-b.display.location), z = min(b.display.length,NSMaxRange(range)-b.display.location)
            if a == 0 && z == b.display.length { pieces.append(source.bytes(b.source)) }
            else { pieces.append(sliceInlines(b.inlines,a,z,source:source)) }
        }
        let plain = (projection.text as NSString).substring(with:range)
        let entire = range.location == projection.blocks[first].display.location && NSMaxRange(range) == NSMaxRange(projection.blocks[last].display)
        return RichFragment(source:pieces.joined(separator:"\n\n"),plain:plain,block:entire)
    }
    public func paste(_ fragment: RichFragment, range: NSRange) {
        let index = projection.blockIndex(at:range.location), b = projection.blocks[index]
        if fragment.block && range.location == b.display.location && range.length >= b.display.length {
            let at = b.source.start
            commit(source.replacingBytes(ByteSpan(at,projection.blocks[projection.blockIndex(at:NSMaxRange(range))].source.end),with:fragment.source),selection:EditSelection(at+fragment.source.utf8.count,at+fragment.source.utf8.count))
        } else if fragment.block && range.length == 0 {
            let before = range.location == b.display.location
            let at = before ? b.source.start : b.source.end
            let inserted = (before ? "" : "\n\n")+fragment.source+(before ? "\n\n" : "")
            commit(source.replacingBytes(ByteSpan(at,at),with:inserted),selection:EditSelection(at+inserted.utf8.count,at+inserted.utf8.count))
        } else { editWrite(range,text:fragment.source,raw:true,group:"") }
    }
}
