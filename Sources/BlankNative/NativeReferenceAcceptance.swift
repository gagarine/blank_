import AppKit
import BlankCore

@MainActor enum NativeReferenceAcceptance {
    private static func check(_ condition: @autoclosure () -> Bool,_ label: String) {
        guard condition() else { fatalError("FAIL: \(label)") }; print("PASS: \(label)")
    }
    static func showFixture(controller: DocumentWindow) {
        let session = controller.session
        let source = "#set heading(numbering: \"1.\")\n\n= Introduction <sec:introduction>\n\nA cross-reference goes here.\n\n== Methods <sec:methods>\n\nMethods text.\n\n== Café <sec:cafe\u{301}>"
        session.buffer.loadExternal(source)
        let range = (source as NSString).range(of:"here")
        session.buffer.selection = EditSelection(source.byteOffset(utf16:range.location),source.byteOffset(utf16:NSMaxRange(range)))
        session.editor?.refresh(reveal:true)
        session.chooseInsertion("reference")
    }
    static func run(controller original: DocumentWindow) {
        let project = DocumentSession()
        project.entry = "main.typ"; project.active = "main.typ"
        project.buffers = [
            "main.typ":DocumentBuffer("= Main <main>\n#include \"chapters/one.typ\"\n#import \"/module.typ\": *\n// <comment>\n#cite(<cite-key>)\n#let name = <code-value>\n`<raw>`"),
            "chapters/one.typ":DocumentBuffer("= Chapter <chapter>\n#include \"../main.typ\"\n#table(columns:1,[Cell <cell>])\n<main>"),
            "module.typ":DocumentBuffer("#[Imported <module>]"),
            "unrelated.typ":DocumentBuffer("<unrelated>"),
            "references.bib":DocumentBuffer("<bibliography>")
        ]
        check(project.referenceLabels == ["cell","chapter","main","module"],"Reference suggestions use reachable include/import markup labels, deduplicate cycles and exclude unrelated files/code")
        project.buffers["chapters/one.typ"]!.editSource(NSRange(location:0,length:0),text:"<unsaved>\n",group:"")
        check(project.referenceLabels.contains("unsaved"),"Reference suggestions include unsaved chapter labels")
        project.buffers["module.typ"]!.editSource(NSRange(location:0,length:0),text:"<sec:café> <sec:cafe\u{301}>\n",group:"")
        let unicodeNames = project.referenceLabels.filter { $0.hasPrefix("sec:") }.map { Array($0.utf8) }
        check(unicodeNames == [Array("sec:cafe\u{301}".utf8),Array("sec:café".utf8)],"Canonically equivalent Unicode labels remain separate exact-byte suggestions")
        project.active = "unrelated.typ"
        check(project.referenceLabels.contains("unrelated") && !project.referenceLabels.contains("bibliography"),"The active document is included without suggesting bibliography files")
        check(Array(crossReferenceTarget("sec:cafe\u{301}").utf8) == Array("sec:cafe\u{301}".utf8) && crossReferenceTarget("future:日本") == "future:日本","Valid literal target names retain exact Unicode bytes")

        let session = DocumentSession(), target = "sec:cafe\u{301}"
        let source = "// Keep this comment\n= Café <\(target)>\n\nBefore | after."
        session.buffer.loadExternal(source)
        let controller = DocumentWindow(session:session)
        AppController.shared.controllers.append(controller)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        defer {
            session.sheet = nil; session.saveWork?.cancel(); session.dirty = false
            controller.nativeDocument.updateChangeCount(.changeCleared)
            controller.window?.close(); original.window?.makeKeyAndOrderFront(nil)
        }
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        guard let editor = session.editor else { fatalError("Missing reference test editor") }
        let offset = source.utf8.count-"| after.".utf8.count
        session.buffer.selection = EditSelection(offset,offset+1); editor.refresh(reveal:true)
        func combo(_ view: NSView?) -> ReferenceLabelComboBox? {
            guard let view else { return nil }
            if let box = view as? ReferenceLabelComboBox { return box }
            return view.subviews.lazy.compactMap { combo($0) }.first
        }
        func open() -> ReferenceLabelComboBox {
            session.chooseInsertion("reference")
            RunLoop.main.run(until:Date().addingTimeInterval(0.3))
            guard let box = combo(controller.window?.attachedSheet?.contentView) else {
                fatalError("FAIL: Cross reference offers a native editable list of existing labels")
            }
            return box
        }
        func key(_ input: NSTextView,_ character: String,_ keyCode: UInt16) {
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:controller.window!.attachedSheet!.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:keyCode)!
            input.keyDown(with:event)
            RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        }
        let box = open()
        check(box.objectValues as? [String] == [target] && box.isEditable && !box.completes,"Cross reference offers a native editable list without forcing autocomplete")
        guard let input = box.currentEditor() as? NSTextView else { fatalError("Reference label field is not focused") }
        check(controller.window?.attachedSheet?.firstResponder === input,"Cross reference focuses its native field editor")
        box.selectItem(at:0)
        box.comboBoxSelectionDidChange(Notification(name:NSComboBox.selectionDidChangeNotification,object:box))
        key(input,"\r",36)
        let expected = source.replacingBytes(ByteSpan(offset,offset+1),with:"#ref(<"+target+">);")
        check(session.sheet == nil && Array(session.buffer.source.utf8) == Array(expected.utf8),"Selecting an existing label and Return inserts its exact target at the Unicode source anchor")
        session.undo()
        check(session.buffer.source == source && session.buffer.selection == EditSelection(offset,offset+1),"Reference insertion Undo restores untouched source and selection")
        session.undo(true)
        check(Array(session.buffer.source.utf8) == Array(expected.utf8),"Reference insertion Redo preserves the exact target")
        session.undo()
        let cancelled = open()
        guard let cancelInput = cancelled.currentEditor() as? NSTextView else { fatalError("Missing custom target editor") }
        cancelInput.insertText("future:日本",replacementRange:cancelInput.selectedRange())
        key(cancelInput,"\u{1b}",53)
        check(session.sheet == nil && session.buffer.source == source && !session.buffer.canUndo,"Cancelling a custom target leaves source and history unchanged")
        let custom = open()
        guard let customInput = custom.currentEditor() as? NSTextView else { fatalError("Missing custom target editor") }
        customInput.insertText("future:日本",replacementRange:customInput.selectedRange())
        key(customInput,"\r",36)
        check(session.sheet == nil && session.buffer.source == source.replacingBytes(ByteSpan(offset,offset+1),with:"#ref(<future:日本>);"),"Typing an undeclared custom target and Return remains supported")
        session.undo()
        session.buffer.loadExternal("No labels yet."); editor.refresh()
        let empty = open()
        check(empty.numberOfItems == 0 && empty.isEditable,"Documents without labels still accept a custom reference")
        session.sheet = nil
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        for (name,suffix) in [("sec:end.","after"),("sec:end:","日本"),("sec:cafe\u{301}","[brackets]after")] {
            let adjacent = "// Keep\n#set heading(numbering: \"1.\")\n= Target <"+name+">\n\nBefore|"+suffix
            session.buffer.loadExternal(adjacent)
            let start = adjacent.utf8.count-suffix.utf8.count-1
            session.buffer.selection = EditSelection(start,start+1); editor.refresh(reveal:true)
            let field = open()
            guard let native = field.currentEditor() as? NSTextView else { fatalError("Missing boundary editor") }
            native.insertText(name,replacementRange:native.selectedRange()); key(native,"\r",36)
            let expected = adjacent.replacingBytes(ByteSpan(start,start+1),with:"#ref(<"+name+">);")
            check(Array(session.buffer.source.utf8) == Array(expected.utf8),"Reference insertion preserves exact punctuation/Unicode targets next to \(suffix)")
            let call = session.buffer.parsed.tree.descendants("FuncCall").first { session.buffer.source.bytes($0.span).hasPrefix("ref(") }!
            check(session.buffer.source.bytes(call.span) == "ref(<"+name+">)","Following markup is outside the generated reference call")
            session.compile()
            let deadline = Date().addingTimeInterval(10)
            while session.compiling && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
            check(session.pdf != nil && session.error == nil,"Exact punctuation/Unicode reference target compiles (\(session.error ?? "no compiler error"))")
            let pdfText = (0..<(session.pdf?.pageCount ?? 0)).compactMap { session.pdf?.page(at:$0)?.string }.joined()
            check(pdfText.contains(suffix),"Compiled reference preserves adjacent prose and brackets")
            session.undo(); check(session.buffer.source == adjacent && session.buffer.selection == EditSelection(start,start+1),"Adjacent reference Undo restores exact source and selection")
        }
        let cell = "// Keep table options\n#table(columns:1,stroke:0.5pt,[Before|[brackets]after])\n\n= Target <cell:end.>"
        session.buffer.loadExternal(cell); editor.refresh()
        editor.focusTableCell(1,0)
        editor.setSelectedRange((editor.string as NSString).range(of:"|")); editor.captureSelection()
        let cellField = open()
        guard let cellInput = cellField.currentEditor() as? NSTextView else { fatalError("Missing table reference field") }
        cellInput.insertText("cell:end.",replacementRange:cellInput.selectedRange()); key(cellInput,"\r",36)
        check(session.buffer.source == cell.replacingOccurrences(of:"|",with:"#ref(<cell:end.>);"),"Table-cell references preserve table options and adjacent bracket prose")
        session.undo(); check(session.buffer.source == cell,"Table-cell reference insertion shares exact-source Undo")
    }
}
