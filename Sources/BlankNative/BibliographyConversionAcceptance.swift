import AppKit
import BlankCore

@MainActor enum BibliographyConversionAcceptance {
    static func run() {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("blank-conversion-"+UUID().uuidString)
        var sessions: [DocumentSession] = []
        let recents = NSDocumentController.shared.recentDocumentURLs
        defer {
            sessions.forEach { $0.saveWork?.cancel(); $0.diskScanWork?.cancel(); $0.watchers.forEach { $0.cancel() }; $0.recoveryQueue.sync {} }
            try? fm.removeItem(at:root)
            NSDocumentController.shared.clearRecentDocuments(nil); recents.reversed().forEach { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
        }
        func check(_ value: Bool,_ message: String) { precondition(value,message); print("PASS: "+message) }
        func wait(_ operation: (@escaping (Error?) -> Void) -> Void,failure: Bool = false) {
            var done = false, error: Error?
            operation { error = $0; done = true }
            let deadline = Date().addingTimeInterval(15)
            while !done && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
            check(done && (failure ? error != nil : error == nil),"Bibliography conversion completes: \(error?.localizedDescription ?? "success")")
        }
        func convert(_ session: DocumentSession,_ target: BibliographyStorage,_ path: String = "",failure: Bool = false) {
            wait({ session.convertBibliography(inputID:session.bibliographyConversionInputs[0].id,to:target,path:path,completion:$0) },failure:failure)
        }
        func compile(_ session: DocumentSession) -> [String] {
            session.compile(); let deadline = Date().addingTimeInterval(20)
            while session.compiling && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            check(session.pdf != nil && session.error == nil,"Converted bibliography compiles: \(session.error ?? "success")")
            return session.buffer.projection.blocks.map { $0.text }
        }
        do {
            try fm.createDirectory(at:root.appendingPathComponent("chapters"),withIntermediateDirectories:true)
            let bib = try BibLaTeX.annotate("% Keep comments 日本\n@string{press = {Press}}\n@book{stable, title={Café}, author={Smith, Jane}, year={2026}, publisher=press, custom={Keep \\{braces\\}}}\n",key:"ABCD1234",library:"users/0")
            try bib.write(to:root.appendingPathComponent("shared.bib"),atomically:true,encoding:.utf8)
            let original = "// Custom source 👩🏽‍💻\n#cite(<stable>)\n\n#bibliography(\"/shared.bib\", style: \"apa\", full: true)\n\nAfter 日本"
            try original.write(to:root.appendingPathComponent("chapters/main.typ"),atomically:true,encoding:.utf8)
            ProjectSelection.remember(root:root,entry:"chapters/main.typ",project:true)
            let session = DocumentSession(); sessions.append(session); try session.open(root.appendingPathComponent("chapters/main.typ"))
            let caret = original.utf8.count; session.buffer.selection = EditSelection(caret,caret)
            let before = compile(session)
            convert(session,.embedded)
            let embedded = session.buffer.source
            check(embedded.contains("full: true") && embedded.contains("style: \"apa\"") && embedded.hasSuffix("After 日本") && embedded.contains(bib.trimmingCharacters(in:.newlines)),"External-to-embedded conversion retains exact BibLaTeX and surrounding custom source")
            let sharedDisk = try String(contentsOf:root.appendingPathComponent("shared.bib"),encoding:.utf8)
            check(session.buffers["shared.bib"]?.source == bib && sharedDisk == bib,"Conversion keeps a bibliography shared with other documents unchanged")
            check(session.buffer.selection.focus == embedded.utf8.count,"Conversion maps the Unicode caret outside the changed input")
            session.undo(); check(session.buffer.source == original && session.buffer.selection == EditSelection(caret,caret),"Conversion Undo restores source and caret")
            session.undo(true); check(session.buffer.source == embedded,"Conversion Redo restores embedded data")
            check(compile(session) == before,"Changing storage preserves formatted citations and bibliography")
            convert(session,.bib,"generated/references.bib")
            let external = session.buffer.source
            check(session.buffers["chapters/generated/references.bib"]!.source == bib,"Embedded-to-external conversion preserves every bibliography source character")
            session.undo(); check(session.buffer.source == embedded,"External conversion shares document Undo")
            session.undo(true); check(session.buffer.source == external && session.buffers["chapters/generated/references.bib"]!.source == bib,"External conversion Redo restores the file buffer and reference together")
            convert(session,.yaml,"/converted.yaml")
            let yaml = session.buffers["converted.yaml"]!.source
            check(try Hayagriva.linked(yaml).first?.0 == "stable","Format conversion preserves citation keys and Zotero linkage")
            check(compile(session) == before,"BibLaTeX-to-Hayagriva conversion preserves formatting")
            convert(session,.embedded)
            check(session.buffer.source == embedded,"Unchanged format round trip restores exact comments, macros and custom fields")
            convert(session,.bib,"/shared.bib",failure:true)
            check(session.buffer.source == embedded,"A destination collision does not change source")
            convert(session,.yaml,"/refreshed.yaml")
            wait { ZoteroIntegration.refresh(session,completion:$0) }
            check(session.buffers["refreshed.yaml"]!.source.contains("Citation acceptance reference"),"Manual refresh still works after format conversion")
            convert(session,.embedded)
            check(session.buffer.source.contains("Citation acceptance reference") && !session.buffer.source.contains("title={Café}"),"Conversion never restores stale data after a manual refresh")
            _ = compile(session)
            let copy = root.appendingPathComponent("copy"); try fm.createDirectory(at:copy,withIntermediateDirectories:true)
            try session.saveCopy(to:copy.appendingPathComponent("Copy.typ"))
            _ = compile(session)
            check(session.buffer.source.contains("x-blank-zotero-key"),"Save As keeps converted embedded linkage")

            let multiple = DocumentSession(); sessions.append(multiple)
            let second = "bytes(\n"+DocumentSession.embeddedBibliography("@book{other, title={Other}}")+"\n)"
            multiple.buffer.loadExternal("#bibliography((bytes(\n"+DocumentSession.embeddedBibliography(bib)+"\n), "+second+"), style: \"apa\")")
            check(multiple.bibliographyConversionInputs.count == 2,"Conversion exposes each input in a bibliography array")
            convert(multiple,.bib,"one.bib")
            check(multiple.buffer.source.contains(second),"Converting one bibliography input leaves other inputs untouched")
            let endings = "\r\n% Exact line endings 日本\r\n@book{crlf, title={Braces \\{x\\} and \\textbackslash{}}}\r\n\r\n"
            let expression = DocumentSession.conversionEmbeddedExpression(endings)
            let decoded = DocumentBuffer("#bibliography("+expression+")")
            check(bibliographyCalls(decoded.source,decoded.parsed).first?.inputs.first?.embedded == endings,"Embedded conversion preserves CRLF, Unicode and escaping exactly")
            let race = DocumentSession(); sessions.append(race)
            let raceSource = "#bibliography(bytes(\n"+DocumentSession.embeddedBibliography(bib)+"\n))"
            try raceSource.write(to:root.appendingPathComponent("race.typ"),atomically:true,encoding:.utf8)
            try race.open(root.appendingPathComponent("race.typ"))
            wait({ done in
                race.convertBibliography(inputID:race.bibliographyConversionInputs[0].id,to:.bib,path:"raced.bib",completion:done)
                try! "Foreign writing".write(to:root.appendingPathComponent("raced.bib"),atomically:true,encoding:.utf8)
            },failure:true)
            check(race.buffer.source == raceSource && race.buffers["raced.bib"] == nil,"A file created during conversion is not overwritten or attached")
            let bound = DocumentSession(); sessions.append(bound)
            let custom = "#let refs = \"shared.bib\"\n#bibliography(refs)"
            bound.buffer.loadExternal(custom); convert(bound,.embedded,failure:true)
            check(bound.buffer.source == custom,"Conversion does not rewrite a shared variable or custom expression")
            let empty = DocumentSession(); sessions.append(empty)
            check(empty.bibliographyConversionInputs.isEmpty,"An empty document has no conversion destination")
            let lossy = DocumentSession(); sessions.append(lossy)
            lossy.buffer.loadExternal("#bibliography(bytes(\n```yaml\nx:\n  type: Book\n  title: Book\n  runtime: 01:00:00\n```.text\n))")
            let unchanged = lossy.buffer.source; convert(lossy,.embedded,failure:true)
            check(lossy.buffer.source == unchanged,"An unsupported format conversion leaves the document unchanged")
            print("PASS: bibliography storage conversion acceptance")
        } catch { fatalError("Conversion acceptance: \(error)") }
    }
}
