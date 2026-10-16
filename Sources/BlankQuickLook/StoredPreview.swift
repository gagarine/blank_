import Foundation
import CContainer

// Quick Look reads the bounded cached member in-process. It has no compiler,
// subprocess, package cache or network path.
enum StoredPreview {
    static func data(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var count = 0
        guard let bytes = url.withUnsafeFileSystemRepresentation({ blank_container_preview($0,&count) }) else {
            throw NSError(domain:"blank_.QuickLook",code:1,userInfo:[NSLocalizedDescriptionKey:"No saved preview is available. Open and save the document in blank_."])
        }
        defer { blank_container_free(bytes,count) }
        return Data(bytes:bytes,count:count)
    }
}
