import AppKit
import BlankCore
@testable import BlankNative

@MainActor enum NativeSaveFormatAcceptance {
    static func showFixture(_ controller: DocumentWindow) {
        controller.session.buffer.loadExternal("= A portable document\n\nText, images and chapters stay together.\n")
        controller.session.changed(); controller.session.saveWork?.cancel()
        try! controller.session.saveFormatted(to:AppController.temporaryDirectory.appendingPathComponent("Portable document.typz"),format:.container)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        controller.session.save(true)
    }
    static func run(_ controller: DocumentWindow) {
        let fm = FileManager.default, root = AppController.temporaryDirectory.appendingPathComponent("save-formats-"+UUID().uuidString)
        try! fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { controller.session.saveWork?.cancel(); try? fm.removeItem(at:root) }
        func check(_ condition: Bool,_ label: String) { if !condition { fatalError(label) }; print("PASS: "+label) }
        func wait(_ label: String,_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(8)
            while !condition() && Date() < end {
                for _ in 0..<32 {
                    guard let event = NSApp.nextEvent(matching:.any,until:Date(),inMode:.default,dequeue:true) else { break }
                    NSApp.sendEvent(event)
                }
                RunLoop.main.run(until:Date().addingTimeInterval(0.01))
            }
            check(condition(),label)
        }
        func descendants<T: NSView>(_ view: NSView?,_ type: T.Type) -> [T] {
            guard let view else { return [] }
            return (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0,type) }
        }
        func save(_ document: NativeDocument,to url: URL,format: DocumentFormat) {
            var done = false, failure: Error?
            document.save(to:url,ofType:format.typeName,for:.saveAsOperation) { failure = $0; done = true }
            wait("Native format save completes") { done }
            check(failure == nil,"Native format save succeeds: \(failure?.localizedDescription ?? "success")")
        }
        NSApp.activate(ignoringOtherApps:true); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        wait("Save format fixture has native focus") { NSApp.isActive && controller.window?.isKeyWindow == true }
        controller.session.buffer.loadExternal("= Café 日本\n\nNative save format test")
        controller.session.changed(); controller.session.saveWork?.cancel()
        // Inspect the real remote sheet, then verify its selected format through
        // the same NSDocument backend. Remote panel confirmation is checked with
        // computer use; synthetic NSEvents cannot confirm this system service.
        for format in [DocumentFormat.container,.folder,.document] {
            NSApp.activate(ignoringOtherApps:true); controller.window?.makeKeyAndOrderFront(nil)
            wait("The editor regains native focus before Save As") { NSApp.isActive && controller.window?.isKeyWindow == true && controller.window?.attachedSheet == nil }
            controller.session.save(true)
            wait("Save As opens a focused native sheet") { controller.window?.attachedSheet?.isKeyWindow == true }
            guard let panel = controller.window?.attachedSheet as? NSSavePanel,
                  let popup = descendants(panel.accessoryView,NSPopUpButton.self).first else { fatalError("Missing Save As format selector") }
            popup.selectItem(at:format.rawValue); _ = popup.sendAction(popup.action,to:popup.target)
            check(panel.currentContentType?.identifier == (format == .folder ? "public.directory" : format.typeName),"The native panel uses the selected content type")
            check(descendants(panel.accessoryView,NSTextField.self).contains { $0.stringValue == format.detail },"Format selector explains \(format.label)")
            let target = root.appendingPathComponent(format == .container ? "Bundle.typz" : format == .folder ? "Project" : "Single.typ")
            let selected = DocumentFormat(rawValue:popup.indexOfSelectedItem)!
            panel.cancel(nil)
            wait("Cancel returns native focus to the editor") { controller.window?.attachedSheet == nil && controller.window?.isKeyWindow == true }
            save(controller.nativeDocument,to:target,format:selected)
            wait("Native Save As adopts \(format.label)") { controller.window?.attachedSheet == nil && controller.session.documentFormat == format && !controller.session.dirty }
            check(controller.session.documentURL?.path.hasPrefix(root.path+"/") == true,"Save As writes only into disposable test data")
            check(controller.nativeDocument.fileURL == controller.session.documentURL,"Native file identity follows the selected save format")
            if format == .container, let editor = controller.session.editor {
                let original = controller.session.buffer.source
                let disk = try! Data(contentsOf:controller.session.documentURL!)
                controller.window?.makeFirstResponder(editor)
                var saved = false
                controller.nativeDocument.save(to:controller.session.documentURL!,ofType:format.typeName,for:.autosaveInPlaceOperation) { _ in saved = true }
                editor.setMarkedText("日本",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
                wait("An in-flight bundle autosave completes during composition") { saved }
                check(editor.hasMarkedText() && editor.composing,"Bundle autosave never finishes marked-text composition")
                check(controller.session.buffer.source == original && (try! Data(contentsOf:controller.session.documentURL!)) == disk,"Composition leaves canonical source and the bundle unchanged until commit")
                editor.finishComposition(); controller.session.saveWork?.cancel()
                var staleFinished = false, staleError: Error?
                controller.nativeDocument.save(to:controller.session.documentURL!,ofType:format.typeName,for:.autosaveInPlaceOperation) { staleError = $0; staleFinished = true }
                controller.session.buffer.editSource(NSRange(location:controller.session.buffer.source.utf16.count,length:0),text:"\nNewer writing")
                controller.session.changed()
                wait("Typing invalidates an in-flight bundle autosave") { staleFinished }
                check(staleError == nil && controller.session.dirty && (try! Data(contentsOf:controller.session.documentURL!)) == disk,"Stale autosave results retry quietly without writing an older revision")
                controller.session.saveWork?.cancel()
            }
        }
        // Also cover NSDocument's save panel, used by Close/Quit save review.
        let draft = DocumentSession()
        draft.entry = "chapters/main.typ"; draft.active = draft.entry; draft.draftName = "Untitled"
        draft.buffers = [draft.entry:DocumentBuffer("Native review save")]
        let window = DocumentWindow(session:draft)
        draft.changed(); draft.saveWork?.cancel()
        window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
        window.nativeDocument.saveAs(nil)
        wait("NSDocument opens its native save panel") { window.window?.attachedSheet?.isKeyWindow == true }
        guard let panel = window.window?.attachedSheet as? NSSavePanel, let popup = descendants(panel.accessoryView,NSPopUpButton.self).first else { fatalError("Missing native document format selector") }
        check((panel.nameFieldStringValue as NSString).deletingPathExtension == "Untitled","The first Save suggests Untitled rather than the template entry filename")
        popup.selectItem(at:DocumentFormat.container.rawValue); _ = popup.sendAction(popup.action,to:popup.target)
        panel.cancel(nil)
        wait("Cancel dismisses the native review save panel") { window.window?.attachedSheet == nil }
        save(window.nativeDocument,to:root.appendingPathComponent("Reviewed.typz"),format:.container)
        wait("Native document Save As produces .typz") { window.window?.attachedSheet == nil && draft.containerURL?.lastPathComponent == "Reviewed.typz" && !draft.dirty }
        window.window?.close()
        check(controller.session.error == nil,"Save formats complete without editor errors")
    }
}
