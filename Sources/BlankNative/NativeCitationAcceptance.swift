import AppKit
import Foundation
import BlankCore

// Intercept only Zotero's loopback endpoint; acceptance never needs a live library.
final class CitationAcceptanceProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var urls: [URL] = []
    static var requests: [URL] { lock.lock(); defer { lock.unlock() }; return urls.filter { !$0.path.hasSuffix("/groups") } }
    static var groupRequests: [URL] { lock.lock(); defer { lock.unlock() }; return urls.filter { $0.path.hasSuffix("/groups") } }
    static var groupFixture = "normal"
    static var itemFixtureOffline = false
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost" && request.url?.port == 23119
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.urls.append(request.url!); Self.lock.unlock()
        let query = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{ $0.name == "q" })?.value ?? ""
        let title = query.isEmpty ? "Citation acceptance reference" : "Search result for " + query
        let groups = request.url!.path.hasSuffix("/groups")
        if groups {
            let start = Int(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{ $0.name == "start" })?.value ?? "0") ?? 0
            let fixture = Self.groupFixture
            let rows: [[String:Any]] = fixture == "empty" ? [] : fixture == "paged" ? (start..<(start == 0 ? 100 : 102)).map { ["id":$0+100,"data":["name":"Group \($0)"]] } : [["id":123,"data":["name":"Research café 日本"]],["id":456,"data":["name":"Second library"]]]
            let data = fixture == "malformed" ? Data("{}".utf8) : try! JSONSerialization.data(withJSONObject:rows)
            let deliver = {
                self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:self.request.url!,statusCode:fixture == "offline" ? 503 : 200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
                self.client?.urlProtocol(self,didLoad:data); self.client?.urlProtocolDidFinishLoading(self)
            }
            if fixture == "late" { DispatchQueue.global().asyncAfter(deadline:.now()+0.3,execute:deliver) } else { deliver() }
            return
        }
        let bibliography = request.url?.query?.contains("format=biblatex") == true
        let itemData = try! JSONSerialization.data(withJSONObject:query == "none" ? [] : [["key":"ABCD1234","data":["itemType":"book","title":title,"creators":[["lastName":"Example"]],"date":"2026"]],["key":"EFGH5678","data":["itemType":"book","title":"Second reference","creators":[["lastName":"Other"]],"date":"2025"]]])
        let data = bibliography ? Data("@book{original, author={Example, Jane}, title={Citation acceptance reference}, year={2026}, publisher={Press}}".utf8) : itemData
        let deliver = {
            self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:self.request.url!,statusCode:query == "offline" || Self.itemFixtureOffline ? 503 : 200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
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
        if CommandLine.arguments.contains("--citation-fixture-offline") { CitationAcceptanceProtocol.groupFixture = "offline"; CitationAcceptanceProtocol.itemFixtureOffline = true }
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
        libraryAndKeyboard(controller:controller)
        fieldsAndCommands(controller:controller)
        ProjectAcceptance.run()
        BibliographyConversionAcceptance.run()
        session.sheet = nil
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
    }
    static func libraryAndKeyboard(controller: DocumentWindow) {
        func check(_ condition: @autoclosure () -> Bool,_ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }; print("PASS: \(label)")
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        }
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
        let session = controller.session
        session.sheet = nil; RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        session.buffer.loadExternal("Before café 日本"); session.revision += 1; session.editor?.refresh()
        session.editor?.setSelectedRange(NSRange(location:session.editor!.string.utf16.count,length:0)); session.editor?.captureSelection()
        let original = session.buffer.source
        session.chooseInsertion("citation")
        func find<T: NSView>(_ view: NSView?,_ type: T.Type) -> T? {
            guard let view else { return nil }; if let result = view as? T { return result }
            return view.subviews.lazy.compactMap { find($0,type) }.first
        }
        wait { find(controller.window?.attachedSheet?.contentView,CitationResultTable.self)?.references.count == 2 }
        guard let table = find(controller.window?.attachedSheet?.contentView,CitationResultTable.self),
              let field = find(controller.window?.attachedSheet?.contentView,CitationQueryTextField.self) else { fatalError("Native citation controls missing") }
        func key(_ code: UInt16,_ characters: String,_ responder: NSResponder) {
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:table.window!.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
            responder.keyDown(with:event); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        }
        check(field.currentEditor() is NSTextView,"Opening Citation automatically focuses its native search field")
        guard let input = field.currentEditor() as? NSTextView else { fatalError("Native citation query is not focused") }
        input.setMarkedText("日本",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:0,length:0))
        let marked = input.string
        field.syncText("background refresh")
        check(input.hasMarkedText() && input.string == marked && !field.control(field,textView:input,doCommandBy:#selector(NSResponder.insertNewline(_:))),"Background query refresh and Return leave native marked-text composition in control")
        input.unmarkText(); input.insertText("",replacementRange:NSRange(location:0,length:input.string.utf16.count))
        RunLoop.main.run(until:Date().addingTimeInterval(0.3))
        key(48,"\t",input)
        check(table.window?.firstResponder is CitationLibraryPopUp,"Native Tab reaches library selection without changing system keyboard preferences")
        field.selectText(nil)
        key(36,"\r",input)
        check(session.sheet == .insertion && session.buffer.source == original && table.selectedRow == -1,"Return with no checked or highlighted citation does not insert the first result")
        key(125,"\u{F701}",input)
        check(table.window?.firstResponder === table && table.selectedRow == 0 && table.chosen.isEmpty,"Native Down transfers search focus to a highlighted unchecked result")
        key(49," ",table)
        check(table.chosen == [table.references[0].id],"Native Space checks the highlighted citation")
        key(125,"\u{F701}",table)
        check(table.selectedRow == 1 && table.chosen == [table.references[0].id],"Native arrow navigation preserves checked references")
        key(49," ",table); key(126,"\u{F700}",table)
        check(table.chosen.count == 2 && table.selectedRow == 0,"Multiple citation checks survive backward native navigation")
        field.selectText(nil)
        guard let queryInput = field.currentEditor() as? NSTextView else { fatalError("Query focus missing") }
        queryInput.insertText("none",replacementRange:NSRange(location:0,length:queryInput.string.utf16.count))
        wait { table.references.isEmpty }
        check(table.selectedRow == -1 && table.chosen.count == 2,"Empty search clears stale row focus while preserving checked references")
        queryInput.insertText("",replacementRange:NSRange(location:0,length:queryInput.string.utf16.count))
        wait { table.references.count == 2 }
        check(table.selectedRow == -1 && table.chosen.count == 2,"Refreshed results retain checked identities without a stale row highlight")
        key(36,"\r",queryInput); wait { session.sheet == nil }
        check(session.sheet == nil && session.buffer.source.contains("zotero-users-0-ABCD1234") && session.buffer.source.contains("zotero-users-0-EFGH5678"),"Native Return inserts all checked references through canonical source")
        let inserted = session.buffer.source
        session.undo(); check(session.buffer.source == original,"Keyboard citation insertion has exact Unicode source Undo")
        session.undo(true); check(session.buffer.source == inserted,"Keyboard citation insertion shares canonical Redo")
        session.chooseInsertion("citation"); wait { find(controller.window?.attachedSheet?.contentView,CitationResultTable.self) != nil }
        guard let second = find(controller.window?.attachedSheet?.contentView,CitationResultTable.self) else { fatalError("Reopened citation table missing") }
        func libraryPicker(_ view: NSView?) -> NSPopUpButton? {
            guard let view else { return nil }
            if let picker = view as? NSPopUpButton, picker.itemTitles.contains("Research café 日本") { return picker }
            return view.subviews.lazy.compactMap { libraryPicker($0) }.first
        }
        wait { libraryPicker(controller.window?.attachedSheet?.contentView) != nil }
        guard let picker = libraryPicker(controller.window?.attachedSheet?.contentView) else { fatalError("Native library picker missing") }
        second.moveHighlight(1); key(49," ",second)
        check(!second.chosen.isEmpty,"Library-change fixture has a checked reference to clear")
        picker.selectItem(withTitle:"Research café 日本"); picker.sendAction(picker.action,to:picker.target)
        wait { CitationAcceptanceProtocol.requests.last?.path == "/api/groups/123/items/top" }
        check(CitationAcceptanceProtocol.requests.last?.path == "/api/groups/123/items/top" && second.chosen.isEmpty,"Selecting a discovered native library searches its group and clears prior choices")
        wait { second.references.contains { $0.library == "groups/123" } }
        guard let groupRow = second.references.firstIndex(where:{ $0.library == "groups/123" }) else { fatalError("Group reference missing") }
        second.selectRowIndexes(IndexSet(integer:groupRow),byExtendingSelection:false); key(49," ",second)
        check(!second.chosen.isEmpty,"Removed-group fixture has a selected library and checked reference")
        func reloadButton(_ view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let button = view as? NSButton, button.accessibilityLabel() == "Reload Zotero libraries" { return button }
            return view.subviews.lazy.compactMap { reloadButton($0) }.first
        }
        guard let reload = reloadButton(controller.window?.attachedSheet?.contentView) else { fatalError("Library reload button missing") }
        CitationAcceptanceProtocol.groupFixture = "empty"; reload.performClick(nil)
        wait { picker.titleOfSelectedItem == "Personal library" && CitationAcceptanceProtocol.requests.last?.path == "/api/users/0/items/top" }
        check(picker.itemTitles == ["Personal library"] && picker.titleOfSelectedItem == "Personal library" && second.chosen.isEmpty && second.selectedRow == -1,"Reloading a removed group resets Personal, clears stale choices and searches the current library")
        CitationAcceptanceProtocol.groupFixture = "normal"
        key(53,"\u{1b}",second)
        check(session.sheet == nil && session.buffer.source == inserted,"Native Escape dismisses citation selection without source edits")
        // No checked state: Return can explicitly insert the highlighted row.
        session.chooseInsertion("citation"); wait { find(controller.window?.attachedSheet?.contentView,CitationResultTable.self)?.references.count ?? 0 > 0 }
        guard let third = find(controller.window?.attachedSheet?.contentView,CitationResultTable.self) else { fatalError("Citation table missing") }
        third.moveHighlight(1); let target = third.highlightedReference!.citeKey
        key(36,"\r",third); wait { session.sheet == nil }
        check(session.sheet == nil && session.buffer.source.contains(target),"Return inserts a deliberately highlighted citation without requiring a mouse checkbox")
        session.undo(); check(session.buffer.source == inserted,"Highlighted citation reuse has exact source Undo")
        CitationAcceptanceProtocol.groupFixture = "offline"; CitationAcceptanceProtocol.itemFixtureOffline = true
        let requestsBeforeOfflineOpen = CitationAcceptanceProtocol.requests.count
        session.chooseInsertion("citation")
        wait { CitationAcceptanceProtocol.requests.count > requestsBeforeOfflineOpen && find(controller.window?.attachedSheet?.contentView,CitationResultTable.self)?.references.count == 2 }
        guard let offline = find(controller.window?.attachedSheet?.contentView,CitationResultTable.self) else { fatalError("Offline citation table missing") }
        check(offline.references.allSatisfy { offline.cited.contains($0.citeKey) },"Remote discovery/search failure leaves already-cited choices visible in the native picker")
        let beforeReuse = CitationAcceptanceProtocol.requests.count
        offline.moveHighlight(1); key(36,"\r",offline); wait { session.sheet == nil }
        check(session.sheet == nil && CitationAcceptanceProtocol.requests.count == beforeReuse,"Native offline citation reuse inserts without another Zotero request")
        session.undo(); check(session.buffer.source == inserted,"Offline keyboard reuse preserves exact-source Undo")
        CitationAcceptanceProtocol.groupFixture = "normal"; CitationAcceptanceProtocol.itemFixtureOffline = false
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
        check(editor.slashMatches.contains { $0.kind == "code" } && editor.slashMatches.contains { $0.kind == "raw" },"Slash search exposes executable Code and displayed Code block")
        editor.slashIndex = editor.slashMatches.firstIndex { $0.kind == "code" }!; editor.chooseSlash()
        check(session.sheet == nil && session.buffer.source == "\n\n#{\n  \n}\n\n","Slash Code immediately inserts an empty Typst source block")
        check(session.buffer.projection.blocks.contains { $0.kind == "source" } && editor.codeButtons.values.contains { !$0.isHidden },"Inserted Code uses the existing collapsible source-block presentation")
        check(session.buffer.selection.focus == 7 && controller.window?.firstResponder === editor,"Code insertion focuses its interior ready to type")
        editor.insertText("let café = \"日本 👋\"",replacementRange:editor.selectedRange())
        check(session.buffer.source.contains("#{\n  let café = \"日本 👋\"\n}") && !session.buffer.parsed.erroneous,"Inserted Code accepts Unicode Typst source directly")
        session.undo(); check(session.buffer.source == "\n\n#{\n  \n}\n\n","Typing inside Code has exact-source Undo")
        session.undo(); check(session.buffer.source.isEmpty,"Code block insertion shares source Undo")
        load("")
        for character in "/code" { editor.insertText(String(character),replacementRange:editor.selectedRange()) }
        editor.slashIndex = editor.slashMatches.firstIndex { $0.kind == "raw" }!; editor.chooseSlash()
        check(session.buffer.projection.blocks.first?.kind == "raw" && !session.buffer.parsed.erroneous,"Slash Code block creates a displayed literal code example")
        editor.insertText("#let literal = 42",replacementRange:editor.selectedRange())
        check(session.buffer.projection.text == "#let literal = 42" && session.buffer.source.hasPrefix("```"),"Slash Code block types literal code with protected fences")
        let displayedCode = session.buffer.source
        session.undo(); session.undo(); check(session.buffer.source == "/code","Displayed code conversion Undo restores the typed slash command")
        session.undo(); check(session.buffer.source.isEmpty,"Slash query typing shares source Undo")
        session.undo(true); session.undo(true); session.undo(true); check(session.buffer.source == displayedCode,"Displayed code conversion and typing retain exact-source Redo")
        load("")
        session.switchMode(.preview)
        check(SlashCommand.all.allSatisfy { !session.canPerformBlockCommand($0) },"Insert and block Format commands are disabled in Preview")
        session.switchMode(.write); load("")
    }
}
