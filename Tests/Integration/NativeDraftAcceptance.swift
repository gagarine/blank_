import AppKit
import BlankCore
@testable import BlankNative

@MainActor enum NativeDraftAcceptance {
    static let closedSource = "// Keep café 👩🏽‍💻\n= Research\n\n#include \"child.typ\"\n#read(\"note.txt\")"
    static let childSource = "= Child\n\n日本 café"
    static let quitSource = "Quit café 👩🏽‍💻 日本語"
    static func check(_ value: @autoclosure () -> Bool,_ label: String) {
        guard value() else { fatalError("FAIL: "+label) }; print("PASS: "+label)
    }
    static func wait(_ condition: () -> Bool) {
        let limit = Date().addingTimeInterval(5)
        while !condition() && Date() < limit { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
    }
    static func waitForSnapshot(_ document: NativeDocument) {
        // Modern NSDocument saves serialize their file work separately from
        // UI activities. Wait behind the launch autosave before touching files.
        var finished = false
        document.performAsynchronousFileAccess { completion in
            MainActor.assumeIsolated {
                completion()
                finished = true
            }
        }
        let limit = Date().addingTimeInterval(15)
        while !finished && Date() < limit { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        check(finished,"Restored draft completes its native file access")
    }
    static func verify() {
        let app = AppController.shared!, sessions = app.controllers.map(\.session)
        check(sessions.count == 2,"A new app process restores drafts kept on Quit, excluding discarded, empty and saved documents")
        let closed = sessions.first { $0.entry == "Research.typ" }!
        check(closed.root == nil && closed.dirty && closed.buffers[closed.entry]?.source == closedSource && closed.buffers["child.typ"]?.source == childSource,"Relaunch restores exact Unicode source and included files as an unnamed project")
        check(closed.assets["note.txt"] == Data("Retained asset 日本".utf8) && closed.active == "child.typ" && closed.mode == .source,"Relaunch restores assets, active file and editing view")
        let range = (childSource as NSString).range(of:"日本")
        check(closed.editor?.selectedRange() == range && closed.buffer.selection.span.count == "日本".utf8.count,"Relaunch restores the native Unicode selection")
        check(sessions.contains { $0.buffer.source == quitSource && $0.root == nil },"Relaunch restores the draft containing committed IME text")
        let ids = Set(sessions.map(\.id)), start = Date(), cpu = ResourceMetrics.cpuSeconds(); _ = app.restoreDrafts()
        print(String(format:"Two small-draft journal rescans (windows already open): %.1f ms wall, %.1f ms CPU; acceptance-process RSS %.1f MiB",Date().timeIntervalSince(start)*1000,(ResourceMetrics.cpuSeconds()-cpu)*1000,ResourceMetrics.residentMiB()))
        check(Set(app.controllers.map { $0.session.id }) == ids && app.controllers.count == 2,"Repeated restoration preserves session identity without duplicate windows")
        let document = app.controllers.first { $0.session === closed }!.nativeDocument
        waitForSnapshot(document)
        check(document.fileURL != nil,"Restored draft writes its native UTF-8 snapshot (\(closed.error ?? "no error"))")
        let snapshot = document.fileURL!
        check((try? String(contentsOf:snapshot,encoding:.utf8)) == closedSource,"Restored native snapshot contains the exact entry source")
        check((try? String(contentsOf:snapshot.deletingLastPathComponent().appendingPathComponent("child.typ"),encoding:.utf8)) == childSource,"Restored native snapshot retains the included file")
        check((try? Data(contentsOf:snapshot.deletingLastPathComponent().appendingPathComponent("note.txt"))) == closed.assets["note.txt"],"Restored native snapshot retains the project asset")
        try! "Older native snapshot".write(to:snapshot,atomically:true,encoding:.utf8)
        let native = NativeDocument(); try! native.read(from:snapshot,ofType:"org.typst.source")
        check(native.session.id == closed.id && native.session.root == nil && native.session.buffers[native.session.entry]?.source == closedSource && native.isDraft,"AppKit snapshot reopening uses the canonical project and original draft identity")
        native.makeWindowControllers()
        check(app.controllers.count == 2 && closed.buffers[closed.entry]?.source == closedSource,"Native snapshot reopening reuses an existing draft without duplicate windows or source replacement")
        try! closedSource.write(to:snapshot,atomically:true,encoding:.utf8)
        check(closed.ensureRecovery(retainingDraft:false),"Explicit discard is recorded durably")
        let discardedNative = NativeDocument(); try! discardedNative.read(from:snapshot,ofType:"org.typst.source"); discardedNative.makeWindowControllers()
        check(discardedNative.windowControllers.isEmpty && app.controllers.count == 2,"A stale native snapshot cannot reopen an explicitly discarded draft")
        check(closed.ensureRecovery(),"The live test document retains its current project after snapshot suppression")
        EditorPreferences.reopensUnsavedDocuments = false
        check(UserDefaults.standard.object(forKey:"reopenUnsavedDocuments") as? Bool == false && !app.restoreDrafts(),"The persisted setting disables journal restoration")
        let suppressed = NativeDocument(); try! suppressed.read(from:snapshot,ofType:"org.typst.source"); suppressed.makeWindowControllers()
        check(suppressed.windowControllers.isEmpty && app.controllers.count == 2,"Disabling restoration also suppresses native AppKit draft reopening")
        check(NSDocumentController.shared.hasEditedDocuments && app.controllers.count == 2,"The restoration setting leaves native unsaved-document review intact")
        EditorPreferences.reopensUnsavedDocuments = true
        let directory = AppController.dataDirectory.appendingPathComponent("recovery")
        let corrupt = directory.appendingPathComponent(UUID().uuidString+".json"), data = Data("not a recovery document".utf8)
        try! data.write(to:corrupt,options:.atomic); _ = app.restoreDrafts()
        check(app.draftRestorationError != nil && (try! Data(contentsOf:corrupt)) == data && app.controllers.count == 2,"A damaged draft reports an error without overwriting its recovery or other drafts")
        try! FileManager.default.removeItem(at:corrupt)
        let blocked = DocumentSession(); blocked.buffer.loadExternal("Keep writing")
        try! FileManager.default.createDirectory(at:blocked.recoveryURL,withIntermediateDirectories:true)
        check(!blocked.ensureRecovery() && FileManager.default.fileExists(atPath:blocked.recoveryURL.path),"Failed durable retention reports failure and preserves the existing location")
        try! FileManager.default.removeItem(at:blocked.recoveryURL)
        EditorPreferences.reopensUnsavedDocuments = false
    }
    static func verifyDisabledLaunch() {
        let app = AppController.shared!
        check(!EditorPreferences.reopensUnsavedDocuments && app.controllers.count == 1 && !app.controllers[0].session.hasDraftContents,"A new process with the setting off opens a fresh empty editor")
        let records = try! FileManager.default.contentsOfDirectory(at:AppController.dataDirectory.appendingPathComponent("recovery"),includingPropertiesForKeys:nil)
        let projects = records.compactMap { try? JSONDecoder().decode(Recovery.self,from:Data(contentsOf:$0)) }
        check(projects.contains { $0.files["Research.typ"] == closedSource && $0.assets["note.txt"] == Data("Retained asset 日本".utf8) } && projects.contains { $0.files[$0.entry] == quitSource },"Opting out preserves the existing recovery projects and assets")
        UserDefaults.standard.removeObject(forKey:"reopenUnsavedDocuments")
        check(EditorPreferences.reopensUnsavedDocuments,"Draft retention defaults to enabled when no preference exists")
        let start = Date(), cpu = ResourceMetrics.cpuSeconds()
        check(app.restoreDrafts() && app.controllers.count == 3,"Enabling restoration reopens kept drafts alongside the current empty document")
        print(String(format:"Restoring two small draft projects and native windows: %.1f ms wall, %.1f ms CPU; acceptance-process RSS %.1f MiB",Date().timeIntervalSince(start)*1000,(ResourceMetrics.cpuSeconds()-cpu)*1000,ResourceMetrics.residentMiB()))
    }
}
