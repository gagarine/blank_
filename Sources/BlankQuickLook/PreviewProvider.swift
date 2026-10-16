import QuickLookUI
import UniformTypeIdentifiers

@objc(BlankPreviewProvider) final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest,completionHandler handler: @escaping (QLPreviewReply?,Error?) -> Void) {
        let reply = QLPreviewReply(dataOfContentType:.pdf,contentSize:.zero) { _ in
            try StoredPreview.data(for:request.fileURL)
        }
        handler(reply,nil)
    }
}
