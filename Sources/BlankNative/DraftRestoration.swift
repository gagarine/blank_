import AppKit
import BlankCore

extension DocumentSession {
    var hasDraftContents: Bool { buffers.values.contains { !$0.source.isEmpty } || !assets.isEmpty }
    func recoverySnapshot() -> Recovery {
        Recovery(id:id,entry:entry,root:root?.path,files:buffers.mapValues(\.source),assets:assets,
                 retainedDraft:root == nil && hasDraftContents,active:active,
                 selections:buffers.mapValues(\.selection),mode:mode.rawValue)
    }
    // AppKit can reopen the native UTF-8 snapshot itself. Rehydrate from the
    // authoritative project journal, keeping its identity and dependencies.
    static func restoredDraft(at snapshot: URL) throws -> DocumentSession? {
        guard let payload = try draftRecovery(at:snapshot) else { return nil }
        return try restoredDraft(payload)
    }
    static func draftRecovery(at snapshot: URL) throws -> Recovery? {
        let folder = snapshot.deletingLastPathComponent(), container = folder.deletingLastPathComponent()
        guard folder.lastPathComponent == "Drafts", UUID(uuidString:container.lastPathComponent) != nil,
              container.deletingLastPathComponent().standardizedFileURL == AppController.dataDirectory.appendingPathComponent("drafts").standardizedFileURL else { return nil }
        let record = AppController.dataDirectory.appendingPathComponent("recovery/"+container.lastPathComponent+".json")
        let payload = try JSONDecoder().decode(Recovery.self,from:Data(contentsOf:record))
        guard payload.id == container.lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
        guard payload.root == nil else { return nil }
        return payload
    }
    static func restoredDraft(_ payload: Recovery) throws -> DocumentSession {
        guard payload.root == nil, UUID(uuidString:payload.id) != nil, payload.files[payload.entry] != nil else { throw CocoaError(.fileReadCorruptFile) }
        let session = DocumentSession(id:payload.id)
        let directory = AppController.dataDirectory.appendingPathComponent("drafts/"+payload.id+"/Drafts")
        for path in Set(payload.files.keys).union(payload.assets.keys) { _ = try dependencyTarget(path,root:directory) }
        session.entry = payload.entry; session.active = payload.active.flatMap { payload.files[$0] != nil ? $0 : nil } ?? payload.entry
        session.buffers = payload.files.mapValues { DocumentBuffer($0) }; session.assets = payload.assets
        for (path,selection) in payload.selections ?? [:] {
            guard let buffer = session.buffers[path] else { continue }
            let limit = buffer.source.utf8.count
            buffer.selection = EditSelection(max(0,min(selection.anchor,limit)),max(0,min(selection.focus,limit)))
        }
        session.mode = payload.mode.flatMap(EditorMode.init(rawValue:)) ?? .write
        session.dirty = true
        return session
    }
}

extension AppController {
    // The recovery journal remains authoritative for source and dependencies.
    // Only canonical session records opt in; conflict archives remain manual.
    func restoreDrafts() -> Bool {
        let fm = FileManager.default, directory = Self.dataDirectory.appendingPathComponent("recovery")
        draftRestorationError = nil
        guard EditorPreferences.reopensUnsavedDocuments else { return false }
        guard fm.fileExists(atPath:directory.path) else { return false }
        var restored = false
        do {
            let records = try fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter { $0.pathExtension == "json" && UUID(uuidString:$0.deletingPathExtension().lastPathComponent) != nil }
            for record in records.sorted(by:{ $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let payload = try JSONDecoder().decode(Recovery.self,from:Data(contentsOf:record))
                    guard payload.id == record.deletingPathExtension().lastPathComponent, payload.root == nil else { continue }
                    let legacyDraft = fm.fileExists(atPath:Self.dataDirectory.appendingPathComponent("drafts/"+payload.id+"/Drafts").path)
                    guard payload.retainedDraft == true || payload.retainedDraft == nil && legacyDraft else { continue }
                    guard !controllers.contains(where:{ $0.session.id == payload.id }) else { continue }
                    let session = try DocumentSession.restoredDraft(payload)
                    guard session.hasDraftContents else { continue }
                    if let document = NSDocumentController.shared.documents.compactMap({ $0 as? NativeDocument }).first(where:{ $0.session.id == session.id }) {
                        document.makeWindowControllers(); document.showWindows()
                    } else { show(session) }
                    restored = true
                    let live = controllers.first { $0.session.id == session.id }?.session ?? session
                    live.autosave()
                    if live.mode == .preview { live.compile() }
                } catch {
                    draftRestorationError = "Some drafts could not be reopened. Their recovery files have been kept. Use File → Open Recovery Copy… to inspect them."
                    NSLog("Draft restoration: %@",error.localizedDescription)
                }
            }
        } catch {
            draftRestorationError = "Drafts could not be reopened: "+error.localizedDescription
            NSLog("Draft restoration: %@",error.localizedDescription)
        }
        return restored
    }
}
