import AppKit
import BlankCore

@MainActor enum ProjectAcceptance {
    static func run() {
        let fm = FileManager.default, folder = fm.temporaryDirectory.appendingPathComponent("blank-project-"+UUID().uuidString)
        var sessions: [DocumentSession] = []
        let recents = NSDocumentController.shared.recentDocumentURLs
        defer {
            sessions.forEach { $0.saveWork?.cancel(); $0.diskScanWork?.cancel(); $0.watchers.forEach { $0.cancel() }; $0.recoveryQueue.sync {} }
            try? fm.removeItem(at:folder)
            NSDocumentController.shared.clearRecentDocuments(nil); recents.reversed().forEach { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
        }
        func check(_ condition: Bool,_ label: String) { precondition(condition,label); print("PASS: "+label) }
        func wait(_ operation: (@escaping (Error?) -> Void) -> Void,expectFailure: Bool = false) {
            var done = false, failure: Error?
            operation { failure = $0; done = true }
            let deadline = Date().addingTimeInterval(10)
            while !done && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
            check(done && (expectFailure ? failure != nil : failure == nil),"Project reference operation completes: \(failure?.localizedDescription ?? "success")")
        }
        func compile(_ session: DocumentSession) {
            session.compile(); let deadline = Date().addingTimeInterval(25)
            while session.compiling && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            check(session.pdf != nil && session.error == nil,"Official compiler accepts the project: \(session.error ?? "success")")
        }
        do {
            try fm.createDirectory(at:folder,withIntermediateDirectories:true)
            let project = folder.appendingPathComponent("New Project"), created = try ProjectSelection.create(at:project); sessions.append(created)
            let projectContents = try fm.contentsOfDirectory(atPath:project.path)
            check(created.entry == "main.typ" && created.buffer.source.isEmpty && projectContents == ["main.typ"],"New Project creates only a folder and empty main.typ")
            do { _ = try ProjectSelection.create(at:project); preconditionFailure("Project collision overwritten") } catch {}
            let refs = ZoteroReference(key:"ABCD1234",library:"personal",title:"Example",author:"Example",year:"2026",citeKey:"zotero-users-0-ABCD1234")
            let a = DocumentSession(), b = DocumentSession(); sessions += [a,b]
            a.buffer.loadExternal("Café 👩🏽‍💻 "); a.buffer.selection = EditSelection(a.buffer.source.utf8.count,a.buffer.source.utf8.count)
            let before = a.buffer.source, selection = a.buffer.selection
            wait { ZoteroIntegration.insert([refs],session:a,anchor:selection,locator:"p. 7 / 日本",form:"prose",completion:$0) }
            let inserted = a.buffer.source
            check(inserted.contains("```bib") && a.buffers.count == 1,"A new document embeds readable BibLaTeX and linkage in source")
            a.undo(); check(a.buffer.source == before && a.buffer.selection == selection,"Reference Undo restores exact writing and selection")
            a.undo(true); check(a.buffer.source == inserted,"Reference Redo restores embedded bibliography and citation together")
            wait { ZoteroIntegration.insert([refs],session:b,anchor:EditSelection(0,0),locator:"",form:"normal",completion:$0) }
            try a.saveCopy(to:folder.appendingPathComponent("A.typ")); try b.saveCopy(to:folder.appendingPathComponent("B.typ"))
            check(!fm.fileExists(atPath:folder.appendingPathComponent("writer-references.json").path) && !fm.fileExists(atPath:folder.appendingPathComponent("writer-zotero.bib").path),"Independent documents in one folder create no shared reference sidecars")
            let reopened = DocumentSession(); sessions.append(reopened); try reopened.open(folder.appendingPathComponent("A.typ"))
            check(reopened.buffers.count == 1 && reopened.buffer.source == inserted,"Opening a .typ selects its exact source without attaching sibling references")
            compile(reopened)
            let independentChild = folder.appendingPathComponent("independent/child.typ")
            try fm.createDirectory(at:independentChild.deletingLastPathComponent(),withIntermediateDirectories:true)
            try "Independent".write(to:independentChild,atomically:true,encoding:.utf8)
            check(ProjectSelection.root(for:independentChild) == independentChild.deletingLastPathComponent(),"Saving independent documents in a parent does not claim nested folders as a project")
            let ambiguous = folder.appendingPathComponent("ambiguous"); try fm.createDirectory(at:ambiguous,withIntermediateDirectories:true)
            try "First".write(to:ambiguous.appendingPathComponent("first.typ"),atomically:true,encoding:.utf8); try "Second".write(to:ambiguous.appendingPathComponent("second.typ"),atomically:true,encoding:.utf8)
            do { _ = try ProjectSelection.entry(in:ambiguous); preconditionFailure("Ambiguous entry guessed") } catch is ProjectEntryChoice {}
            let chosen = DocumentSession(); sessions.append(chosen); try chosen.open(ambiguous,selectedEntry:"second.typ")
            check(try ProjectSelection.entry(in:ambiguous) == "second.typ","Folder entry choice is remembered only in app state")
            let embeddedPair = DocumentSession(); sessions.append(embeddedPair)
            let oldEntry = try BibLaTeX.annotate("@book{first, title={Old}, year={2000}}",key:"ABCD1234",library:"users/0")
            let secondEntry = oldEntry.replacingOccurrences(of:"@book{first",with:"@book{second")
            let pairSource = "#bibliography(bytes(\n"+DocumentSession.embeddedBibliography(oldEntry)+"\n), full: true)\n\nMiddle prose 日本\n\n#bibliography(bytes(\n"+DocumentSession.embeddedBibliography(secondEntry)+"\n), full: true)"
            embeddedPair.buffer.loadExternal(pairSource)
            let middle = pairSource.byteOffset(utf16:(pairSource as NSString).range(of:"Middle").location)
            embeddedPair.buffer.selection = EditSelection(middle,middle)
            wait { ZoteroIntegration.refresh(embeddedPair,completion:$0) }
            let updatedMiddle = embeddedPair.buffer.source.byteOffset(utf16:(embeddedPair.buffer.source as NSString).range(of:"Middle").location)
            check(embeddedPair.buffer.selection == EditSelection(updatedMiddle,updatedMiddle),"Refreshing separated embedded bibliographies preserves a caret in unchanged intervening prose")
            embeddedPair.undo(); check(embeddedPair.buffer.source == pairSource && embeddedPair.buffer.selection == EditSelection(middle,middle),"Multi-bibliography refresh Undo restores source and selection together")
            let external = folder.appendingPathComponent("external"); try fm.createDirectory(at:external.appendingPathComponent("chapters/deep"),withIntermediateDirectories:true)
            try fm.createDirectory(at:external.appendingPathComponent("references"),withIntermediateDirectories:true)
            let main = "// Preserve custom source\n#let custom = 42\n#include \"chapters/one.typ\"\n#bibliography(\"references/works.bib\", style: \"apa\")\n"
            let chapter = "== 日本\n#include \"deep/two.typ\"\n"
            try main.write(to:external.appendingPathComponent("main.typ"),atomically:true,encoding:.utf8)
            try chapter.write(to:external.appendingPathComponent("chapters/one.typ"),atomically:true,encoding:.utf8)
            try "Deep writing ".write(to:external.appendingPathComponent("chapters/deep/two.typ"),atomically:true,encoding:.utf8)
            let bib = "% Keep Unicode café\n@string{press = \"Press\"}\n@book{manual, title={Unrelated}, year={2001}}\n"
            try bib.write(to:external.appendingPathComponent("references/works.bib"),atomically:true,encoding:.utf8)
            try "@book{unrelated, title={Elsewhere}, year={2000}}".write(to:external.appendingPathComponent("writer-zotero.bib"),atomically:true,encoding:.utf8)
            let s = DocumentSession(); sessions.append(s); try s.open(external)
            check(s.includes.count == 3 && s.buffers["writer-zotero.bib"] == nil,"External projects follow nested includes and only declared bibliographies")
            s.switchFile("chapters/deep/two.typ"); let originalChapter = s.buffer.source
            wait { ZoteroIntegration.insert([refs],session:s,anchor:EditSelection(originalChapter.utf8.count,originalChapter.utf8.count),locator:"",form:"normal",completion:$0) }
            let importedBib = s.buffers["references/works.bib"]!.source
            check(importedBib.hasPrefix(bib) && s.buffers[s.entry]!.source == main,"Zotero import appends to the declared external .bib while preserving custom source")
            s.undo(); check(s.buffer.source == originalChapter && s.buffers["references/works.bib"]!.source == bib,"Shared Undo restores chapter citation and external bibliography as one transaction")
            s.undo(true); check(s.buffers["references/works.bib"]!.source == importedBib,"Shared Redo restores external references")
            var linkedBib = importedBib.replacingOccurrences(of:"Citation acceptance reference",with:"Old title")
            linkedBib = linkedBib.replacingOccurrences(of:"x-blank-zotero-key",with:"note = {Custom preserved},\n  % Keep linked comment\n  x-blank-zotero-key")
            s.buffers["references/works.bib"]!.loadExternal(linkedBib); s.revision += 1
            let beforeRepeat = s.buffer.source
            wait { ZoteroIntegration.insert([refs],session:s,anchor:EditSelection(beforeRepeat.utf8.count,beforeRepeat.utf8.count),locator:"",form:"normal",completion:$0) }
            check(s.buffers["references/works.bib"]!.source == linkedBib,"Reusing a linked Zotero item inserts a citation without refreshing its saved data")
            s.undo(); check(s.buffer.source == beforeRepeat,"Undoing a reused citation leaves its unchanged bibliography intact")
            wait { ZoteroIntegration.refresh(s,completion:$0) }
            check(s.buffers["references/works.bib"]!.source.contains("Citation acceptance reference") && s.buffers["references/works.bib"]!.source.contains("% Keep linked comment") && s.buffers["references/works.bib"]!.source.contains("note = {Custom preserved}"),"Manual refresh updates linked fields and preserves comments and custom fields")
            check(s.buffers["references/works.bib"]!.source.hasPrefix(bib),"Manual refresh leaves unrelated entries and macros exact")
            s.undo(); check(s.buffers["references/works.bib"]!.source == linkedBib,"Manual refresh uses canonical range-based Undo")
            s.undo(true); compile(s)
            let saved = folder.appendingPathComponent("saved"); try fm.createDirectory(at:saved,withIntermediateDirectories:true)
            try s.saveCopy(to:saved.appendingPathComponent("Paper.typ"))
            check(try String(contentsOf:saved.appendingPathComponent("references/works.bib"),encoding:.utf8) == s.buffers["references/works.bib"]!.source,"Save As retains external bibliography names and data")
            let yamlSource = "yamlbook:\n  type: Book\n  title: Manual title\n  date: 2000\n"
            s.buffers[s.entry]!.loadExternal("#bibliography((\"references/works.bib\", \"references/other.yaml\"), style: \"apa\")"); s.buffers["references/other.yaml"] = DocumentBuffer(yamlSource); s.revision += 1
            let options = try s.referenceDestinations(); check(options.count == 2,"Bibliography arrays offer explicit destinations")
            wait({ ZoteroIntegration.insert([refs],session:s,anchor:EditSelection(0,0),locator:"",form:"normal",completion:$0) },expectFailure:true)
            s.switchFile(s.entry)
            wait { ZoteroIntegration.insert([refs],session:s,anchor:EditSelection(0,0),locator:"",form:"normal",destinationID:options.first { $0.file.hasSuffix("yaml") }!.id,completion:$0) }
            check(s.buffers["references/other.yaml"]!.source.hasPrefix(yamlSource) && s.buffers["references/other.yaml"]!.source.contains("x-blank-zotero-key"),"Zotero import retains the selected external Hayagriva format and unrelated entries")
            compile(s)
            wait { ZoteroIntegration.refresh(s,completion:$0) }; compile(s)
            check(s.projectAssetPath("/references/works.bib",file:"chapters/one.typ") == "references/works.bib","Absolute Typst paths resolve at the selected project root")
            let computed = folder.appendingPathComponent("computed")
            try fm.createDirectory(at:computed.appendingPathComponent("chapters"),withIntermediateDirectories:true)
            try fm.createDirectory(at:computed.appendingPathComponent("assets"),withIntermediateDirectories:true)
            try bib.write(to:computed.appendingPathComponent("assets/works.bib"),atomically:true,encoding:.utf8)
            try "Computed asset café".write(to:computed.appendingPathComponent("assets/note.txt"),atomically:true,encoding:.utf8)
            let customSource = "// exact custom source\n#let note = \"../assets/\" + \"note.txt\"\n#let works = \"../assets/\" + \"works.bib\"\n#read(note)\n#bibliography(works, style: \"apa\")\n"
            try customSource.write(to:computed.appendingPathComponent("chapters/start.typ"),atomically:true,encoding:.utf8)
            let dynamic = DocumentSession(); sessions.append(dynamic); try dynamic.open(computed,selectedEntry:"chapters/start.typ")
            wait { ZoteroIntegration.insert([refs],session:dynamic,anchor:EditSelection(0,0),locator:"",form:"normal",completion:$0) }
            check(dynamic.buffers["assets/works.bib"] != nil && dynamic.buffer.source.hasSuffix(customSource),"Computed external bibliography paths come from Typst evaluation without changing custom expressions")
            compile(dynamic)
            let exactDynamic = dynamic.buffer.source
            let dynamicCopy = folder.appendingPathComponent("computed-copy"); try fm.createDirectory(at:dynamicCopy,withIntermediateDirectories:true)
            try dynamic.saveCopy(to:dynamicCopy.appendingPathComponent("Copy.typ"))
            check(dynamic.entry == "Copy.typ" && dynamic.active == "chapters/start.typ" && dynamic.buffer.source == exactDynamic,"Nested computed-source Save As retains its filename, source and path origin")
            check(try String(contentsOf:dynamicCopy.appendingPathComponent("assets/note.txt"),encoding:.utf8) == "Computed asset café","Save As copies dependencies read through custom expressions")
            compile(dynamic)
            let location = dynamic.bibliographyLocations.first!
            let csl = "<style xmlns=\"http://purl.org/net/xbiblio/csl\" version=\"1.0\" class=\"in-text\"><info><title>Custom</title><id>https://example.org/custom</id><updated>2026-01-01T00:00:00+00:00</updated></info><citation><layout><text variable=\"title\"/></layout></citation><bibliography><layout><text variable=\"title\"/></layout></bibliography></style>"
            try csl.write(to:dynamicCopy.appendingPathComponent("assets/custom.csl"),atomically:true,encoding:.utf8)
            try dynamic.setBibliographyStyle("../assets/custom.csl",locationID:location.id)
            compile(dynamic)
            check(dynamic.buffer.projection.text.contains("Citation acceptance reference"),"Write displays citations from a custom CSL style")
            dynamic.undo(); check(dynamic.buffer.source == exactDynamic,"Changing a custom CSL style preserves exact-source Undo")
            print("PASS: ordinary Typst project and reference acceptance")
        } catch { fatalError("Project acceptance: \(error)") }
    }
}
