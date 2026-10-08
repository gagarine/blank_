import AppKit
import SwiftUI
import BlankCore

@MainActor enum NativeBlockSourceAcceptance {
    static func check(_ condition: @autoclosure () -> Bool,_ label: String) {
        guard condition() else { fatalError("FAIL: \(label)") }; print("PASS: \(label)")
    }
    static func run(controller original: DocumentWindow) {
        let session = DocumentSession(), controller = DocumentWindow(session:session)
        AppController.shared.controllers.append(controller)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        defer {
            session.sheet = nil; session.saveWork?.cancel(); session.dirty = false
            controller.nativeDocument.updateChangeCount(.changeCleared); controller.window?.close()
            original.window?.makeKeyAndOrderFront(nil)
        }
        let editor = session.editor!
        let prefix = "Before café 👩🏽‍💻.\n\n", suffix = "\n\nAfter 日本."
        let cases: [(String,String)] = [
            ("", "paragraph"), ("Plain *bold* text <label>","paragraph"),
            ("== Heading 日本 <heading>","heading"), ("- Bullet *text*", "bullet"),
            ("+ Numbered text", "number"), ("#quote[Quoted text]", "quote"),
            ("#table(columns: 2, inset: 8pt,\n  // Keep this comment\n  [Cell café], [日本],\n)","table"),
            ("#table(columns: custom, ..cells)","table"),
            ("#figure(image(\"assets/original.png\", width: 85%), caption: [Caption])", "image"),
            ("#figure(image(\"assets/original.png\", width: auto), caption: [*Rich*])", "image"),
            ("#bibliography(\"references.bib\", style: \"ieee\")", "bibliography"),
            ("$ x + y $", "equation"),
            ("#{\n  // Keep custom code\n  let value = \"日本\"\n  value\n}", "source")
        ]
        session.assets["assets/original.png"] = NativeFigureAcceptance.imageData(.systemBlue)
        func load(_ text: String) { session.sheet = nil; session.buffer.loadExternal(text); session.dirty = false; editor.refresh(reveal:true) }
        func index(_ kind: String,_ snippet: String) -> Int {
            guard let index = session.buffer.projection.blocks.firstIndex(where:{ $0.kind == kind && (kind != "paragraph" || snippet.isEmpty || session.buffer.source.bytes($0.source).contains(snippet)) }) else { fatalError("Missing \(kind) fixture: \(session.buffer.source)") }
            return index
        }
        func rawItem(_ menu: NSMenu) -> NSMenuItem {
            let items = menu.items.filter { $0.title == "Edit source…" }
            check(items.count == 1,"Every handle has exactly one Edit source action")
            return items[0]
        }
        func show(_ index: Int) {
            let event = NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0)!
            editor.showBlockMenu(index,event:event)
        }
        func open(_ index: Int) -> (BlockActionMenu,NSMenuItem) {
            show(index)
            guard let view = (editor.blockPopover?.contentViewController as? NSHostingController<BlockActionMenu>)?.rootView else { fatalError("Missing actual handle popover") }
            let item = view.items.first { $0.item.title == "Edit source…" }!.item
            return (view,item)
        }
        func choose(_ index: Int) { let (view,item) = open(index); view.choose(item) }
        for (snippet,kind) in cases {
            load(snippet.isEmpty ? "" : prefix+snippet+suffix)
            let at = index(kind,snippet), block = session.buffer.projection.blocks[at]
            let menu = editor.makeBlockMenu(at); _ = rawItem(menu)
            let titles = menu.items.map(\.title)
            check(titles.contains("Duplicate") && titles.contains("Delete"),"Source access retains block operations for \(kind)")
            if block.editable { check(titles.contains("Turn into"),"Source access retains Turn into for \(kind)") }
            if kind == "table" && !block.cellRanges.isEmpty { check(titles.contains("Row") && titles.contains("Column"),"Source access retains native table controls") }
            if kind == "image" && FigureFieldEdit(session.buffer.source.bytes(block.source)) != nil { check(titles.contains("Edit image…"),"Literal figures retain semantic Edit image") }
            if kind == "table" && block.cellRanges.isEmpty { check(titles.contains("Edit table…"),"Unsupported tables retain their existing edit action") }
            let source = session.buffer.source, revision = session.buffer.revision, selection = session.buffer.selection
            choose(at)
            check(session.sheet == .object && session.objectTitle == "Edit source" && session.objectOriginal.utf8.elementsEqual(source.bytes(block.source).utf8),"Actual \(kind) handle dispatch opens exact canonical block source")
            check(session.buffer.source == source && session.buffer.revision == revision && session.buffer.selection == selection && !session.buffer.canUndo && !session.dirty,"Opening source leaves source/history/selection/dirty state unchanged")
            check(session.applyObjectSource(session.objectOriginal) && session.buffer.source == source && !session.buffer.canUndo && !session.dirty,"Unchanged Apply is a no-op for \(kind)")
        }
        for kind in ["heading","table","image","source"] {
            let snippet = cases.first { $0.1 == kind }!.0, source = prefix+snippet+suffix
            load(source); let at = index(kind,snippet)
            if kind == "source" {
                editor.toggleCode(at); check(session.buffer.projection.blocks[at].collapsed,"Source fixture is folded")
                let foldedMenu = editor.makeBlockMenu(at); _ = rawItem(foldedMenu)
                check(foldedMenu.items.contains { $0.title == "Expand code" },"Folded source keeps its disclosure action")
            }
            choose(at)
            let span = session.objectSpan, changed = session.objectOriginal+" // Edited 日本 👩🏽‍💻"
            let beforeSelection = session.buffer.selection
            check(session.applyObjectSource(changed) && session.buffer.source.utf8.elementsEqual(source.replacingBytes(span,with:changed).utf8),"\(kind) source Apply preserves every unaffected Unicode byte")
            let afterSelection = session.buffer.selection
            check(afterSelection == EditSelection(span.start,span.start+changed.utf8.count),"Raw source edit selects its canonical changed range")
            session.switchMode(.source); session.undo()
            check(session.buffer.source.utf8.elementsEqual(source.utf8) && session.buffer.selection == beforeSelection,"Source Undo restores exact \(kind) bytes and selection")
            session.undo(true)
            check(session.buffer.source == source.replacingBytes(span,with:changed) && session.buffer.selection == afterSelection,"Source Redo restores \(kind) edit and selection")
            session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1)); session.undo()
            check(session.buffer.source == source,"Write shares source-edit history for \(kind)")
        }
        load(prefix+"== Heading"+suffix)
        var at = index("heading","== Heading")
        choose(at); session.sheet = nil
        check(!session.buffer.canUndo && !session.dirty,"Cancel leaves block source and history unchanged")
        choose(at); session.buffer.editSource(NSRange(location:0,length:0),text:"Intervening 日本\n",group:"")
        let intervening = session.buffer.source
        check(!session.applyObjectSource("Wrong block") && session.buffer.source == intervening,"Stale source sheet rejects an intervening revision")
        session.sheet = nil; session.error = nil
        load(prefix+"== Heading"+suffix); at = index("heading","== Heading")
        var pending = open(at)
        session.buffer.editSource(NSRange(location:0,length:0),text:"Intervening\n",group:""); pending.0.choose(pending.1)
        check(session.sheet == nil,"Stale handle menu cannot open a different block")
        editor.refresh(); let fresh = open(index("heading","== Heading"))
        pending.0.choose(pending.1)
        check(session.sheet == nil,"An old menu cannot borrow a newly opened menu's revision")
        fresh.0.choose(NSMenuItem())
        load(prefix+"== Heading"+suffix); at = index("heading","== Heading")
        pending = open(at); session.switchMode(.source); pending.0.choose(pending.1)
        check(session.sheet == nil,"Source view invalidates an open Write handle menu")
        session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        let path = session.active
        pending = open(at); session.buffers["other.typ"] = DocumentBuffer("Other file"); session.active = "other.typ"; pending.0.choose(pending.1)
        check(session.sheet == nil && session.buffer.source == "Other file","File switching invalidates an open handle menu")
        session.active = path; editor.refresh(reveal:true); choose(at)
        session.active = "other.typ"
        check(!session.applyObjectSource("Wrong file") && session.buffer.source == "Other file","A source sheet cannot apply to another file")
        session.sheet = nil; session.error = nil; session.active = path
        load(prefix+"== Heading"+suffix); at = index("heading","== Heading")
        editor.setSelectedRange(NSRange(location:0,length:0)); editor.captureSelection()
        editor.setMarkedText("日本\n\n",selectedRange:NSRange(location:4,length:0),replacementRange:editor.selectedRange())
        show(at)
        check(!editor.hasMarkedText() && index("heading","== Heading") != at,"Committing multiline composition changes the former heading index")
        check(editor.blockPopover?.isShown != true && session.sheet == nil,"Composition invalidating a handle index requires a fresh click")
        pending = open(index("heading","== Heading")); pending.0.choose(pending.1)
        check(session.objectOriginal == session.buffer.source.bytes(session.buffer.projection.blocks[index("heading","== Heading")].source) && session.objectTitle == "Edit source","The menu targets the post-composition heading span")
        session.sheet = nil
        pending = open(index("heading","== Heading"))
        editor.setSelectedRange(NSRange(location:0,length:0)); editor.captureSelection()
        editor.setMarkedText("追記",selectedRange:NSRange(location:2,length:0),replacementRange:editor.selectedRange())
        pending.0.choose(pending.1)
        check(!editor.hasMarkedText() && session.sheet == nil,"Composition completed at selection invalidates a stale menu snapshot")
    }
}
