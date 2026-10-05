import AppKit
import PDFKit
import BlankCore

struct SearchPart { var page: Int; var range: NSRange }
struct DocumentMatch: Identifiable {
    var id: Int
    var path: String
    var range: NSRange
    var snippet: String
    var snippetMatch: NSRange
    var parts: [SearchPart] = []
    var page: Int? { parts.first?.page }
}
struct SearchResultGroup: Identifiable {
    var matches: [DocumentMatch]
    var id: Int { matches[0].id }
}

// Search snapshots are immutable. PDFKit searches a private document on the
// worker queue; page/range identities are mapped back to the live PDF on main.
@MainActor final class DocumentSearch: ObservableObject {
    weak var session: DocumentSession?
    @Published private(set) var matches: [DocumentMatch] = []
    @Published private(set) var searching = false
    @Published private(set) var selected = -1
    private var generation = 0
    private var work: DispatchWorkItem?
    private var pendingDirection: Bool?
    private var completedQuery = ""
    private var revealing = false
    private var highlightsApplied = false
    private let queue = DispatchQueue(label:"blank.search",qos:.userInitiated)
    let limit = 5000
    var groups: [SearchResultGroup] {
        var groups: [SearchResultGroup] = []
        for match in matches {
            if let page = match.page, groups.last?.matches.first?.page == page {
                groups[groups.count-1].matches.append(match)
            } else { groups.append(SearchResultGroup(matches:[match])) }
        }
        return groups
    }
    var status: String { searching ? "Searching…" : "\(matches.count)\(matches.count == limit ? "+" : "") matches" }
    init(session: DocumentSession) { self.session = session }
    func update(revealFirst: Bool = true) {
        guard let session, !revealing else { return }
        if session.searchQuery.isEmpty && matches.isEmpty && work == nil && !highlightsApplied { return }
        generation += 1; let token = generation
        work?.cancel(); pendingDirection = nil; completedQuery = ""; selected = -1
        matches = []; clearHighlights()
        guard session.searchVisible, !session.searchQuery.isEmpty else { searching = false; work = nil; return }
        if session.searchVisible { session.sidebar = true }
        searching = true
        let query = session.searchQuery, mode = session.mode, sensitive = session.caseSensitive, limit = limit
        let snapshots = (session.projectSearch ? session.includes : [session.active]).compactMap { path -> (String,String)? in
            guard let model = session.buffers[path] else { return nil }
            return (path,mode == .source ? model.source : model.projection.text)
        }
        let data = session.pdfData, active = session.active
        let task = DispatchWorkItem { [weak self] in
            let options: NSString.CompareOptions = sensitive ? [] : [.caseInsensitive]
            var results: [DocumentMatch] = []
            if mode == .preview {
                if let data, let pdf = PDFDocument(data:data) {
                    for selection in pdf.findString(query,withOptions:options).prefix(limit) {
                        let parts = selection.pages.flatMap { page in
                            (0..<selection.numberOfTextRanges(on:page)).map { SearchPart(page:pdf.index(for:page),range:selection.range(at:$0,on:page)) }
                        }
                        guard let part = parts.first, let text = pdf.page(at:part.page)?.string else { continue }
                        let context = Self.context(text,range:part.range)
                        results.append(DocumentMatch(id:results.count,path:active,range:part.range,snippet:context.0,snippetMatch:context.1,parts:parts))
                    }
                }
            } else {
                for (path,string) in snapshots {
                    let text = string as NSString; var at = 0
                    while at < text.length && results.count < limit {
                        let range = text.range(of:query,options:options,range:NSRange(location:at,length:text.length-at))
                        if range.location == NSNotFound { break }
                        let context = Self.context(string,range:range)
                        results.append(DocumentMatch(id:results.count,path:path,range:range,snippet:context.0,snippetMatch:context.1))
                        at = NSMaxRange(range)
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, let session = self.session else { return }
                self.work = nil; self.matches = results; self.searching = false; self.completedQuery = query
                self.applyHighlights()
                if let next = self.pendingDirection { self.pendingDirection = nil; self.navigate(next:next) }
                else if session.searchVisible, !results.isEmpty {
                    self.selected = 0
                    if revealFirst { self.reveal(0,select:false) }
                }
            }
        }
        work = task; queue.asyncAfter(deadline:.now()+0.12,execute:task)
    }
    nonisolated static func context(_ string: String,range: NSRange) -> (String,NSRange) {
        let text = string as NSString
        guard range.location != NSNotFound, range.location <= text.length, range.length <= text.length-range.location else { return ("",NSRange(location:0,length:0)) }
        let start = max(0,range.location-45), end = min(text.length,NSMaxRange(range)+65)
        let span = text.rangeOfComposedCharacterSequences(for:NSRange(location:start,length:end-start))
        return (text.substring(with:span).replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\u{2028}",with:" "),NSRange(location:range.location-span.location,length:range.length))
    }
    func navigate(next: Bool = true) {
        guard let session, !session.searchQuery.isEmpty else { return }
        if searching || completedQuery != session.searchQuery { pendingDirection = next; return }
        guard !matches.isEmpty else { return }
        let index = selected < 0 ? (next ? 0 : matches.count-1) : (selected+(next ? 1 : matches.count-1)) % matches.count
        reveal(index,select:true)
    }
    func selection(_ match: DocumentMatch) -> PDFSelection? {
        guard let pdf = session?.pdf else { return nil }
        let selection = PDFSelection(document:pdf)
        for part in match.parts { if let piece = pdf.page(at:part.page)?.selection(for:part.range) { selection.add(piece) } }
        selection.color = .systemYellow
        return selection
    }
    func reveal(_ index: Int,select: Bool = true) {
        guard matches.indices.contains(index), let session else { return }
        let match = matches[index]
        revealing = true; defer { revealing = false }
        if select { selected = index }
        if session.mode == .preview {
            guard let selection = selection(match) else { return }
            if select { session.pdfView?.setCurrentSelection(selection,animate:true) }
            session.pdfView?.go(to:selection)
        } else {
            if session.active != match.path { session.switchFile(match.path) }
            guard let editor = session.editor, NSMaxRange(match.range) <= editor.string.utf16.count else { return }
            if select { editor.setSelectedRange(match.range); editor.captureSelection() }
            editor.scrollRangeToVisible(match.range)
            editor.showFindIndicator(for:match.range)
        }
    }
    func clearHighlights() {
        guard highlightsApplied, let session else { return }
        highlightsApplied = false
        if let editor = session.editor {
            let all = NSRange(location:0,length:editor.string.utf16.count)
            editor.layoutManager?.removeTemporaryAttribute(.backgroundColor,forCharacterRange:all)
            editor.layoutManager?.removeTemporaryAttribute(.foregroundColor,forCharacterRange:all)
        }
        session.pdfView?.highlightedSelections = nil
    }
    func applyHighlights() {
        clearHighlights()
        guard let session, session.searchVisible, !session.searchQuery.isEmpty else { return }
        highlightsApplied = !matches.isEmpty
        if session.mode == .preview { session.pdfView?.highlightedSelections = matches.compactMap(selection) }
        else if let editor = session.editor {
            for match in matches where match.path == session.active && NSMaxRange(match.range) <= editor.string.utf16.count {
                editor.layoutManager?.addTemporaryAttributes([.backgroundColor:NSColor.systemYellow.withAlphaComponent(0.8),.foregroundColor:NSColor.black],forCharacterRange:match.range)
            }
        }
    }
}
