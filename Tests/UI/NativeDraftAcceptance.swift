@testable import BlankIntegrationTests
import AppKit
import BlankCore
@testable import BlankNative

@MainActor enum NativeDraftUIAcceptance {
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
    static func buttons(_ view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
    }
    static func respondToClose(_ window: NSWindow?,titles: [String]) {
        wait { window?.attachedSheet != nil }
        if let panel = window?.attachedSheet as? NSSavePanel {
            if titles.contains("Cancel") { panel.cancel(nil) }
            return
        }
        let choices = buttons(window?.attachedSheet?.contentView)
        guard let button = choices.first(where:{ titles.contains($0.title) }) else { fatalError("Missing close choice: \(choices.map(\.title))") }
        button.performClick(nil)
    }
    static func prepare() {
        EditorPreferences.reopensUnsavedDocuments = true
        let app = AppController.shared!, first = app.controllers.first!, session = first.session
        session.entry = "Research.typ"; session.active = "child.typ"
        session.buffers = [session.entry:DocumentBuffer(closedSource),"child.typ":DocumentBuffer(childSource)]
        session.assets = ["note.txt":Data("Retained asset 日本".utf8)]; session.mode = .source
        session.changed(); session.saveWork?.cancel()
        first.window?.makeKeyAndOrderFront(nil); session.editor?.refresh()
        let range = (childSource as NSString).range(of:"日本")
        session.editor?.setSelectedRange(range); session.editor?.captureSelection()
        let selection = session.buffer.selection, revision = session.buffer.revision
        first.window?.performClose(nil)
        respondToClose(first.window,titles:["Cancel"])
        wait { first.window?.attachedSheet == nil }
        check(app.controllers.contains { $0 === first },"Close still asks, and Cancel keeps the unsaved document open")
        check(session.buffer.source == childSource && session.buffer.selection == selection && session.buffer.revision == revision,"Cancel preserves exact source, selection and model history")
        let discarded = DocumentSession(); discarded.buffer.loadExternal("Explicitly discarded café"); app.show(discarded); discarded.changed(); discarded.saveWork?.cancel()
        let discardedWindow = app.controllers.last!
        discardedWindow.window?.performClose(nil)
        respondToClose(discardedWindow.window,titles:["Cancel"])
        wait { discardedWindow.window?.attachedSheet == nil }
        // NSWindow.close discards without review, just as the native panel's
        // Don't Save choice does. The remote panel's buttons are checked in UI.
        discardedWindow.window?.close()
        wait { !app.controllers.contains { $0 === discardedWindow } }
        let record = try! JSONDecoder().decode(Recovery.self,from:Data(contentsOf:discarded.recoveryURL))
        check(!app.controllers.contains { $0 === discardedWindow } && record.retainedDraft == false && record.files[discarded.entry] == "Explicitly discarded café","Discard on Close excludes the draft from reopening and keeps manual recovery")
        let empty = DocumentSession(); app.show(empty)
        let emptyWindow = app.controllers.last!
        emptyWindow.window?.performClose(nil); wait { !app.controllers.contains { $0 === emptyWindow } }
        check(!app.controllers.contains { $0 === emptyWindow },"An untouched empty document closes normally")
        let saved = DocumentSession(); saved.buffer.loadExternal("Saved writing"); app.show(saved)
        let destination = AppController.dataDirectory.appendingPathComponent("chosen")
        try! FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        try! saved.saveCopy(to:destination.appendingPathComponent("Saved.typ")); saved.recoveryQueue.sync {}
        check(try! JSONDecoder().decode(Recovery.self,from:Data(contentsOf:saved.recoveryURL)).retainedDraft == false,"Choosing a file location removes a document from retained drafts")
        saved.window?.performClose(nil); wait { !app.controllers.contains { $0.session === saved } }
        let quitting = DocumentSession(); quitting.buffer.loadExternal("Quit café 👩🏽‍💻 日本"); app.show(quitting)
        quitting.changed(); quitting.saveWork?.cancel(); let editor = quitting.editor!
        editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0)); editor.captureSelection()
        editor.setMarkedText("語",selectedRange:NSRange(location:1,length:0),replacementRange:editor.selectedRange())
        check(app.applicationShouldTerminate(NSApp) == .terminateNow,"The final termination snapshot adds no custom save question")
        check(!editor.hasMarkedText() && quitting.buffer.source == quitSource,"Quit commits visible composition before retaining the draft")
        let payload = try! JSONDecoder().decode(Recovery.self,from:Data(contentsOf:quitting.recoveryURL))
        check(payload.files[quitting.entry] == quitSource && payload.retainedDraft == true,"Quit waits for the final durable snapshot")
        let project = try! JSONDecoder().decode(Recovery.self,from:Data(contentsOf:session.recoveryURL))
        check(project.retainedDraft == true && project.files[session.entry] == closedSource && project.assets["note.txt"] == session.assets["note.txt"],"Quit durably retains the multi-file project and assets")
        check(NSDocumentController.shared.hasEditedDocuments,"AppKit retains its standard unsaved-document review")
    }
}
