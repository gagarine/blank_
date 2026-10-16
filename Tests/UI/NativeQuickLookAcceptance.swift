import AppKit
import QuickLookUI
@testable import BlankNative

@MainActor enum NativeQuickLookAcceptance {
    // Explicit visual fixture; normal/background checks never show Quick Look
    // or alter extension registration. Uses only the app-owned test directory.
    static func showFixture(_ controller: DocumentWindow) {
        let source = "#set page(width: 300pt, height: 400pt, margin: 30pt)\n= Cached Quick Look\n\nThe complete document is available offline.\n\n#rect(width: 90%, height: 50pt, fill: blue)\n#pagebreak()\n= Second cached page\n\nThis is a two-page document."
        let url = AppController.temporaryDirectory.appendingPathComponent("Quick Look.typz")
        try! TypstContainer.encode(["main.typ":Data(source.utf8)],entry:"main.typ",renderPreview:true).write(to:url)
        let preview = QLPreviewView(frame:controller.window!.contentView!.bounds,style:.normal)!
        preview.autoresizingMask = [.width,.height]
        preview.shouldCloseWithWindow = true
        controller.window?.contentView = preview
        preview.previewItem = url as NSURL
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
}
