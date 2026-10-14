import AppKit
import PDFKit
import BlankCore
@testable import BlankNative

@MainActor enum NativePDFIntegration {
    static func run() {
        let session = DocumentSession()
        defer { session.saveWork?.cancel(); session.watchers.forEach { $0.cancel() }; session.recoveryQueue.sync {} }
        func check(_ condition: @autoclosure () -> Bool,_ label: String) { guard condition() else { fatalError(label) }; print("PASS: "+label) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        session.assets["assets/test.png"] = bitmap.representation(using:.png,properties:[:])!
        session.buffer.loadExternal("= Native PDF\n\nHello *Typst*.\n\n#table(columns: 2, [A], [B])\n\n#footnote[Native footnote]\n\n#pagebreak()\n\nSecond page.\n")
        session.revision += 1; session.compile()
        let deadline = Date().addingTimeInterval(25)
        while session.compiling && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        check(session.pdf != nil,"Official Typst compiler produces native PDF")
        let sharedFile = try! SharedPDF(data:session.pdfData!,name:session.title)
        check(sharedFile.url.pathExtension == "pdf" && sharedFile.url.lastPathComponent == session.title+".pdf","Share prepares a named PDF file without Typst source")
        check((try? Data(contentsOf:sharedFile.url)) == session.pdfData && PDFDocument(url:sharedFile.url)?.string?.contains("Native PDF") == true,"Native sharing supplies the current compiler PDF")
        check(!session.sourceMap.isEmpty,"Preview carries source navigation map")
        let good = session.pdf
        session.buffer.loadExternal("#unknown-function()")
        session.revision += 1; session.compile()
        let failureDeadline = Date().addingTimeInterval(10)
        while session.compiling && Date() < failureDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        check(session.pdf === good && session.error != nil,"Compilation errors preserve last successful PDF")
        var failedShare: Result<Data,any Error>?
        session.requestPDF { failedShare = $0 }
        let failedShareDeadline = Date().addingTimeInterval(10)
        while failedShare == nil && Date() < failedShareDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        if case .failure? = failedShare { check(session.pdf === good,"Sharing invalid source reports an error instead of sharing the previous PDF") }
        else { fatalError("Invalid source was shared as a PDF") }
        session.buffer.loadExternal("= Share snapshot\n\nPDF sharing revision check."); session.revision += 1
        var staleShare: Result<Data,any Error>?
        session.requestPDF { staleShare = $0 }; session.revision += 1
        let staleShareDeadline = Date().addingTimeInterval(10)
        while staleShare == nil && Date() < staleShareDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        if case .failure? = staleShare { check(true,"Changing source during PDF preparation rejects a stale share") }
        else { fatalError("Stale PDF revision was shared") }
        // A share requested during an older compilation must wait for its own
        // revision, provided no further edit occurs after the request.
        session.compile(); session.buffer.loadExternal("= Latest share\n\nNewest revision."); session.revision += 1
        var latestShare: Result<Data,any Error>?
        session.requestPDF { latestShare = $0 }
        let latestShareDeadline = Date().addingTimeInterval(10)
        while latestShare == nil && Date() < latestShareDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        if case let .success(data)? = latestShare { check(PDFDocument(data:data)?.string?.contains("Latest share") == true,"Share waits for its current revision behind an older compilation") }
        else { fatalError("Current PDF share did not finish behind older compilation") }
        session.buffer.loadExternal("#figure(image(\"assets/test.png\"), caption: [A caption])")
        session.revision += 1
        let exported = AppController.temporaryDirectory.appendingPathComponent("blank-export-"+UUID().uuidString+".pdf")
        session.compile(); session.compile(export:exported)
        let exportDeadline = Date().addingTimeInterval(10)
        while session.compiling && Date() < exportDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        check((try? Data(contentsOf:exported).starts(with:Data("%PDF-".utf8))) == true,"PDF export queued during compilation includes imported figure and caption")
        try? FileManager.default.removeItem(at:exported)
    }
}
