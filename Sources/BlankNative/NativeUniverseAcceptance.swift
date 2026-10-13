import AppKit
import PDFKit
import BlankCore

@MainActor enum NativeUniverseAcceptance {
    static func run(original: DocumentWindow) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("blank-universe-acceptance-"+UUID().uuidString)
        let cache = ProcessInfo.processInfo.environment["BLANK_PACKAGE_CACHE"].map { URL(fileURLWithPath:$0) } ?? AppController.dataDirectory.appendingPathComponent("cache/typst/packages")
        let package = cache.appendingPathComponent("preview/blank-universe-native-fixture/1.0.0")
        let index = cache.appendingPathComponent(".universe-index.json")
        let savedIndex = try? Data(contentsOf:index)
        var sessions: [DocumentSession] = []
        var gallery: TemplateGalleryWindow?
        func check(_ condition: Bool,_ label: String) { if !condition { fatalError("Universe: "+label) }; print("PASS: "+label) }
        func wait(_ label: String,_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(30)
            while !condition() && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            check(condition(),label)
        }
        func write(_ path: String,_ data: Data) throws {
            let target = package.appendingPathComponent(path)
            try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true); try data.write(to:target)
        }
        defer {
            gallery?.window?.close()
            for session in sessions { session.saveWork?.cancel(); session.watchers.forEach { $0.cancel() }; session.recoveryQueue.sync {} }
            try? fm.removeItem(at:folder); try? fm.removeItem(at:package.deletingLastPathComponent())
            if let savedIndex { try? savedIndex.write(to:index,options:.atomic) } else { try? fm.removeItem(at:index) }
            original.window?.makeKeyAndOrderFront(nil)
        }
        do {
            let source = "// Preserve Café 日本 👩🏽‍💻\n#import \"@preview/blank-universe-native-fixture:1.0.0\": message\n= Starter\n#message\n#include \"../body.typ\"\n#image(\"../assets/icon.svg\")\n"
            try write("typst.toml",Data("[package]\nname = \"blank-universe-native-fixture\"\nversion = \"1.0.0\"\nentrypoint = \"lib.typ\"\n[template]\npath = \"starter\"\nentrypoint = \"chapters/main.typ\"\n".utf8))
            try write("lib.typ",Data("#let message = [Cached pinned package]".utf8))
            try write("README.md",Data("Fixture documentation".utf8))
            try write("starter/chapters/main.typ",Data(source.utf8))
            try write("starter/body.typ",Data("== Body\nExact source".utf8))
            try write("starter/unused.typ",Data("// Not yet included\n= Later".utf8))
            let icon = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><rect width=\"20\" height=\"20\" fill=\"blue\"/></svg>".utf8)
            try write("starter/assets/icon.svg",icon)
            let unused = Data([0,255,7]); try write("starter/assets/unused.bin",unused)
            let record: [String:Any] = ["name":"blank-universe-native-fixture","version":"1.0.0","description":"Unicode Café template","authors":["Fixture author"],"categories":["book"],"keywords":["acceptance"],"template":["path":"starter","entrypoint":"chapters/main.typ"]]
            try JSONSerialization.data(withJSONObject:[record]).write(to:index,options:.atomic)
            let library = UniverseLibrary()
            library.load()
            wait("Offline cached Universe catalogue loads without changing the document") { !library.loading }
            check(library.loadError == nil && library.templates.count == 1 && original.session.buffer.source.isEmpty,"Catalogue browsing leaves New Document empty")
            let item = library.templates[0]
            check(item.version == "1.0.0" && item.matches("café") && item.matches("book") && item.matches("fixture author") && !item.matches("unmatched"),"Search covers name, description, author and category")
            let locals = try TemplateLibrary(root:folder.appendingPathComponent("library"))
            let chooser = TemplateGalleryWindow(library:locals); gallery = chooser
            chooser.query = "thesis"
            check(chooser.visibleLocalTemplates.count == 1 && chooser.visibleLocalTemplates[0].name == "Thesis","Local templates use the shared search convention")
            chooser.source = .universe
            check(!chooser.validateToolbarItem(NSToolbarItem(itemIdentifier:.init("edit"))) && !chooser.validateMenuItem(NSMenuItem(title:"Duplicate",action:#selector(TemplateGalleryWindow.duplicate(_:)),keyEquivalent:"")),"Universe does not expose local editing or deletion actions")
            chooser.universe.cancelBrowsing()
            library.selection = item.id
            wait("Selected Universe starter compiles its cached pinned import and assets") { !library.previewing }
            check(library.previewError == nil && library.pdf(item).flatMap({ PDFDocument(data:$0) })?.pageCount == 1 && library.project(item)?.documentation == "Fixture documentation","Details provide a real PDF, version and documentation")
            var first: DocumentSession?
            library.create { first = $0 }
            wait("Create Document installs its prepared draft asynchronously") { first != nil }
            let draft = first!; sessions.append(draft)
            check(draft.root == nil && draft.dirty && draft.entry == "chapters/main.typ" && draft.active == draft.entry && draft.buffer.source == source && !draft.buffer.canUndo,"Universe creates an exact independent draft at the declared nested entry")
            check(draft.buffers["unused.typ"]?.source == "// Not yet included\n= Later" && draft.assets["assets/unused.bin"] == unused && draft.assets["assets/icon.svg"] == icon,"All starter sources and binary assets survive, including unused files")
            var second: DocumentSession?
            library.create { second = $0 }; wait("The same version can create another draft") { second != nil }
            sessions.append(second!)
            draft.buffer.editSource(NSRange(location:draft.buffer.source.utf16.count,length:0),text:"\nLocal edit")
            check(second!.buffer.source == source && draft.buffers["body.typ"] !== second!.buffers["body.typ"],"Copies have independent source and history")
            var cancelledCreated = false
            library.create { _ in cancelledCreated = true }; library.cancelCreation()
            RunLoop.main.run(until:Date().addingTimeInterval(0.15))
            check(!cancelledCreated && !library.creating,"Cancelling creation suppresses its queued completion")
            library.load(refresh:true); library.cancelBrowsing()
            check(!library.loading && !library.previewing,"Cancellation ends catalogue and preview activity immediately")
            let added = try locals.add(second!,name:"Universe local")
            let localCopy = try locals.newDocument(from:added); sessions.append(localCopy)
            check(localCopy.assets["assets/unused.bin"] == unused && localCopy.buffers["unused.typ"]?.source == "// Not yet included\n= Later","Save as Template retains the complete Universe project for later local copies")
            let brokenPackage = package.deletingLastPathComponent().appendingPathComponent("2.0.0")
            try fm.createDirectory(at:brokenPackage.appendingPathComponent("starter"),withIntermediateDirectories:true)
            try Data("[package]\nname = \"blank-universe-native-fixture\"\nversion = \"2.0.0\"\nentrypoint = \"lib.typ\"\n[template]\npath = \"starter\"\nentrypoint = \"main.typ\"\n".utf8).write(to:brokenPackage.appendingPathComponent("typst.toml"))
            try Data("#thisDoesNotExist()".utf8).write(to:brokenPackage.appendingPathComponent("starter/main.typ"))
            var brokenRecord = record; brokenRecord["version"] = "2.0.0"
            try JSONSerialization.data(withJSONObject:[brokenRecord]).write(to:index,options:.atomic)
            let broken = UniverseLibrary(); broken.load()
            wait("A failing starter can still be discovered") { !broken.loading }
            broken.selection = broken.templates.first?.id
            wait("Preview compilation failure returns control to the gallery") { !broken.previewing }
            check(broken.previewError != nil,"A failed preview reports its compilation diagnostics")
            var editable: DocumentSession?
            broken.create { editable = $0 }; wait("A failed preview remains available for creation") { editable != nil }
            sessions.append(editable!)
            check(editable!.buffer.source == "#thisDoesNotExist()" && editable!.root == nil,"Preview failure preserves the editable starter source")
            try fm.removeItem(at:package)
            let destination = folder.appendingPathComponent("output/Document.typ")
            try second!.saveCopy(to:destination)
            check(try Data(contentsOf:destination.deletingLastPathComponent().appendingPathComponent("assets/unused.bin")) == unused,"Created projects save after the downloaded template is removed")
            let invalidReplies: [[String:Any]] = [
                ["entry":"../escape.typ","files":["../escape.typ":Data().base64EncodedString()]],
                ["entry":"main.typ","files":["main.typ":Data([255]).base64EncodedString()]],
                ["entry":"missing.typ","files":["other.typ":Data().base64EncodedString()]]
            ]
            for reply in invalidReplies {
                var rejected = false; do { _ = try UniverseProject(reply:reply) } catch { rejected = true }
                check(rejected,"Invalid downloaded projects cannot install partial drafts")
            }
            print("PASS: native Universe template acceptance")
        } catch { fatalError("Native Universe acceptance: \(error)") }
    }
}
