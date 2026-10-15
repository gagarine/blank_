import AppKit
import BlankCore

// AppKit owns the document title, status, proxy icon and rename/move popover.
// The existing session remains responsible for canonical source, project
// dependencies, conflict checks, recovery and shared Write/Source history.
@objc(BlankDocument) @MainActor final class NativeDocument: NSDocument {
    private(set) var session: DocumentSession
    private var saveFormatAccessory: SaveFormatAccessory?
    private var synchronizing = false
    private var nativeSaveDepth = 0
    private var closed = false
    private var draftURL: URL?
    private var draftRestorationAllowed = true
    private var synchronizedRevision = -1
    private var draftContainer: URL { AppController.dataDirectory.appendingPathComponent("drafts/"+session.id) }
    // The native Where control displays this final directory component.
    private var draftDirectory: URL { draftContainer.appendingPathComponent("Drafts") }
    override class var autosavesInPlace: Bool { true }
    override class var preservesVersions: Bool { false }
    // Canonical project state owns dirty tracking, including included files.
    // Hosting-view binding editors must not keep a saved document marked edited.
    override var isDocumentEdited: Bool { session.dirty }
    override var displayName: String! {
        get { session.title }
        set {
            if session.root == nil, let name = newValue, name != session.title {
                do { try session.renameEntry(name) } catch { session.error = error.localizedDescription }
            }
            super.displayName = session.title
        }
    }

    override init() {
        session = DocumentSession()
        super.init()
        fileType = "org.typst.source"; hasUndoManager = false
    }

    init(session: DocumentSession) {
        self.session = session
        super.init()
        fileType = "org.typst.source"
        hasUndoManager = false
        synchronize()
    }
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { DocumentFormat.allCases.map(\.typeName) }
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        let ready = super.prepareSavePanel(savePanel)
        savePanel.nameFieldStringValue = session.title
        saveFormatAccessory = SaveFormatAccessory(panel:savePanel,format:session.documentFormat)
        return ready
    }
    func synchronize() {
        guard !synchronizing, nativeSaveDepth == 0 else { return }
        synchronizing = true
        defer { synchronizing = false }
        if session.root != nil { draftURL = nil; isDraft = false }
        let url = session.documentURL ?? draftURL
        let type = session.containerURL != nil ? DocumentFormat.container.typeName : DocumentFormat.document.typeName
        if fileType != type { fileType = type }
        if fileURL != url { fileURL = url }
        if let url { fileModificationDate = try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate }
        if session.dirty && synchronizedRevision != session.revision { updateChangeCount(.changeDone) }
        else if !session.dirty { updateChangeCount(.changeCleared) }
        synchronizedRevision = session.revision
        windowControllers.forEach { $0.synchronizeWindowTitleWithDocumentName() }
    }
    override func save(to url: URL,ofType typeName: String,for saveOperation: NSDocument.SaveOperationType,completionHandler: @escaping ((any Error)?) -> Void) {
        guard !closed else { completionHandler(CocoaError(.userCancelled)); return }
        let implicit = [.autosaveInPlaceOperation,.autosaveAsOperation,.autosaveElsewhereOperation].contains(saveOperation)
        if implicit, session.editor?.hasMarkedText() == true || session.editor?.composing == true {
            session.preparedContainerWrite = nil; completionHandler(nil); return
        }
        if !implicit { session.editor?.finishComposition() }
        let chosenType: String
        if let accessory = saveFormatAccessory, accessory.panel?.url?.standardizedFileURL == url.standardizedFileURL { chosenType = accessory.format.typeName }
        else { chosenType = typeName }
        saveFormatAccessory = nil
        if session.root != nil, url.standardizedFileURL != session.documentURL?.standardizedFileURL, session.dependencyRevision != session.revision {
            session.prepareProjectCopy { [weak self] error in
                if let error { completionHandler(error); return }
                self?.save(to:url,ofType:chosenType,for:saveOperation,completionHandler:completionHandler)
            }
            return
        }
        if chosenType == DocumentFormat.container.typeName,
           session.preparedContainerWrite?.url != url || session.preparedContainerWrite?.revision != session.revision {
            session.prepareContainerWrite(to:url) { [weak self] error in
                if implicit, error is ContainerWriteError {
                    if let self, !self.closed {
                        self.session.saveWork?.cancel()
                        let retry = DispatchWorkItem { [weak self] in self?.session.autosave() }
                        self.session.saveWork = retry
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.65,execute:retry)
                    }
                    completionHandler(nil); return
                }
                if let error { completionHandler(error); return }
                self?.save(to:url,ofType:chosenType,for:saveOperation,completionHandler:completionHandler)
            }
            return
        }
        nativeSaveDepth += 1
        super.save(to:url,ofType:chosenType,for:saveOperation) { [weak self] error in
            if let self {
                self.nativeSaveDepth -= 1
                if error != nil { self.session.preparedContainerWrite = nil }
                self.synchronize()
            }
            completionHandler(implicit && (error as? CocoaError)?.code == .userCancelled ? nil : error)
        }
    }
    // NSDocument's default save implementation still supplies file coordination,
    // panels and error presentation. This hook retains our project-wide preflight
    // and atomic source writes instead of regenerating a document from rich text.
    nonisolated override func writeSafely(to url: URL,ofType typeName: String,for saveOperation: NSDocument.SaveOperationType) throws {
        try MainActor.assumeIsolated {
            let implicit = [.autosaveInPlaceOperation,.autosaveAsOperation,.autosaveElsewhereOperation].contains(saveOperation)
            if implicit, session.editor?.hasMarkedText() == true || session.editor?.composing == true {
                throw CocoaError(.userCancelled)
            }
            if !implicit { session.editor?.finishComposition() }
            if saveOperation == .autosaveAsOperation || saveOperation == .autosaveElsewhereOperation || (session.root == nil && saveOperation == .autosaveInPlaceOperation) {
                try session.saveCopy(to:url,adopt:false,overwritingSnapshot:url.deletingLastPathComponent().path == draftDirectory.path); draftURL = url; return
            }
            if saveOperation == .saveToOperation {
                if typeName == DocumentFormat.container.typeName { try session.saveContainer(to:url,adopt:false) }
                else { try session.saveCopy(to:url,adopt:false) }
                return
            }
            let current = session.documentURL
            if url.standardizedFileURL == current?.standardizedFileURL { try session.saveToDisk() }
            else { try session.saveFormatted(to:url,format:DocumentFormat.allCases.first { $0.typeName == typeName } ?? .document) }
        }
    }
    nonisolated override var backupFileURL: URL? { nil }
    nonisolated override func read(from url: URL,ofType typeName: String) throws {
        try MainActor.assumeIsolated {
            if let recovery = try DocumentSession.draftRecovery(at:url) {
                session = try DocumentSession.restoredDraft(recovery)
                draftRestorationAllowed = recovery.retainedDraft != false
                draftURL = url; isDraft = true
            } else { try session.open(url) }
        }
    }
    override func makeWindowControllers() {
        guard windowControllers.isEmpty else { return }
        if draftURL != nil, !EditorPreferences.reopensUnsavedDocuments || !draftRestorationAllowed || !session.hasDraftContents { super.close(); return }
        if let existing = AppController.shared.controllers.first(where:{ $0.session.id == session.id }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            super.close(); return
        }
        let controller = DocumentWindow(session:session,nativeDocument:self)
        AppController.shared.controllers.append(controller)
    }
    override func autosave(withImplicitCancellability cancellable: Bool,completionHandler: @escaping ((any Error)?) -> Void) {
        // Do not interrupt marked text. The session schedules another save when
        // composition commits, and already maintains its own durable journal.
        if session.editor?.hasMarkedText() == true || session.editor?.composing == true { completionHandler(nil); return }
        do {
            guard session.ensureRecovery() else { throw CocoaError(.fileWriteUnknown) }
            if let url = session.containerURL {
                save(to:url,ofType:DocumentFormat.container.typeName,for:.autosaveInPlaceOperation,completionHandler:completionHandler)
            }
            else if session.root != nil { try session.saveToDisk(); completionHandler(nil) }
            else {
                guard hasUnautosavedChanges || draftURL == nil || !FileManager.default.fileExists(atPath:draftURL!.path) else { completionHandler(nil); return }
                try FileManager.default.createDirectory(at:draftDirectory,withIntermediateDirectories:true)
                let url = draftURL ?? draftDirectory.appendingPathComponent((session.entry as NSString).lastPathComponent)
                save(to:url,ofType:"org.typst.source",for:draftURL == nil ? .autosaveAsOperation : .autosaveInPlaceOperation) { [weak self] error in
                    if error == nil, let self, self.session.root == nil { self.isDraft = true; self.synchronize() }
                    completionHandler(error)
                }
            }
        } catch { completionHandler(error) }
    }
    override func close() {
        closed = true
        session.editor?.finishComposition()
        let retained = AppController.shared?.retainingDraftsForTermination == true
        if session.root == nil { _ = session.ensureRecovery(retainingDraft:retained) }
        super.close()
        try? FileManager.default.removeItem(at:session.containerDirectory)
        if !retained || session.root != nil || !session.hasDraftContents { try? FileManager.default.removeItem(at:draftContainer) }
    }
    override func canClose(withDelegate delegate: Any,shouldClose shouldCloseSelector: Selector?,contextInfo: UnsafeMutableRawPointer?) {
        session.editor?.finishComposition()
        if session.dirty { _ = session.ensureRecovery() }
        super.canClose(withDelegate:delegate,shouldClose:shouldCloseSelector,contextInfo:contextInfo)
    }
    override func lock(completionHandler: ((Bool) -> Void)? = nil) {
        session.editor?.finishComposition()
        super.lock(completionHandler:completionHandler)
    }
    override func move(to url: URL,completionHandler: (((any Error)?) -> Void)? = nil) {
        guard !closed else { completionHandler?(CocoaError(.userCancelled)); return }
        if let original = session.containerURL, session.dirty,
           session.preparedContainerWrite?.url != original || session.preparedContainerWrite?.revision != session.revision {
            session.prepareContainerWrite(to:original) { [weak self] error in
                if let error { completionHandler?(error); return }
                self?.move(to:url,completionHandler:completionHandler)
            }
            return
        }
        if session.containerURL == nil, session.root != nil, session.dependencyRevision != session.revision, url.deletingLastPathComponent().standardizedFileURL != session.documentURL?.deletingLastPathComponent().standardizedFileURL {
            session.prepareProjectCopy { [weak self] error in
                if let error { completionHandler?(error); return }
                self?.move(to:url,completionHandler:completionHandler)
            }
            return
        }
        guard session.requestEditing() else { completionHandler?(CocoaError(.userCancelled)); return }
        do {
            if session.root == nil, let draftURL, draftURL.deletingLastPathComponent() == url.deletingLastPathComponent() {
                try FileManager.default.moveItem(at:draftURL,to:url)
                self.draftURL = url; fileURL = url
                try session.renameEntry(url.lastPathComponent)
            } else { try session.moveEntry(to:url) }
            synchronize(); completionHandler?(nil)
        }
        catch { completionHandler?(error) }
    }
    nonisolated override func presentedItemDidChange() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            session.checkDisk(session.entry)
        }
    }
}
