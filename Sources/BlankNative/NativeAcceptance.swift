import AppKit
import BlankCore

@MainActor enum NativeAcceptance {
    static func run() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let session = DocumentSession()
        let controller = DocumentWindow(session:session); controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        guard let view = session.editor else { fatalError("No native editor") }
        func check(_ condition: @autoclosure () -> Bool,_ label: String) { if !condition() { fatalError("FAIL: \(label) | source=\(session.buffer.source) | native=\(view.string)") }; print("PASS: \(label)") }
        check(view.textLayoutManager != nil,"TextKit 2 active at creation")
        check(controller.window?.firstResponder === view,"Empty editor is focused")
        check(view.string.isEmpty,"Launch has no welcome screen")
        for scalar in "Hello café 👩🏽‍💻".unicodeScalars { view.insertText(String(scalar),replacementRange:view.selectedRange()) }
        check(session.buffer.projection.text == "Hello café 👩🏽‍💻","Native typing and Unicode")
        view.insertNewline(nil); view.insertText("Second paragraph",replacementRange:view.selectedRange())
        check(session.buffer.projection.blocks.count == 2,"Return splits paragraph")
        view.setSelectedRange(NSRange(location:0,length:5)); view.captureSelection(); session.format(italic:false)
        check(session.buffer.source.contains("*Hello*"),"Native selection and bold")
        view.copy(nil)
        check(NSPasteboard.general.string(forType:.string) == "Hello","Write clipboard plain text")
        check(NSPasteboard.general.data(forType:NSPasteboard.PasteboardType("local.blank.typst-fragment")) != nil,"Write clipboard structured source")
        session.switchMode(.source); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        guard let sourceView = session.editor else { fatalError() }
        sourceView.selectAll(nil); sourceView.copy(nil)
        check(NSPasteboard.general.string(forType:.string) == session.buffer.source,"Source clipboard exact source")
        session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(session.editor?.textLayoutManager != nil,"TextKit 2 retained after switching")
        session.undo(); check(!session.buffer.source.contains("*Hello*"),"Undo shared across views")
        session.undo(true); check(session.buffer.source.contains("*Hello*"),"Redo shared across views")
        let editor = session.editor!
        editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0)); editor.captureSelection()
        editor.setMarkedText("に",selectedRange:NSRange(location:1,length:0),replacementRange:editor.selectedRange())
        editor.setMarkedText("日本",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        editor.insertText("日本",replacementRange:NSRange(location:NSNotFound,length:0))
        check(session.buffer.projection.text.hasSuffix("日本"),"Native marked-text composition commits once")
        check(editor.textLayoutManager != nil,"TextKit 2 retained through composition")
        print("Native acceptance completed")
        session.saveWork?.cancel(); controller.window?.close()
    }
}
