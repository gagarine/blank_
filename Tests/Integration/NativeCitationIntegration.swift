import AppKit
import BlankCore
@testable import BlankNative

@MainActor enum NativeCitationIntegration {
    static func run() {
        func check(_ condition: @autoclosure () -> Bool,_ label: String) { guard condition() else { fatalError("FAIL: "+label) }; print("PASS: "+label) }
        func waitForRequest(_ count: Int) {
            let deadline = Date().addingTimeInterval(3)
            while CitationAcceptanceProtocol.requests.count < count && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        }
        guard URLProtocol.registerClass(CitationAcceptanceProtocol.self) else { fatalError("Cannot isolate citation API") }
        defer { URLProtocol.unregisterClass(CitationAcceptanceProtocol.self) }
        let requestBase = CitationAcceptanceProtocol.requests.count
        let live = CitationSearch()
        live.search(query:"old",library:"personal",delay:0); waitForRequest(requestBase+1)
        live.search(query:"new",library:"personal",delay:0); waitForRequest(requestBase+2)
        RunLoop.main.run(until:Date().addingTimeInterval(0.4))
        check(live.references.first?.title == "Search result for new" && !live.finding,"Late search responses cannot replace results for the current query")
        live.search(query:"offline",library:"personal",delay:0); waitForRequest(requestBase+3)
        check(!live.error.isEmpty && live.references.isEmpty && !live.finding,"Live citation search presents failures and stops its progress indicator")
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
        let libraries = CitationLibraries()
        CitationAcceptanceProtocol.groupFixture = "paged"; libraries.load(); wait { !libraries.loading }
        check(libraries.error.isEmpty && libraries.libraries.count == 103 && CitationAcceptanceProtocol.groupRequests.last?.query?.contains("start=100") == true,"Group discovery pages all locally available libraries and retains Personal")
        let previous = libraries.libraries.map(\.id)
        CitationAcceptanceProtocol.groupFixture = "offline"; libraries.load(); wait { !libraries.loading }
        check(!libraries.error.isEmpty && libraries.libraries.map(\.id) == previous,"Failed group discovery preserves the last usable library list")
        CitationAcceptanceProtocol.groupFixture = "malformed"; libraries.load(); wait { !libraries.loading }
        check(!libraries.error.isEmpty && libraries.libraries.map(\.id) == previous,"Malformed group data is reported without erasing libraries")
        CitationAcceptanceProtocol.groupFixture = "late"; libraries.load(); libraries.cancel()
        RunLoop.main.run(until:Date().addingTimeInterval(0.5))
        check(libraries.libraries.map(\.id) == previous && !libraries.loading,"Dismissal rejects late group discovery results")
        CitationAcceptanceProtocol.groupFixture = "normal"; libraries.load(); wait { !libraries.loading }
        check(libraries.error.isEmpty && libraries.libraries.map(\.id) == ["personal","groups/123","groups/456"],"Library retry discovers named Unicode groups")
    }
}
