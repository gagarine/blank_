import AppKit
import SwiftUI
import BlankCore
import Combine

@main enum BlankMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--measure") { ResourceMetrics.run(); return }
        if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--document-self-test") {
            setbuf(stdout,nil)
        }
        let app = NSApplication.shared
        let delegate = AppController(); app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppController!
    static var dataDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["BLANK_DATA_DIR"] { return URL(fileURLWithPath:custom) }
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("blank_-swift")
    }
    var controllers: [DocumentWindow] = []
    var current: DocumentSession? { controllers.first { $0.window === NSApp.keyWindow }?.session ?? controllers.last?.session }
    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.regular)
        installMenus()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let file = CommandLine.arguments.dropFirst().first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        if CommandLine.arguments.contains("--tutorial") { tutorial(nil) }
        else if let file { openURL(URL(fileURLWithPath:file)) }
        else { newDocument(nil) }
        // Finish AppKit's launch/activation-policy transition before requesting
        // activation. The complete menu is already attached at this point.
        DispatchQueue.main.async { NSApp.activate() }
        if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--document-self-test") {
            // Run outside a main-queue block: the acceptance suite pumps the
            // run loop while waiting for background compiler/file callbacks.
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    guard let controller = self.controllers.first else { fatalError("Launch did not open an editor") }
                    if CommandLine.arguments.contains("--document-self-test") { NativeDocumentAcceptance.run() }
                    else { NativeAcceptance.run(controller:controller) }
                    exit(0)
                }
            }
        }
    }
    func show(_ session: DocumentSession) {
        let controller = DocumentWindow(session:session); controllers.append(controller)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    @objc func newDocument(_ sender: Any?) { show(DocumentSession()) }
    @objc func renameDocument(_ sender: Any?) { current?.performDocumentAction { $0.rename(sender) } }
    @objc func moveDocument(_ sender: Any?) { current?.performDocumentAction { $0.move(sender) } }
    @objc func openRecent(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { openURL(url) } }
    @objc func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(sender) }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }; menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = NSMenuItem(title:url.deletingPathExtension().lastPathComponent,action:#selector(openRecent(_:)),keyEquivalent:""); item.target = self; item.representedObject = url; item.toolTip = url.path; menu.addItem(item)
        }
        if menu.items.isEmpty { let item = NSMenuItem(title:"No Recent Documents",action:nil,keyEquivalent:""); item.isEnabled = false; menu.addItem(item) }
        menu.addItem(.separator()); let clear = NSMenuItem(title:"Clear Menu",action:#selector(clearRecent(_:)),keyEquivalent:""); clear.target = self; menu.addItem(clear)
    }
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.init(filenameExtension:"typ")!]; panel.title = "Open a Typst document"
        panel.begin { [weak self] result in if result == .OK, let url = panel.url { self?.openURL(url) } }
    }
    func openURL(_ url: URL) {
        if let document = NSDocumentController.shared.document(for:url) { document.showWindows(); return }
        let session = DocumentSession()
        do {
            try session.open(url)
            if let entry = session.root?.appendingPathComponent(session.entry), let document = NSDocumentController.shared.document(for:entry) { document.showWindows(); return }
            show(session); NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        catch { NSAlert(error:error).runModal() }
    }
    @objc func tutorial(_ sender: Any?) {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Tutorial.typ")
        let file = bundled.flatMap { try? String(contentsOf:$0,encoding:.utf8) } ?? (try? String(contentsOfFile:FileManager.default.currentDirectoryPath+"/examples/Tutorial.typ",encoding:.utf8))
        guard let file else { return }
        let session = DocumentSession(); session.buffers = ["Tutorial.typ":DocumentBuffer(file)]; session.entry = "Tutorial.typ"; session.active = "Tutorial.typ"; session.sidebar = true; show(session)
    }
    @objc func recover(_ sender: Any?) {
        let directory = Self.dataDirectory.appendingPathComponent("recovery")
        let panel = NSOpenPanel(); panel.directoryURL = directory; panel.allowedContentTypes = [.json]; panel.title = "Open a recovery copy"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let data = try? Data(contentsOf:url), let payload = try? JSONDecoder().decode(Recovery.self,from:data) else { return }
            let session = DocumentSession(); session.entry = payload.entry; session.active = payload.entry; session.buffers = payload.files.mapValues { DocumentBuffer($0) }; session.assets = payload.assets; session.dirty = true; self?.show(session)
        }
    }
    @objc func save(_ sender: Any?) { current?.save() }
    @objc func saveAs(_ sender: Any?) { current?.save(true) }
    @objc func export(_ sender: Any?) { current?.exportPDF() }
    @objc func writeMode(_ sender: Any?) { current?.switchMode(.write) }
    @objc func sourceMode(_ sender: Any?) { current?.switchMode(.source) }
    @objc func previewMode(_ sender: Any?) { current?.switchMode(.preview) }
    @objc func commands(_ sender: Any?) { current?.editor?.finishComposition(); current?.commandQuery = ""; current?.pendingCommandKeys.removeAll(); current?.sheet = .commands }
    @objc func settings(_ sender: Any?) { current?.sheet = .settings }
    @objc func statistics(_ sender: Any?) { current?.sheet = .statistics }
    @objc func find(_ sender: Any?) { current?.showSearch() }
    @objc func outline(_ sender: Any?) { current?.toggleSidebar() }
    @objc func undo(_ sender: Any?) { current?.undo() }
    @objc func redo(_ sender: Any?) { current?.undo(true) }
    @objc func bold(_ sender: Any?) { current?.editor?.formatNative(false) }
    @objc func italic(_ sender: Any?) { current?.editor?.formatNative(true) }
    @objc func fullscreen(_ sender: Any?) { NSApp.keyWindow?.toggleFullScreen(nil) }
    @objc func refresh(_ sender: Any?) { current?.compileRevision = -1; current?.compile() }
    @objc func refreshReferences(_ sender: Any?) { if let current { ZoteroIntegration.refresh(current) } }
    @objc func quit(_ sender: Any?) { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { if !flag { newDocument(nil) }; return true }
    func application(_ sender: NSApplication,openFiles filenames: [String]) { filenames.forEach { openURL(URL(fileURLWithPath:$0)) }; sender.reply(toOpenOrPrint:.success) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        prepareDocumentsForTermination()
        let unsaved = controllers.filter { $0.session.dirty }
        if unsaved.contains(where:{ !$0.session.ensureRecovery() }) { let alert = NSAlert(); alert.messageText = "Recovery could not be saved"; alert.informativeText = "Keep blank_ open and save your writing to a writable location before quitting."; alert.runModal(); return .terminateCancel }
        if unsaved.isEmpty { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Save changes before quitting?"; alert.informativeText = "Unsaved documents have recovery copies. Save each document to keep it as a .typ file."; alert.addButton(withTitle:"Review Documents"); alert.addButton(withTitle:"Quit with Recovery Copies"); alert.addButton(withTitle:"Cancel")
        let result = alert.runModal()
        if result == .alertSecondButtonReturn { return .terminateNow }
        if result == .alertFirstButtonReturn { unsaved.first?.window?.makeKeyAndOrderFront(nil); unsaved.first?.session.save() }
        return .terminateCancel
    }
    func prepareDocumentsForTermination() {
        controllers.forEach { $0.session.editor?.finishComposition(); $0.session.autosave() }
    }
    func installMenus() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let root = NSMenuItem(title:title,action:nil,keyEquivalent:""); let submenu = NSMenu(title:title); root.submenu = submenu; bar.addItem(root); return submenu
        }
        func add(_ menu: NSMenu,_ title: String,_ action: Selector?,_ key: String = "",_ modifiers: NSEvent.ModifierFlags = .command,target: AnyObject? = nil) {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:key); item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item)
        }
        let app = menu("blank_")
        add(app,"About blank_",#selector(NSApplication.orderFrontStandardAboutPanel(_:)),target:NSApp)
        app.addItem(.separator()); add(app,"Settings…",#selector(settings(_:)),",",target:self)
        let services = NSMenu(title:"Services"), servicesItem = NSMenuItem(title:"Services",action:nil,keyEquivalent:"")
        servicesItem.submenu = services; app.addItem(servicesItem); NSApp.servicesMenu = services
        app.addItem(.separator()); add(app,"Hide blank_",#selector(NSApplication.hide(_:)),"h",target:NSApp); add(app,"Hide Others",#selector(NSApplication.hideOtherApplications(_:)),"h",[.command,.option],target:NSApp)
        app.addItem(.separator()); add(app,"Quit blank_",#selector(quit(_:)),"q",target:self)
        let file = menu("File")
        add(file,"New Document",#selector(newDocument(_:)),"n",target:self); add(file,"Open…",#selector(openDocument(_:)),"o",target:self)
        let recent = NSMenuItem(title:"Open Recent",action:nil,keyEquivalent:""); recent.submenu = NSMenu(title:"Open Recent"); recent.submenu?.delegate = self; file.addItem(recent)
        add(file,"Open Recovery Copy…",#selector(recover(_:)),target:self); file.addItem(.separator())
        add(file,"Close Window",#selector(NSWindow.performClose(_:)),"w"); add(file,"Save",#selector(save(_:)),"s",target:self); add(file,"Save As…",#selector(saveAs(_:)),"s",[.command,.shift],target:self)
        add(file,"Export PDF…",#selector(export(_:)),"e",[.command,.shift],target:self)
        add(file,"Rename Document…",#selector(renameDocument(_:)),target:self)
        add(file,"Move To…",#selector(moveDocument(_:)),target:self)
        let edit = menu("Edit")
        add(edit,"Undo",#selector(undo(_:)),"z",target:self); add(edit,"Redo",#selector(redo(_:)),"z",[.command,.shift],target:self); edit.addItem(.separator())
        add(edit,"Cut",#selector(NSText.cut(_:)),"x"); add(edit,"Copy",#selector(NSText.copy(_:)),"c"); add(edit,"Paste",#selector(NSText.paste(_:)),"v"); add(edit,"Select All",#selector(NSText.selectAll(_:)),"a"); edit.addItem(.separator()); add(edit,"Find…",#selector(find(_:)),"f",target:self)
        let format = menu("Format"); add(format,"Bold",#selector(bold(_:)),"b",target:self); add(format,"Italic",#selector(italic(_:)),"i",target:self)
        let view = menu("View"); add(view,"Write",#selector(writeMode(_:)),"1",target:self); add(view,"Source",#selector(sourceMode(_:)),"2",target:self); add(view,"Preview",#selector(previewMode(_:)),"3",target:self)
        view.addItem(.separator()); add(view,"Toggle Sidebar",#selector(outline(_:)),"l",[.command,.shift],target:self); add(view,"Commands…",#selector(commands(_:)),"k",target:self); add(view,"Refresh Preview",#selector(refresh(_:)),target:self); add(view,"Enter Full Screen",#selector(fullscreen(_:)),"f",[.command,.control],target:self)
        let window = menu("Window"); NSApp.windowsMenu = window
        add(window,"Minimize",#selector(NSWindow.performMiniaturize(_:)),"m"); add(window,"Zoom",#selector(NSWindow.performZoom(_:))); window.addItem(.separator()); add(window,"Bring All to Front",#selector(NSApplication.arrangeInFront(_:)),target:NSApp)
        let help = menu("Help"); NSApp.helpMenu = help
        add(help,"Tutorial",#selector(tutorial(_:)),target:self); add(help,"Statistics & Info",#selector(statistics(_:)),target:self); add(help,"Refresh Zotero References",#selector(refreshReferences(_:)),target:self)
        NSApp.mainMenu = bar
    }
}
@MainActor final class DocumentWindow: NSWindowController, NSWindowDelegate {
    let session: DocumentSession
    let nativeDocument: NativeDocument
    var toolbarSubscriptions = Set<AnyCancellable>()
    var modeItem: NSToolbarItemGroup?
    var sidebarItem: NSToolbarItem?
    init(session: DocumentSession,nativeDocument: NativeDocument? = nil) {
        self.session = session
        self.nativeDocument = nativeDocument ?? NativeDocument(session:session)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1060,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:window)
        window.titlebarAppearsTransparent = true
        if session.dark { window.appearance = NSAppearance(named:.darkAqua) }
        window.center(); window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView:EditorRoot(session:session)); window.minSize = NSSize(width:660,height:480)
        installToolbar()
        window.isReleasedWhenClosed = false; session.window = window
        self.nativeDocument.addWindowController(self)
        NSDocumentController.shared.addDocument(self.nativeDocument)
        session.onTitle = { [weak document = self.nativeDocument] in document?.synchronize() }
        self.nativeDocument.synchronize()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // NSDocument has already provided the native Save/Don't Save/Cancel
        // decision. Keep only the durable-recovery guard here.
        if session.dirty && !session.ensureRecovery() {
            let alert = NSAlert(); alert.messageText = "Recovery could not be saved"; alert.informativeText = session.error ?? "Save your writing before closing."; alert.beginSheetModal(for:sender); return false
        }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        nativeDocument.removeWindowController(self)
        nativeDocument.close()
        session.watchers.forEach { $0.cancel() }; session.saveWork?.cancel(); session.diskScanWork?.cancel()
        AppController.shared?.controllers.removeAll { $0 === self }
    }
}
