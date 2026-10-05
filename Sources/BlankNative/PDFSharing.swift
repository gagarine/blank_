import AppKit

// Sharing waits for the requested revision while Typst runs off the UI thread.
// It never uses a source file or the last successful PDF from an older revision.
@MainActor extension DocumentSession {
    func requestPDF(_ completion: @escaping (Result<Data,any Error>) -> Void) {
        if compileRevision == revision, let pdfData { completion(.success(pdfData)); return }
        pendingPDFRequests.append((revision,completion))
        compile()
    }
    func finishPDFRequests(_ result: Result<Data,any Error>,revision completedRevision: Int) {
        let requests = pendingPDFRequests; pendingPDFRequests.removeAll()
        for (requestedRevision,completion) in requests {
            if requestedRevision != revision { completion(.failure(NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"Document changed while preparing the PDF. Share again."]))) }
            else if requestedRevision == completedRevision { completion(result) }
            else { pendingPDFRequests.append((requestedRevision,completion)) }
        }
    }
}

// Real file URLs give the system PDF metadata and native sharing destinations.
// Keep a small disk cache: Copy can put the file URL on the clipboard, and a
// receiving service may consume it after the picker closes or the app quits.
final class SharedPDF {
    private static let cacheLock = NSLock()
    private static var liveDirectories = Set<String>()
    private let directory: URL
    let url: URL
    @MainActor init(data: Data,name: String) throws {
        let cache = AppController.dataDirectory.appendingPathComponent("shared-pdfs",isDirectory:true)
        directory = cache.appendingPathComponent(UUID().uuidString,isDirectory:true)
        url = directory.appendingPathComponent((name as NSString).lastPathComponent+".pdf")
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try data.write(to:url,options:.atomic)
        } catch { try? FileManager.default.removeItem(at:directory); throw error }
        Self.cacheLock.lock(); Self.liveDirectories.insert(directory.path); Self.cacheLock.unlock()
        Self.prune(cache)
    }
    deinit {
        Self.cacheLock.lock(); Self.liveDirectories.remove(directory.path); Self.cacheLock.unlock()
    }
    @MainActor private static func prune(_ cache: URL) {
        guard let folders = try? FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:[.contentModificationDateKey],options:.skipsHiddenFiles) else { return }
        cacheLock.lock(); let live = liveDirectories; cacheLock.unlock()
        let clipboard = NSPasteboard.general.pasteboardItems?.compactMap {
            $0.string(forType:.fileURL).flatMap(URL.init(string:))?.deletingLastPathComponent().resolvingSymlinksInPath().path
        } ?? []
        let ordered = folders.sorted {
            ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for folder in ordered.dropFirst(8) where !live.contains(folder.path) && !clipboard.contains(folder.resolvingSymlinksInPath().path) { try? FileManager.default.removeItem(at:folder) }
    }
}
