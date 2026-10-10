import AppKit
import SwiftUI
import BlankCore
import Combine

@main enum BlankMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--measure") { ResourceMetrics.run(); return }
        if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--document-self-test") || CommandLine.arguments.contains("--figure-self-test") || CommandLine.arguments.contains("--label-self-test") || CommandLine.arguments.contains("--block-source-self-test") || CommandLine.arguments.contains("--selection-style-self-test") {
            setbuf(stdout,nil)
        }
        let app = NSApplication.shared
        let delegate = AppController(); app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    static var shared: AppController!
    static var dataDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["BLANK_DATA_DIR"] { return URL(fileURLWithPath:custom) }
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("blank_-swift")
    }
    var controllers: [DocumentWindow] = []
    var draftRestorationError: String?
    var retainingDraftsForTermination = false
    var templateGallery: TemplateGalleryWindow?
    @objc func templates(_ sender: Any?) {
        do {
            if templateGallery == nil { templateGallery = TemplateGalleryWindow(library:try TemplateLibrary()) }
            try templateGallery?.library.reload()
            templateGallery?.showWindow(nil); templateGallery?.window?.makeKeyAndOrderFront(nil)
        } catch { NSAlert(error:error).runModal() }
    }
    @objc func saveAsTemplate(_ sender: Any?) {
        guard let session = current else { return }; session.editor?.finishComposition()
        templates(sender); templateGallery?.addDocument(session)
    }
    var current: DocumentSession? {
        if let key = NSApp.keyWindow { return controllers.first { $0.window === (key.sheetParent ?? key) }?.session }
        return controllers.last?.session
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.regular)
        installMenus()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let file = CommandLine.arguments.dropFirst().first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        let isolated = CommandLine.arguments.contains("--draft-lifecycle-prepare") || CommandLine.arguments.contains(where:{ $0.hasSuffix("self-test") || $0.hasSuffix("ui-test") })
        let restored = !isolated && restoreDrafts()
        if CommandLine.arguments.contains("--tutorial") { tutorial(nil) }
        else if let file { openURL(URL(fileURLWithPath:file)) }
        else if !restored && controllers.isEmpty { newDocument(nil) }
        if let draftRestorationError { current?.error = draftRestorationError }
        // Finish AppKit's launch/activation-policy transition before requesting
        // activation. The complete menu is already attached at this point.
        DispatchQueue.main.async { if !CommandLine.arguments.contains("--selection-style-ui-test") { NSApp.activate() } }
        if CommandLine.arguments.contains(where:{ $0.hasPrefix("--draft-lifecycle-") }) {
            setbuf(stdout,nil)
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    if CommandLine.arguments.contains("--draft-lifecycle-prepare") { NativeDraftAcceptance.prepare() }
                    else if CommandLine.arguments.contains("--draft-lifecycle-disabled-verify") { NativeDraftAcceptance.verifyDisabledLaunch() }
                    else { NativeDraftAcceptance.verify() }
                    exit(0)
                }
            }
        }
        if CommandLine.arguments.contains("--selection-style-ui-test"), let controller = controllers.first { NativeSelectionStyleAcceptance.showFixture(controller:controller) }
        if CommandLine.arguments.contains("--figure-ui-test"), let controller = controllers.first { NativeFigureAcceptance.showFixture(controller:controller) }
        if CommandLine.arguments.contains("--reference-ui-test"), let controller = controllers.first {
            NativeReferenceAcceptance.showFixture(controller:controller)
        }
        if CommandLine.arguments.contains("--citation-ui-test"), let controller = controllers.first {
            NativeCitationAcceptance.showFixture(controller:controller)
        }
        if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--document-self-test") || CommandLine.arguments.contains("--figure-self-test") || CommandLine.arguments.contains("--label-self-test") || CommandLine.arguments.contains("--block-source-self-test") || CommandLine.arguments.contains("--selection-style-self-test") {
            // Run outside a main-queue block: the acceptance suite pumps the
            // run loop while waiting for background compiler/file callbacks.
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    guard let controller = self.controllers.first else { fatalError("Launch did not open an editor") }
                    if CommandLine.arguments.contains("--selection-style-self-test") { NativeSelectionStyleAcceptance.run(controller:controller) }
                    else if CommandLine.arguments.contains("--block-source-self-test") { NativeBlockSourceAcceptance.run(controller:controller) }
                    else if CommandLine.arguments.contains("--label-self-test") { NativeLabelAcceptance.run(controller:controller) }
                    else if CommandLine.arguments.contains("--figure-self-test") { NativeFigureAcceptance.run(controller:controller) }
                    else if CommandLine.arguments.contains("--document-self-test") { NativeDocumentAcceptance.run() }
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
    @objc func newProject(_ sender: Any?) {
        let panel = NSSavePanel(); panel.title = "New Project"; panel.nameFieldStringValue = "Untitled Project"; panel.prompt = "Create Project"; panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { self?.show(try ProjectSelection.create(at:url)) } catch { NSAlert(error:error).runModal() }
        }
    }
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
        var session = DocumentSession()
        do {
            if let restored = try DocumentSession.restoredDraft(at:url) { session = restored }
            else { try session.open(url) }
            if let existing = controllers.first(where:{ $0.session.id == session.id }) { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
            if let entry = session.root?.appendingPathComponent(session.entry), let document = NSDocumentController.shared.document(for:entry) { document.showWindows(); return }
            show(session); NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        catch let choice as ProjectEntryChoice {
            let panel = NSOpenPanel(); panel.directoryURL = choice.root; panel.allowedContentTypes = [.init(filenameExtension:"typ")!]; panel.title = "Choose the main Typst document"; panel.prompt = "Open Project"
            panel.begin { [weak self] response in
                guard response == .OK, let selected = panel.url else { return }
                do {
                    let path = try ProjectSelection.relative(selected,root:choice.root)
                    let session = DocumentSession(); try session.open(choice.root,selectedEntry:path)
                    if let document = NSDocumentController.shared.document(for:selected) { document.showWindows(); return }
                    self?.show(session); NSDocumentController.shared.noteNewRecentDocumentURL(choice.root)
                } catch { NSAlert(error:error).runModal() }
            }
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
    @objc func underline(_ sender: Any?) { current?.editor?.formatNative(.underline) }
    @objc func strikethrough(_ sender: Any?) { current?.editor?.formatNative(.strikethrough) }
    @objc func inlineStyle(_ sender: NSMenuItem) { if let mark = InlineMark(rawValue:sender.tag) { current?.editor?.formatNative(mark) } }
    @objc func alignment(_ sender: NSMenuItem) { if let alignment = sender.representedObject as? String { current?.editor?.selectionAlignment(alignment == "default" ? nil : alignment) } }
    @objc func inlineColor(_ sender: NSMenuItem) {
        if let values = sender.representedObject as? [String] { current?.editor?.selectionAttribute(values[0],values.count > 1 ? values[1] : nil) }
    }
    @objc func editLink(_ sender: Any?) { current?.editor?.selectionLink() }
    @objc func blockCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? SlashCommand else { return }
        current?.performBlockCommand(command)
    }
    @objc func go(_ sender: NSMenuItem) {
        guard NSApp.keyWindow == nil || current?.window === NSApp.keyWindow,
              let action = sender.representedObject as? GoAction else { return }
        current?.navigate(action)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(bold(_:)),#selector(italic(_:)),#selector(underline(_:)),#selector(strikethrough(_:))].contains(where:{ $0 == menuItem.action }) {
            return current?.mode == .write
        }
        if menuItem.action == #selector(inlineStyle(_:)) || menuItem.action == #selector(alignment(_:)) { return current?.mode == .write }
        if menuItem.action == #selector(inlineColor(_:)) || menuItem.action == #selector(editLink(_:)) { return current?.mode == .write && (current?.editor?.selectedRange().length ?? 0) > 0 }
        if menuItem.action == #selector(blockCommand(_:)), let command = menuItem.representedObject as? SlashCommand {
            return current?.canPerformBlockCommand(command) == true
        }
        if menuItem.action == #selector(go(_:)), let action = menuItem.representedObject as? GoAction {
            return (NSApp.keyWindow == nil || current?.window === NSApp.keyWindow) && current?.canNavigate(action) == true
        }
        let documentActions: [Selector] = [#selector(save(_:)),#selector(saveAs(_:)),#selector(saveAsTemplate(_:)),#selector(export(_:)),#selector(renameDocument(_:)),#selector(moveDocument(_:)),#selector(commands(_:)),#selector(undo(_:)),#selector(redo(_:)),#selector(bold(_:)),#selector(italic(_:)),#selector(find(_:)),#selector(writeMode(_:)),#selector(sourceMode(_:)),#selector(previewMode(_:)),#selector(outline(_:)),#selector(settings(_:)),#selector(statistics(_:)),#selector(refresh(_:)),#selector(refreshReferences(_:)),#selector(convertBibliography(_:))]
        if documentActions.contains(where:{ $0 == menuItem.action }) { return current != nil }
        return true
    }
    @objc func fullscreen(_ sender: Any?) { NSApp.keyWindow?.toggleFullScreen(nil) }
    @objc func refresh(_ sender: Any?) { current?.compileRevision = -1; current?.compile() }
    @objc func convertBibliography(_ sender: Any?) { current?.showBibliographyConversion() }
    @objc func refreshReferences(_ sender: Any?) { if let current { ZoteroIntegration.refresh(current) } }
    @objc func quit(_ sender: Any?) { prepareDocumentsForTermination(); NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { if !flag && !restoreDrafts() { newDocument(nil) }; return true }
    func application(_ sender: NSApplication,openFiles filenames: [String]) { filenames.forEach { openURL(URL(fileURLWithPath:$0)) }; sender.reply(toOpenOrPrint:.success) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        retainingDraftsForTermination = false
        prepareDocumentsForTermination()
        if controllers.contains(where:{ ($0.session.dirty || $0.session.root == nil && $0.session.hasDraftContents) && !$0.session.ensureRecovery() }) { let alert = NSAlert(); alert.messageText = "Recovery could not be saved"; alert.informativeText = "Keep blank_ open and save your writing to a writable location before quitting."; alert.runModal(); return .terminateCancel }
        let keepDrafts = EditorPreferences.reopensUnsavedDocuments
        // AppKit has already handled its ordinary unsaved-document review.
        // Preserve any drafts still open at termination without another dialog.
        if !keepDrafts && controllers.contains(where:{ $0.session.root == nil && !$0.session.ensureRecovery(retainingDraft:false) }) { return .terminateCancel }
        retainingDraftsForTermination = keepDrafts
        return .terminateNow
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
        add(file,"New Document",#selector(newDocument(_:)),"n",target:self); add(file,"New Project…",#selector(newProject(_:)),target:self); add(file,"Templates…",#selector(templates(_:)),target:self); add(file,"Open…",#selector(openDocument(_:)),"o",target:self)
        let recent = NSMenuItem(title:"Open Recent",action:nil,keyEquivalent:""); recent.submenu = NSMenu(title:"Open Recent"); recent.submenu?.delegate = self; file.addItem(recent)
        add(file,"Open Recovery Copy…",#selector(recover(_:)),target:self); file.addItem(.separator())
        add(file,"Close Window",#selector(NSWindow.performClose(_:)),"w"); add(file,"Save",#selector(save(_:)),"s",target:self); add(file,"Save As…",#selector(saveAs(_:)),"s",[.command,.shift],target:self)
        add(file,"Save as Template…",#selector(saveAsTemplate(_:)),target:self)
        add(file,"Convert Bibliography…",#selector(convertBibliography(_:)),target:self)
        add(file,"Export PDF…",#selector(export(_:)),"e",[.command,.shift],target:self)
        add(file,"Rename Document…",#selector(renameDocument(_:)),target:self)
        add(file,"Move To…",#selector(moveDocument(_:)),target:self)
        let edit = menu("Edit")
        add(edit,"Undo",#selector(undo(_:)),"z",target:self); add(edit,"Redo",#selector(redo(_:)),"z",[.command,.shift],target:self); edit.addItem(.separator())
        add(edit,"Cut",#selector(NSText.cut(_:)),"x"); add(edit,"Copy",#selector(NSText.copy(_:)),"c"); add(edit,"Paste",#selector(NSText.paste(_:)),"v"); add(edit,"Select All",#selector(NSText.selectAll(_:)),"a"); edit.addItem(.separator()); add(edit,"Find…",#selector(find(_:)),"f",target:self)
        func blockItem(_ menu: NSMenu,_ command: SlashCommand) {
            add(menu,command.label+(command.insertion && !["table","code"].contains(command.kind) ? "…" : ""),#selector(blockCommand(_:)),target:self)
            menu.items.last?.representedObject = command
        }
        let insert = menu("Insert")
        for command in SlashCommand.all where command.insertion { blockItem(insert,command) }
        let format = menu("Format"); add(format,"Bold",#selector(bold(_:)),"b",target:self); add(format,"Italic",#selector(italic(_:)),"i",target:self)
        add(format,"Underline",#selector(underline(_:)),"u",target:self); add(format,"Strikethrough",#selector(strikethrough(_:)),target:self)
        for (title,mark) in [("Inline Code",InlineMark.code),("Superscript",.superscript),("Subscript",.subscripted)] {
            add(format,title,#selector(inlineStyle(_:)),target:self); format.items.last?.tag = mark.rawValue
        }
        add(format,"Link…",#selector(editLink(_:)),target:self)
        for (title,attribute) in [("Text Color","color"),("Highlight Color","highlight")] {
            let item = NSMenuItem(title:title,action:nil,keyEquivalent:""); let submenu = NSMenu(title:title); item.submenu = submenu; format.addItem(item)
            add(submenu,attribute == "color" ? "Default" : "None",#selector(inlineColor(_:)),target:self); submenu.items.last?.representedObject = [attribute]
            for (name,color,highlight) in inlinePalette { add(submenu,name,#selector(inlineColor(_:)),target:self); submenu.items.last?.representedObject = [attribute,attribute == "color" ? color : highlight] }
        }
        let alignmentItem = NSMenuItem(title:"Alignment",action:nil,keyEquivalent:""); let alignmentMenu = NSMenu(title:"Alignment"); alignmentItem.submenu = alignmentMenu; format.addItem(alignmentItem)
        for value in ["default","left","center","right","justified"] { add(alignmentMenu,value.capitalized,#selector(alignment(_:)),target:self); alignmentMenu.items.last?.representedObject = value }
        format.addItem(.separator())
        for command in SlashCommand.all where !command.insertion { blockItem(format,command) }
        let view = menu("View"); add(view,"Write",#selector(writeMode(_:)),"1",target:self); add(view,"Source",#selector(sourceMode(_:)),"2",target:self); add(view,"Preview",#selector(previewMode(_:)),"3",target:self)
        view.addItem(.separator()); add(view,"Toggle Sidebar",#selector(outline(_:)),"l",[.command,.shift],target:self); add(view,"Commands…",#selector(commands(_:)),"k",target:self); add(view,"Refresh Preview",#selector(refresh(_:)),target:self); add(view,"Enter Full Screen",#selector(fullscreen(_:)),"f",[.command,.control],target:self)
        let go = menu("Go")
        func navigation(_ title: String,_ action: GoAction,_ key: String = "",_ modifiers: NSEvent.ModifierFlags = .command) {
            add(go,title,#selector(self.go(_:)),key,modifiers,target:self)
            go.items.last?.representedObject = action
        }
        navigation("Up",.up)
        navigation("Down",.down)
        // Option-arrow already moves blocks in Write and is native paragraph
        // navigation in Source. Keep those editing keys free of menu interception.
        navigation("Previous Item",.previousItem,String(UnicodeScalar(NSUpArrowFunctionKey)!),[.command,.option])
        navigation("Next Item",.nextItem,String(UnicodeScalar(NSDownArrowFunctionKey)!),[.command,.option])
        navigation("Go to Page…",.page,"g",[.command,.option])
        go.addItem(.separator())
        navigation("Back",.back,"[")
        navigation("Forward",.forward,"]")
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
    var searchItem: NSSearchToolbarItem?
    var searchWidth: NSLayoutConstraint?
    var zoomItem: NSToolbarItemGroup?
    var shareButton: NSButton?
    var sharePicker: NSSharingServicePicker?
    var sharedPDF: SharedPDF?
    var activePDFShares: [ObjectIdentifier:SharedPDF] = [:]
    var splitController: DocumentSplitViewController!
    init(session: DocumentSession,nativeDocument: NativeDocument? = nil) {
        self.session = session
        self.nativeDocument = nativeDocument ?? NativeDocument(session:session)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1060,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:window)
        window.titlebarAppearsTransparent = false
        if session.dark { window.appearance = NSAppearance(named:.darkAqua) }
        window.center(); window.delegate = self
        window.acceptsMouseMovedEvents = true
        splitController = DocumentSplitViewController(session:session)
        window.contentViewController = splitController; window.minSize = NSSize(width:660,height:480)
        window.setContentSize(NSSize(width:1060,height:780))
        window.titlebarSeparatorStyle = .none
        installToolbar()
        window.isReleasedWhenClosed = false; session.window = window
        self.nativeDocument.addWindowController(self)
        NSDocumentController.shared.addDocument(self.nativeDocument)
        session.onTitle = { [weak document = self.nativeDocument] in document?.synchronize() }
        self.nativeDocument.synchronize()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        session.editor?.finishComposition()
        // NSDocument supplies the native Save/Don't Save/Cancel panel.
        // Keep the durable recovery guard for every closing document.
        if (session.dirty || session.root == nil && session.hasDraftContents) && !session.ensureRecovery() {
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
