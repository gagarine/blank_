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
        func confirm(_ panel: NSSavePanel) {
            for type in [NSEvent.EventType.keyDown,.keyUp] {
                let event = NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:panel.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
                NSApp.sendEvent(event)
            }
        }
        NSApp.activate(ignoringOtherApps:true); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        wait("Save format fixture has native focus") { NSApp.isActive && controller.window?.isKeyWindow == true }
        controller.session.buffer.loadExternal("= Café 日本\n\nNative save format test")
        controller.session.changed(); controller.session.saveWork?.cancel()
        // Exercise the app's Save As sheet and all three destinations.
        for format in [DocumentFormat.container,.folder,.document] {
            controller.session.save(true)
            wait("Save As opens a focused native sheet") { controller.window?.attachedSheet?.isKeyWindow == true }
            guard let panel = controller.window?.attachedSheet as? NSSavePanel,
                  let popup = descendants(panel.accessoryView,NSPopUpButton.self).first else { fatalError("Missing Save As format selector") }
            popup.selectItem(at:format.rawValue); _ = popup.sendAction(popup.action,to:popup.target)
            check(descendants(panel.accessoryView,NSTextField.self).contains { $0.stringValue == format.detail },"Format selector explains \(format.label)")
            panel.directoryURL = root
            panel.nameFieldStringValue = format == .container ? "Bundle.typz" : format == .folder ? "Project" : "Single.typ"
            panel.validateVisibleColumns()
            wait("Save panel resolves the disposable destination") { panel.url?.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL }
            // Route Return through AppKit into the native remote panel service.
            confirm(panel)
            wait("Native Save As adopts \(format.label)") { controller.window?.attachedSheet == nil && controller.session.documentFormat == format && !controller.session.dirty }
            check(controller.nativeDocument.fileURL == controller.session.documentURL,"Native file identity follows the selected save format")
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
        check(panel.nameFieldStringValue == "Untitled.typ","The first Save suggests Untitled rather than the template entry filename")
        popup.selectItem(at:DocumentFormat.container.rawValue); _ = popup.sendAction(popup.action,to:popup.target)
        panel.directoryURL = root; panel.nameFieldStringValue = "Reviewed.typz"; panel.validateVisibleColumns()
        wait("Native review save resolves the disposable destination") { panel.url?.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL }
        confirm(panel)
        wait("Native document Save As produces .typz") { window.window?.attachedSheet == nil && draft.containerURL?.lastPathComponent == "Reviewed.typz" && !draft.dirty }
        window.window?.close()
        check(controller.session.error == nil,"Save formats complete without editor errors")
    }
}
