import AppKit
import PDFKit
import BlankCore
@testable import BlankNative

@MainActor enum NativePreviewAcceptance {
    static func run(_ original: DocumentWindow) {
        let root = AppController.temporaryDirectory.appendingPathComponent("preview-"+UUID().uuidString)
        try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func wait(_ label: String,_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(15)
            while !condition() && Date() < end {
                for _ in 0..<32 {
                    guard let event = NSApp.nextEvent(matching:.any,until:Date(),inMode:.default,dequeue:true) else { break }
                    NSApp.sendEvent(event)
                }
                RunLoop.main.run(until:Date().addingTimeInterval(0.01))
            }
            precondition(condition(),label); print("PASS: "+label)
        }
        let draft = DocumentSession()
        draft.buffer.loadExternal("= Bundle preview 日本\n\nA visible PDF page.")
        let file = root.appendingPathComponent("Paper.typz")
        try! draft.saveFormatted(to:file,format:.container)
        for compiledBeforeMount in [false,true] {
            let session = DocumentSession(); try! session.open(file)
            if compiledBeforeMount {
                session.compile(); wait("A bundle can compile before mounting Preview") { !session.compiling && session.pdf != nil }
            }
            let window = DocumentWindow(session:session)
            AppController.shared.controllers.append(window)
            window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
            session.switchMode(.preview)
            wait("Opening .typz supplies its PDF to the native Preview view") { !session.compiling && session.pdfView?.document === session.pdf && session.pdf != nil }
            wait("The bundle PDF has a visible, fitted native page") {
                guard let view = session.pdfView, let page = view.document?.page(at:0), view.bounds.width > 100, view.bounds.height > 100, view.scaleFactor.isFinite, view.scaleFactor > 0 else { return false }
                return view.convert(page.bounds(for:.mediaBox),from:page).intersects(view.bounds) && view.visiblePages.contains(page)
            }
            precondition(session.pdf!.page(at:0)!.string!.contains("Bundle preview"))
            window.window?.close()
        }
        try? FileManager.default.removeItem(at:draft.containerDirectory)
        original.window?.makeKeyAndOrderFront(nil)
    }
}
