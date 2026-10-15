import AppKit
import BlankCore
import BlankTestSupport
@testable import BlankNative

@MainActor public enum IntegrationSuite {
    public static func main() {
        setbuf(stdout,nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let state = VerificationState(clipboard:false)
        if CommandLine.arguments.contains("--restore-state") { state.restore(); return }
        if CommandLine.arguments.contains("--draft-integration-prepare") { prepareDrafts(); return }
        let verify = CommandLine.arguments.contains("--draft-integration-verify")
        let disabled = CommandLine.arguments.contains("--draft-integration-disabled-verify")
        let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        var activated = false
        let observation = NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:NSApplication.shared,queue:.main) { _ in activated = true }
        BlankApplication.run(background:true,restore:verify || disabled) { object in
            let app = object as! AppController
            guard let original = app.controllers.first else { fatalError("Missing background native host") }
            if verify { NativeDraftAcceptance.verify() }
            else if disabled { NativeDraftAcceptance.verifyDisabledLaunch() }
            else {
                FileAcceptance.run()
                ProjectAcceptance.run()
                ContainerAcceptance.run()
                BibliographyConversionAcceptance.run()
                NativeDocumentAcceptance.run()
                NativeUniverseAcceptance.run(original:original)
                NativeTemplateAcceptance.run(original:original)
                NativeCitationIntegration.run()
                NativePDFIntegration.run()
            }
            guard !activated, !NSApp.isActive, NSApp.activationPolicy() == .prohibited,
                  NSApp.windows.allSatisfy({ !$0.isVisible && !$0.isKeyWindow }) else {
                print("Background diagnostic: activated=\(activated), active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue), windows=\(NSApp.windows.map { "\(type(of:$0)) \( $0.title) visible=\($0.isVisible) key=\($0.isKeyWindow)" })")
                fatalError("Background verification took focus or displayed a window")
            }
            print("PASS: background integration never activates, displays a window or takes keyboard focus")
            print("Background foreground observation: \(foreground) → \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
            NotificationCenter.default.removeObserver(observation)
            state.restore(preferences:!verify)
            exit(0)
        }
    }
    // Setup only: the Close/Cancel/composition/Quit paths stay in the UI suite.
    private static func prepareDrafts() {
        EditorPreferences.reopensUnsavedDocuments = true
        let closed = DocumentSession()
        closed.entry = "Research.typ"; closed.active = "child.typ"; closed.mode = .source
        closed.buffers = [closed.entry:DocumentBuffer(NativeDraftAcceptance.closedSource),"child.typ":DocumentBuffer(NativeDraftAcceptance.childSource)]
        closed.assets = ["note.txt":Data("Retained asset 日本".utf8)]
        let text = NativeDraftAcceptance.childSource, position = text.range(of:"日本")!.lowerBound
        let byte = text[..<position].utf8.count
        closed.buffer.selection = EditSelection(byte,byte+"日本".utf8.count)
        let quitting = DocumentSession(); quitting.buffer.loadExternal(NativeDraftAcceptance.quitSource)
        let discarded = DocumentSession(); discarded.buffer.loadExternal("Explicitly discarded café")
        let empty = DocumentSession()
        guard closed.ensureRecovery(retainingDraft:true), quitting.ensureRecovery(retainingDraft:true),
              discarded.ensureRecovery(retainingDraft:false), empty.ensureRecovery(retainingDraft:true) else { fatalError("Cannot prepare isolated restoration records") }
        let saved = DocumentSession(); saved.buffer.loadExternal("Saved writing")
        let folder = AppController.dataDirectory.appendingPathComponent("chosen")
        try! FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try! saved.saveCopy(to:folder.appendingPathComponent("Saved.typ"))
        [closed,quitting,discarded,empty,saved].forEach { $0.saveWork?.cancel(); $0.watchers.forEach { $0.cancel() }; $0.recoveryQueue.sync {} }
        print("PASS: prepared disposable multi-process restoration journals")
    }
}
