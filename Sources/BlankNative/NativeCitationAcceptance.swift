import AppKit
import Foundation
import BlankCore

// Intercept only Zotero's loopback endpoint; acceptance never needs a live library.
final class CitationAcceptanceProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var urls: [URL] = []
    static var requests: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost" && request.url?.port == 23119
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.urls.append(request.url!); Self.lock.unlock()
        let query = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{ $0.name == "q" })?.value ?? ""
        let title = query.isEmpty ? "Citation acceptance reference" : "Search result for " + query
        let bibliography = request.url?.query?.contains("format=biblatex") == true
        let data = bibliography ? Data("@book{original, author={Example, Jane}, title={Citation acceptance reference}, year={2026}, publisher={Press}}".utf8) : try! JSONSerialization.data(withJSONObject:[["key":"ABCD1234","data":["itemType":"book","title":title,"creators":[["lastName":"Example"]],"date":"2026"]]])
        let deliver = {
            self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:self.request.url!,statusCode:query == "offline" ? 503 : 200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            self.client?.urlProtocol(self,didLoad:data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if query == "old" { DispatchQueue.global().asyncAfter(deadline:.now()+0.3,execute:deliver) } else { deliver() }
    }
    override func stopLoading() {}
}

@MainActor enum NativeCitationAcceptance {
    static func showFixture(controller: DocumentWindow) {
        URLProtocol.registerClass(CitationAcceptanceProtocol.self)
        controller.session.chooseInsertion("citation")
    }
    static func run(controller: DocumentWindow) {
        let session = controller.session
        let original = session.buffer.source
        func check(_ condition: @autoclosure () -> Bool,_ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }
        func waitForRequest(_ count: Int) {
            let deadline = Date().addingTimeInterval(3)
            while CitationAcceptanceProtocol.requests.count < count && Date() < deadline {
                RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            }
            RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        }
        check(URLProtocol.registerClass(CitationAcceptanceProtocol.self),"Citation acceptance installs isolated Zotero responses")
        defer { session.sheet = nil; URLProtocol.unregisterClass(CitationAcceptanceProtocol.self) }
        session.chooseInsertion("citation")
        waitForRequest(1)
        let requests = CitationAcceptanceProtocol.requests
        check(requests.count == 1,"Opening Citation loads references without pressing Search")
        let url = requests[0]
        let query = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
        check(url.path == "/api/users/0/items/top" && query.first(where:{ $0.name == "q" })?.value == "" && query.first(where:{ $0.name == "limit" })?.value == "40","Initial citation load uses the bounded empty-query personal library search")
        session.sheet = nil
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        session.chooseInsertion("citation")
        waitForRequest(2)
        check(CitationAcceptanceProtocol.requests.count == 2,"Reopening Citation loads references for the new presentation")
        func findField(_ view: NSView?) -> NSTextField? {
            guard let view else { return nil }
            if let field = view as? NSTextField, field.placeholderString == "Title, author or year" { return field }
            return view.subviews.lazy.compactMap { findField($0) }.first
        }
        guard let search = findField(controller.window?.attachedSheet?.contentView) else { fatalError("Citation search field missing") }
        search.selectText(nil)
        guard let input = search.currentEditor() as? NSTextView else { fatalError("Citation search field not focused") }
        input.insertText("typed",replacementRange:input.selectedRange())
        waitForRequest(3)
        check(CitationAcceptanceProtocol.requests.last?.query?.contains("q=typed") == true,"Typing in Citation searches without Return or a Search button")
        let live = CitationSearch()
        live.search(query:"old",library:"personal",delay:0); waitForRequest(4)
        live.search(query:"new",library:"personal",delay:0); waitForRequest(5)
        RunLoop.main.run(until:Date().addingTimeInterval(0.4))
        check(live.references.first?.title == "Search result for new" && !live.finding,"Late search responses cannot replace results for the current query")
        live.search(query:"offline",library:"personal",delay:0); waitForRequest(6)
        check(!live.error.isEmpty && live.references.isEmpty && !live.finding,"Live citation search presents failures and stops its progress indicator")
        session.sheet = nil
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        session.chooseInsertion("link")
        RunLoop.main.run(until:Date().addingTimeInterval(0.3))
        check(CitationAcceptanceProtocol.requests.count == 6 && session.buffer.source == original,"Other insertion sheets do not fetch Zotero or change source")
        let writing = DocumentSession()
        let reference = ZoteroReference(key:"ABCD1234",library:"personal",title:"Citation acceptance reference",author:"Example",year:"2026",citeKey:"zotero-users-0-ABCD1234")
        var inserted = false
        ZoteroIntegration.insert([reference],session:writing,anchor:EditSelection(0,0),locator:"",form:"normal") { error in check(error == nil,"Zotero insertion succeeds against an isolated BibLaTeX response"); inserted = true }
        let insertDeadline = Date().addingTimeInterval(5)
        while !inserted && Date() < insertDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        check(inserted && writing.buffer.source.hasPrefix("#cite(<zotero-users-0-ABCD1234>)"),"New standard citations consistently use explicit cite syntax")
        let exact = writing.buffer.source
        writing.compile()
        let compileDeadline = Date().addingTimeInterval(20)
        while writing.compiling && Date() < compileDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        check(writing.pdf != nil && writing.buffer.projection.text.contains("(Example, 2026)"),"Write uses the official compiler’s formatted citation")
        check(writing.buffer.projection.text.contains("Example, J. (2026). Citation acceptance reference. Press.") && !writing.buffer.projection.text.contains("#bibliography"),"Write renders the bibliography rather than its Typst call")
        check(writing.buffer.source == exact,"Rendering citations and bibliography preserves exact canonical source")
        let renderer = NativeTextView(usingTextLayoutManager:false); renderer.session = writing
        renderer.delegate = renderer; renderer.allowsUndo = false
        let attributed = renderer.rendered()
        let bookTitle = (attributed.string as NSString).range(of:"Citation acceptance reference")
        check(bookTitle.location != NSNotFound && NSFontManager.shared.traits(of:attributed.attribute(.font,at:bookTitle.location,effectiveRange:nil) as! NSFont).contains(.italicFontMask),"Native bibliography typography retains the official style’s italic title")
        writing.editor = renderer; renderer.refresh()
        writing.buffer.setReferencePresentations([]); renderer.refresh()
        writing.searchVisible = true; writing.searchQuery = "Example"
        writing.searchController.update(revealFirst:false)
        writing.revision += 1 // Force a new result instead of reusing the cached PDF.
        writing.compile()
        let searchDeadline = Date().addingTimeInterval(20)
        while (writing.compiling || writing.searchController.searching || writing.searchController.matches.count != 2) && Date() < searchDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        check(writing.searchController.matches.count == 2,"Async reference formatting refreshes Find’s placeholder snapshot (\(writing.searchController.matches.count) matches; \(writing.error ?? "no compile error"))")
        check(writing.searchController.matches.allSatisfy { (writing.buffer.projection.text as NSString).substring(with:$0.range) == "Example" },"Refreshed Find ranges address the displayed citation and bibliography")
        let replacementSource = "Before #cite(<smith>) target target."
        writing.buffer.loadExternal(replacementSource); writing.revision += 1
        writing.buffer.setReferencePresentations([ReferencePresentation(source:ByteSpan(7,21),text:"(Smith Smith, 2020)")]); renderer.refresh()
        writing.searchQuery = "target"; writing.replaceText = "日本"; writing.replace(all:true)
        check(writing.buffer.source == "Before #cite(<smith>) 日本 日本.","Replace All after a rendered citation preserves source offsets")
        writing.undo(); renderer.refresh(); writing.searchQuery = "Smith"; writing.replaceText = "Author"; writing.replace(all:true)
        check(writing.buffer.source == "Before Author target target.","Replace All merges repeated matches within one atomic citation")
        writing.undo(); check(writing.buffer.source == replacementSource,"Atomic Replace All uses exact-source undo")
        writing.buffer.setReferencePresentations([ReferencePresentation(source:ByteSpan(7,21),text:"(Smith Smith, 2020)")]); renderer.refresh()
        writing.searchController.update(revealFirst:false)
        let findDeadline = Date().addingTimeInterval(3)
        while writing.searchController.searching && Date() < findDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        writing.find()
        check(renderer.selectedRange() == writing.buffer.projection.atomicRanges.first,"Find selects a rendered citation as one source object")
        writing.replace()
        check(writing.buffer.source == "Before Author target target.","Single Replace accepts Find’s expanded atomic citation selection")
        writing.undo(); check(writing.buffer.source == replacementSource,"Single citation replacement preserves exact-source undo")
        writing.saveWork?.cancel(); writing.recoveryQueue.sync {}
        ProjectAcceptance.run()
        BibliographyConversionAcceptance.run()
        session.sheet = nil
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
    }
}
