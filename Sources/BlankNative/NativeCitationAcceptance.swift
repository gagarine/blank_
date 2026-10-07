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
        fieldsAndCommands(controller:controller)
        ProjectAcceptance.run()
        BibliographyConversionAcceptance.run()
        session.sheet = nil
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
    }
    static func fieldsAndCommands(controller: DocumentWindow) {
        let session = controller.session, editor = session.editor!
        func check(_ condition: @autoclosure () -> Bool,_ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }; print("PASS: \(label)")
        }
        func load(_ text: String) {
            session.sheet = nil; RunLoop.main.run(until:Date().addingTimeInterval(0.15))
            session.buffer.loadExternal(text); session.revision += 1; editor.refresh()
            controller.window?.makeFirstResponder(editor)
        }
        let raw = "#cite(<smith>, /* keep 👋 */ supplement: [p. 12], form: \"prose\", style: \"apa\")"
        let source = "Café 👩🏽‍💻 "+raw+" after // untouched 日本\n"
        load(source)
        let field = editor.inlineFields.first!
        check(editor.textStorage!.attribute(.backgroundColor,at:field.range.location,effectiveRange:nil) != nil && editor.textStorage!.attribute(.backgroundColor,at:0,effectiveRange:nil) == nil,"Only inline dynamic fields have the subtle native gray background")
        editor.ensureNativeLayout()
        let manager = editor.layoutManager!, container = editor.textContainer!
        let glyphs = manager.glyphRange(forCharacterRange:NSRange(location:field.range.location,length:1),actualCharacterRange:nil)
        let rect = manager.boundingRect(forGlyphRange:glyphs,in:container).offsetBy(dx:editor.textContainerOrigin.x,dy:editor.textContainerOrigin.y)
        let point = NSPoint(x:rect.midX,y:rect.midY)
        check(editor.inlineField(at:point)?.source == field.source,"Citation hit testing uses actual native glyph geometry")
        check(editor.inlineField(at:NSPoint(x:editor.bounds.maxX-4,y:point.y)) == nil,"Blank space beside a citation does not open its editor")
        let event = NSEvent.mouseEvent(with:.leftMouseDown,location:editor.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        editor.mouseDown(with:event)
        check(session.sheet == .object && session.objectOriginal == raw && session.buffer.source == source,"A single citation click opens its editor without changing source")
        let edit = CitationFieldEdit(raw)!
        check(edit.key == "smith" && edit.locator == "p. 12" && edit.form == "prose","Citation editor reads reference, locator and display controls")
        check(edit.applying(key:edit.key,locator:edit.locator,form:edit.form) == raw,"Unchanged citation controls preserve every source byte")
        let updated = edit.applying(key:"jones",locator:"p. 日本 20",form:"year")
        check(updated == raw.replacingOccurrences(of:"<smith>",with:"<jones>").replacingOccurrences(of:"[p. 12]",with:"[p. 日本 20]").replacingOccurrences(of:"\"prose\"",with:"\"year\""),"Citation edits preserve comments and custom style arguments")
        check(session.applyObjectSource(updated),"Citation Apply commits its local source range")
        check(session.buffer.source == source.replacingOccurrences(of:raw,with:updated),"Citation Apply preserves surrounding Unicode prose and comments")
        session.undo(); check(session.buffer.source == source,"Citation field edit has exact-source Undo")
        session.undo(true); check(session.buffer.source.contains(updated),"Citation field edit shares Redo with Source")
        let bare = CitationFieldEdit("#cite(label(\"key with space\"), /* keep */)")!
        let changed = bare.applying(key:"日本",locator:"20",form:"author")
        check(!ParsedSource.parse(changed).erroneous && changed.contains("/* keep */") && changed.contains("supplement: [20]") && changed.contains("form: \"author\""),"Adding citation options preserves a trailing comma and comment")
        let shorthand = CitationFieldEdit("@smith[p. 12]")!
        check(shorthand.applying(key:"smith",locator:"13",form:"prose") == "#cite(<smith>, supplement: [13], form: \"prose\")","Shorthand citation edits retain the locator when choosing a display")
        check(CitationFieldEdit("#cite(<smith>, supplement: [*Rich*])") == nil,"Rich/computed citation options retain the exact-source editor")
        session.editSourceObject(field.source,title:"Edit Citation")
        session.buffer.commit(session.buffer.source+" external",selection:session.buffer.selection)
        let stale = session.buffer.source
        check(!session.applyObjectSource(raw) && session.buffer.source == stale,"A stale inline editor cannot overwrite intervening changes")
        session.sheet = nil; session.error = nil

        let bib = "@book{smith, title={Used book}, author={Example}, year={2020}}\n@book{unused, title={Unused book}, year={2021}}"
        let citationDocument = "#cite(<smith>)\n\n#bibliography(bytes(\n"+DocumentSession.embeddedBibliography(bib)+"\n))"
        load(citationDocument)
        let choices = session.citationChoices()
        check(choices.cited.map(\.citeKey) == ["smith"] && choices.cited[0].title == "Used book","Citation choices contain actually cited bibliography entries, excluding unused entries")
        let live = ZoteroReference(key:"ABCD1234",library:"users/0",title:"Another result",author:"Example",year:"2026",citeKey:"zotero-users-0-ABCD1234")
        check(choices.results([live],query:"").map(\.citeKey) == ["smith",live.citeKey] && choices.results([],query:"used").first?.citeKey == "smith","Cited references stay first and searchable when Zotero has no results")
        check(choices.results([],query:"not present").isEmpty,"Search also filters already cited references")
        let custom = CitationChoices(cited:[ZoteroReference(key:live.key,library:live.library,title:"Saved",author:"Example",year:"2026",citeKey:"custom-key")])
        check(custom.results([live],query:"").map(\.citeKey) == ["custom-key"],"Live Zotero matches reuse custom citation keys without duplicate rows")
        let keySource = "// @fake\n`@fake` #cite(label(\"日本 key\")) @smith[p. 12] <uncited>"
        check(literalCitationKeys(keySource,ParsedSource.parse(keySource)) == ["日本 key","smith"],"Parser-backed cited keys exclude comments, code and unattached labels")
        let requests = CitationAcceptanceProtocol.requests.count
        session.insertionAnchor = EditSelection(0,0)
        var done = false
        ZoteroIntegration.insert([choices.cited[0]],session:session,anchor:session.insertionAnchor,locator:"42",form:"normal") { error in check(error == nil,"Saved reference insertion succeeds offline"); done = true }
        check(done && CitationAcceptanceProtocol.requests.count == requests && session.buffer.source.hasPrefix("#cite(<smith>, supplement: [42])"),"Reusing a cited reference keeps its key and performs no Zotero request")
        session.undo(); check(session.buffer.source == citationDocument,"Reusing a citation preserves bibliography and exact-source Undo")
        load("#table(columns: 2, [Before #cite(<smith>) after], [Keep])")
        let cellField = editor.inlineFields.first!
        check(editor.textStorage!.attribute(.backgroundColor,at:cellField.range.location,effectiveRange:nil) != nil,"Citation fields have the same gray background inside native table cells")
        session.editSourceObject(cellField.source,title:"Edit Citation")
        check(session.objectOriginal == "#cite(<smith>)" && session.applyObjectSource("#cite(<jones>)"),"Table citation editor maps to canonical cell source")
        check(session.buffer.source == "#table(columns: 2, [Before #cite(<jones>) after], [Keep])","Table citation edit preserves table dimensions and surrounding cell text")
        session.undo(); check(session.buffer.source.contains("<smith>"),"Table citation edit has exact-source Undo")
        session.switchMode(.source); editor.refresh()
        check(editor.inlineFields.isEmpty && editor.rendered().attribute(.backgroundColor,at:0,effectiveRange:nil) == nil,"Source retains exact text without dynamic field decorations")
        session.switchMode(.write); load("")
        let commands = NSApp.mainMenu!.items.flatMap { $0.submenu?.items ?? [] }.compactMap { $0.representedObject as? SlashCommand }
        check(Set(commands.map(\.id)) == Set(SlashCommand.all.map(\.id)),"Every slash command appears in the native Insert or Format menu")
        let heading = NSApp.mainMenu!.items.first { $0.title == "Format" }!.submenu!.items.first { ($0.representedObject as? SlashCommand)?.id == "heading2" }!
        check(NSApp.sendAction(heading.action!,to:heading.target,from:heading),"Native Format menu dispatches its paragraph command")
        check(session.buffer.source == "== ","Format Heading 2 uses the canonical block transaction")
        session.undo(); check(session.buffer.source.isEmpty,"Menu block formatting shares source Undo")
        for character in "/code" { editor.insertText(String(character),replacementRange:editor.selectedRange()) }
        check(editor.slashMatches.first?.kind == "code","Slash search exposes Code")
        editor.slashIndex = 0; editor.chooseSlash()
        check(session.sheet == nil && session.buffer.source == "\n\n#{\n  \n}\n\n","Slash Code immediately inserts an empty Typst source block")
        check(session.buffer.projection.blocks.contains { $0.kind == "source" } && editor.codeButtons.values.contains { !$0.isHidden },"Inserted Code uses the existing collapsible source-block presentation")
        check(session.buffer.selection.focus == 7 && controller.window?.firstResponder === editor,"Code insertion focuses its interior ready to type")
        editor.insertText("let café = \"日本 👋\"",replacementRange:editor.selectedRange())
        check(session.buffer.source.contains("#{\n  let café = \"日本 👋\"\n}") && !session.buffer.parsed.erroneous,"Inserted Code accepts Unicode Typst source directly")
        session.undo(); check(session.buffer.source == "\n\n#{\n  \n}\n\n","Typing inside Code has exact-source Undo")
        session.undo(); check(session.buffer.source.isEmpty,"Code block insertion shares source Undo")
        load("")
        session.switchMode(.preview)
        check(SlashCommand.all.allSatisfy { !session.canPerformBlockCommand($0) },"Insert and block Format commands are disabled in Preview")
        session.switchMode(.write); load("")
    }
}
