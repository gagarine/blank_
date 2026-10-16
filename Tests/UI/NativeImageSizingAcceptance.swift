import AppKit
import BlankCore
@testable import BlankNative

@MainActor enum NativeImageSizingAcceptance {
    static func showFixture(_ controller: DocumentWindow) {
        controller.session.assets["assets/original.png"] = NativeFigureAcceptance.imageData(.systemBlue)
        controller.session.buffer.loadExternal("Before café 日本.\n\n#figure(image(\"assets/original.png\"), caption: [Automatic image width])\n\nAfter.")
        controller.session.revision += 1; controller.session.editor?.refresh(reveal:true)
    }
    static func run(_ controller: DocumentWindow) {
        let session = controller.session
        NSApp.activate(ignoringOtherApps:true); controller.window?.makeKeyAndOrderFront(nil)
        showFixture(controller)
        func wait(_ label: String,_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(8)
            while !condition() && Date() < end {
                for _ in 0..<32 {
                    guard let event = NSApp.nextEvent(matching:.any,until:Date(),inMode:.default,dequeue:true) else { break }
                    NSApp.sendEvent(event)
                }
                RunLoop.main.run(until:Date().addingTimeInterval(0.01))
            }
            precondition(condition(),label); print("PASS: "+label)
        }
        wait("Image sizing fixture owns native focus") { session.editor != nil && controller.window?.isKeyWindow == true && NSApp.isActive }
        let editor = session.editor!, original = session.buffer.source
        func open() {
            editor.refresh(); editor.ensureNativeLayout(); editor.positionObjects()
            let figure = editor.objectViews.values.compactMap { $0 as? FigureBlockView }.first!
            let event = NSEvent.mouseEvent(with:.leftMouseDown,location:figure.convert(NSPoint(x:figure.bounds.midX,y:10),to:nil),modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:0,clickCount:2,pressure:1)!
            figure.mouseDown(with:event)
            wait("Double-clicking a literal image opens its image editor") { session.objectTitle == "Edit Image" && NativeFigureAcceptance.field(controller.window?.attachedSheet?.contentView,"Caption") != nil }
        }
        func apply() {
            var dismissed = false; session.pendingDocumentAction = { dismissed = true }
            let sheet = controller.window!.attachedSheet!
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
            if !sheet.performKeyEquivalent(with:event) { NSApp.sendEvent(event) }
            wait("Image Apply completes its native sheet dismissal") { dismissed && controller.window?.attachedSheet == nil }
        }
        open(); apply()
        precondition(session.buffer.source == original && !session.buffer.canUndo,"Automatic width is a lossless no-op")
        let editableOriginal = original.replacingOccurrences(of:"image(\"assets/original.png\")",with:"image(\"assets/original.png\", width: 50%)")
        session.buffer.loadExternal(editableOriginal); session.revision += 1; editor.refresh()
        open()
        wait("Custom width exposes an editable numeric field") { NativeFigureAcceptance.field(controller.window?.attachedSheet?.contentView,"Percent") != nil }
        let field = NativeFigureAcceptance.field(controller.window?.attachedSheet?.contentView,"Percent")!
        field.selectText(nil)
        let input = field.currentEditor() as! NSTextView
        input.insertText("37.5",replacementRange:input.selectedRange())
        input.insertTab(nil)
        apply()
        precondition(session.buffer.source.contains("width: 37.5%"),"Direct numeric entry writes the chosen percentage")
        editor.ensureNativeLayout(); editor.positionObjects()
        let figure = editor.objectViews.values.compactMap { $0 as? FigureBlockView }.first!
        let picture = figure.subviews.compactMap { $0 as? NSImageView }.first!
        precondition(abs(picture.frame.width-figure.bounds.width*0.375) < 1,"A local width edit updates the mounted image view immediately")
        let sized = session.buffer.source
        session.undo(); precondition(session.buffer.source == editableOriginal,"Image sizing Undo restores the prior width and surrounding Unicode")
        session.undo(true); precondition(session.buffer.source == sized,"Image sizing shares source Redo")
        let small = figureImageSize("#image(\"x\", width: 25%)",natural:NSSize(width:120,height:80),available:600)
        let large = figureImageSize("#image(\"x\", width: 75%)",natural:NSSize(width:120,height:80),available:600)
        precondition(small.width == 150 && large.width == 450 && small.height*3 == large.height,"Write image geometry follows source percentages")
        precondition(figureImageSize("#image(\"x\")",natural:NSSize(width:120,height:80),available:600).width == 120,"Automatic sizing retains natural image width")
        print("PASS: Optional, directly editable image sizing preserves geometry and shared history")
        session.saveWork?.cancel(); session.dirty = false
    }
}
