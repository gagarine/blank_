import AppKit
import BlankCore

// AppKit owns the document title, status, proxy icon and rename/move popover.
// The existing session remains responsible for canonical source, project
// dependencies, conflict checks, recovery and shared Write/Source history.
@objc(BlankDocument) @MainActor final class NativeDocument: NSDocument {
    let session: DocumentSession
    private var synchronizing = false
    private var nativeSaveDepth = 0
    private var draftURL: URL?
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
    func synchronize() {
        guard !synchronizing, nativeSaveDepth == 0 else { return }
        synchronizing = true
        defer { synchronizing = false }
        if session.root != nil { draftURL = nil; isDraft = false }
        let url = session.root?.appendingPathComponent(session.entry) ?? draftURL
        if fileURL != url { fileURL = url }
        if let url { fileModificationDate = try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate }
        if session.dirty && synchronizedRevision != session.revision { updateChangeCount(.changeDone) }
        else if !session.dirty { updateChangeCount(.changeCleared) }
        synchronizedRevision = session.revision
        windowControllers.forEach { $0.synchronizeWindowTitleWithDocumentName() }
    }
    override func save(to url: URL,ofType typeName: String,for saveOperation: NSDocument.SaveOperationType,completionHandler: @escaping ((any Error)?) -> Void) {
        if session.root != nil, url.standardizedFileURL != session.root?.appendingPathComponent(session.entry).standardizedFileURL, session.dependencyRevision != session.revision {
            session.prepareProjectCopy { [weak self] error in
                if let error { completionHandler(error); return }
                self?.save(to:url,ofType:typeName,for:saveOperation,completionHandler:completionHandler)
            }
            return
        }
        nativeSaveDepth += 1
        super.save(to:url,ofType:typeName,for:saveOperation) { [weak self] error in
            if let self { self.nativeSaveDepth -= 1; self.synchronize() }
            completionHandler(error)
        }
    }
    // NSDocument's default save implementation still supplies file coordination,
    // panels and error presentation. This hook retains our project-wide preflight
    // and atomic source writes instead of regenerating a document from rich text.
    nonisolated override func writeSafely(to url: URL,ofType typeName: String,for saveOperation: NSDocument.SaveOperationType) throws {
        try MainActor.assumeIsolated {
            session.editor?.finishComposition()
            if saveOperation == .autosaveAsOperation || saveOperation == .autosaveElsewhereOperation || (session.root == nil && saveOperation == .autosaveInPlaceOperation) {
                try session.saveCopy(to:url,adopt:false,overwritingSnapshot:url.deletingLastPathComponent().path == draftDirectory.path); draftURL = url; return
            }
            if saveOperation == .saveToOperation { try session.saveCopy(to:url,adopt:false); return }
            let current = session.root?.appendingPathComponent(session.entry)
            if url.standardizedFileURL == current?.standardizedFileURL { try session.saveToDisk() }
            else { try session.saveCopy(to:url) }
        }
    }
    nonisolated override var backupFileURL: URL? { nil }
    nonisolated override func read(from url: URL,ofType typeName: String) throws {
        try MainActor.assumeIsolated { try session.open(url) }
    }
    override func makeWindowControllers() {
        guard windowControllers.isEmpty else { return }
        let controller = DocumentWindow(session:session,nativeDocument:self)
        AppController.shared.controllers.append(controller)
    }
    override func autosave(withImplicitCancellability cancellable: Bool,completionHandler: @escaping ((any Error)?) -> Void) {
        // Do not interrupt marked text. The session schedules another save when
        // composition commits, and already maintains its own durable journal.
        if session.editor?.hasMarkedText() == true || session.editor?.composing == true { completionHandler(nil); return }
        do {
            guard session.ensureRecovery() else { throw CocoaError(.fileWriteUnknown) }
            if session.root != nil { try session.saveToDisk(); completionHandler(nil) }
            else {
                guard hasUnautosavedChanges else { completionHandler(nil); return }
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
        super.close()
        try? FileManager.default.removeItem(at:draftContainer)
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
        if session.root != nil, session.dependencyRevision != session.revision, url.deletingLastPathComponent().standardizedFileURL != session.root?.appendingPathComponent(session.entry).deletingLastPathComponent().standardizedFileURL {
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
