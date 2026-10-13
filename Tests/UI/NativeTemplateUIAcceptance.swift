import AppKit
import PDFKit
import BlankCore
@testable import BlankNative
@testable import BlankIntegrationTests

@MainActor enum NativeTemplateUIAcceptance {
    static func run(original: DocumentWindow,library: TemplateLibrary,chooser: TemplateGalleryWindow,starters: [DocumentTemplate]) throws -> [DocumentWindow] {
        var windows: [DocumentWindow] = []
        func check(_ value: Bool,_ label: String) { if !value { fatalError("Templates: "+label) }; print("PASS: "+label) }
        func waitForNativeUI(_ label: String,_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline {
                for _ in 0..<32 {
                    guard Date() < deadline, let event = NSApp.nextEvent(matching:.any,until:Date(),inMode:.default,dequeue:true) else { break }
                    NSApp.sendEvent(event)
                }
                RunLoop.main.run(until:Date().addingTimeInterval(0.01))
            }
            if !condition() { print("Template UI diagnostic: controllers=\(AppController.shared.controllers.count) sheet=\(chooser.window?.attachedSheet != nil) chooserVisible=\(chooser.window?.isVisible == true) selected=\(library.selection as Any) source=\(chooser.source) key=\(NSApp.keyWindow?.title as Any)") }
            check(condition(),label)
        }
        chooser.showWindow(nil); chooser.window?.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.3))
        func descendant<T: NSView>(_ view: NSView?,as type: T.Type) -> T? {
            guard let view else { return nil }; if let result = view as? T { return result }
            return view.subviews.lazy.compactMap { descendant($0,as:type) }.first
        }
        guard let grid = descendant(chooser.window?.contentView,as:TemplateGrid.self) else { fatalError("Missing native template grid") }
        check(grid.numberOfItems(inSection:0) == starters.count && grid.isSelectable && !grid.allowsMultipleSelection,"Gallery uses a native single-selection thumbnail collection")
        let firstFrame = grid.layoutAttributesForItem(at:IndexPath(item:0,section:0))!.frame
        let lastFrame = grid.layoutAttributesForItem(at:IndexPath(item:4,section:0))!.frame
        check(firstFrame.minY <= lastFrame.minY && (0..<starters.count).allSatisfy { grid.layoutAttributesForItem(at:IndexPath(item:$0,section:0))!.frame.maxX <= grid.bounds.maxX },"Starter thumbnails fit the gallery’s available width across native rows")
        check(chooser.window?.toolbar?.items.filter { $0.isBordered }.count == 4,"Template gallery uses native glass toolbar controls")
        grid.selectItems(at:[IndexPath(item:0,section:0)],scrollPosition:[]); library.selection = starters[0].id
        func key(_ code: UInt16,_ characters: String) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:chooser.window!.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
        }
        grid.keyDown(with:key(124,String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        check(library.selection == starters[1].id,"Arrow keys select templates through native collection navigation")
        grid.keyDown(with:key(49," "))
        let sheetDeadline = Date().addingTimeInterval(3)
        while chooser.window?.attachedSheet == nil && Date() < sheetDeadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        guard let sheet = chooser.window?.attachedSheet else { fatalError("Template Preview did not open") }
        check((descendant(sheet.contentView,as:PDFView.self)?.document?.pageCount ?? 0) > 1,"Space opens the complete multipage template in a native PDF preview sheet")
        let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
        _ = sheet.performKeyEquivalent(with:escape)
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        check(chooser.window?.attachedSheet == nil,"Escape dismisses template Preview and returns to the gallery")
        grid.keyDown(with:key(49," "))
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        guard let createSheet = chooser.window?.attachedSheet else { fatalError("Preview did not reopen") }
        let previousCount = AppController.shared.controllers.count
        let returnKey = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:createSheet.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        waitForNativeUI("Template Preview receives native key focus before Return") { NSApp.isActive && createSheet.isKeyWindow && NSApp.keyWindow === createSheet }
        check(createSheet.performKeyEquivalent(with:returnKey),"Template Preview consumes its native Return key")
        waitForNativeUI("Creating from Preview first dismisses its sheet and opens exactly one document") { chooser.window?.attachedSheet == nil && AppController.shared.controllers.count == previousCount+1 }
        let previewCopy = AppController.shared.controllers.last!
        windows.append(previewCopy)
        previewCopy.session.dirty = false; previewCopy.window?.close()
        chooser.showWindow(nil)
        grid.keyDown(with:key(36,"\r"))
        guard let created = AppController.shared.controllers.last, created !== original else { fatalError("Gallery Return did not create a document") }
        windows.append(created)
        let chosenSource = try library.read(starters[1]).buffer.source
        check(created.session.root == nil && created.session.dirty && created.session.buffer.source == chosenSource && chooser.window?.isVisible == false,"Return creates the chosen independent document and returns to the editor")
        created.session.dirty = false; created.window?.close()
        chooser.window?.close()
        return windows
    }
}
