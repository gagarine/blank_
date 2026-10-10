import AppKit
import BlankCore

@MainActor enum NativeDeleteAcceptance {
    static func run(controller: DocumentWindow) {
        let session = controller.session, editor = session.editor!
        func check(_ condition: @autoclosure () -> Bool,_ label: String) {
            guard condition() else { fatalError("FAIL: \(label) | source=\(session.buffer.source) | native=\(editor.string) | selection=\(editor.selectedRange())") }
            print("PASS: \(label)")
        }
        func sourceIs(_ text: String) -> Bool { session.buffer.source.utf8.elementsEqual(text.utf8) }
        func key(_ backward: Bool, repeatKey: Bool = false) {
            let character = backward ? "\u{7f}" : "\u{f728}"
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:repeatKey,keyCode:backward ? 51 : 117)!
            editor.keyDown(with:event)
        }
        func undo(_ redo: Bool = false) {
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:redo ? [.command,.shift] : [.command],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:"z",charactersIgnoringModifiers:"z",isARepeat:false,keyCode:6)!
            editor.keyDown(with:event)
        }
        func reset(_ source: String, folded: Bool = false) {
            // Equal-source reloads intentionally retain live presentation and
            // history; start each key scenario with an independent fixture.
            session.buffer.loadExternal("")
            session.buffer.loadExternal(source); session.revision += 1; editor.refresh()
            if folded { editor.toggleCode(1) }
            controller.window?.makeFirstResponder(editor)
        }
        let prefix = "Cafe\u{301} " // Keep decomposed Unicode bytes unchanged.
        let prose = prefix+"日本👩🏽‍💻 tail"
        let objects: [(String,Bool)] = [
            ("#let value = 42\n#let other = \"日本😀\"",true),
            ("#let value = 42\n#let other = \"日本😀\"",false),
            ("#{\n  // keep this comment\n  let value = \"日本😀\"\n}",true),
            ("#{\n  // keep this comment\n  let value = \"日本😀\"\n}",false),
            ("#table(columns: 2, inset: 8pt, [日本], [], [Café], [])",false),
            (rawTypst("#let value = 42\n日本😀",block:true),false)
        ]
        for (object,folded) in objects {
            for backward in [false,true] {
                let original = prose+"\n\n"+object+"\n\n"+prose
                reset(original,folded:folded)
                let paragraph = session.buffer.projection.blocks[backward ? 2 : 0]
                let local = (paragraph.text as NSString).range(of:"日本👩🏽‍💻")
                let middle = NSRange(location:paragraph.display.location+local.location,length:local.length)
                editor.setSelectedRange(middle); editor.captureSelection(); key(backward)
                let changed = prefix+" tail"
                let afterMiddle = (backward ? prose : changed)+"\n\n"+object+"\n\n"+(backward ? changed : prose)
                check(sourceIs(afterMiddle) && editor.selectedRange() == NSRange(location:middle.location,length:0),"Native Delete removes only the middle Unicode selection (backward=\(backward), folded=\(folded))")
                for step in 0..<5 { key(backward,repeatKey:step > 0) }
                let remaining = backward ? " tail" : prefix
                let beforeBoundary = (backward ? prose : remaining)+"\n\n"+object+"\n\n"+(backward ? remaining : prose)
                check(sourceIs(beforeBoundary),"Repeated native Delete reaches the paragraph boundary with exact neighboring source")
                let block = session.buffer.projection.blocks[1], kind = block.kind
                let expectedCaret = backward ? session.buffer.projection.blocks[2].display.location : NSMaxRange(session.buffer.projection.blocks[0].display)
                check(editor.selectedRange() == NSRange(location:expectedCaret,length:0),"Repeated native Delete keeps its caret at the edited paragraph boundary")
                key(backward)
                check(sourceIs(beforeBoundary) && session.buffer.projection.blocks[1].kind == kind && session.buffer.projection.blocks[1].collapsed == folded && editor.selectedRange() == block.display,"Native Delete toward code/table selects it without changing source or block kind")
                editor.copy(nil)
                let fragment = NSPasteboard.general.data(forType:NSPasteboard.PasteboardType("local.blank.typst-fragment")).flatMap { try? JSONDecoder().decode(RichFragment.self,from:$0) }
                check(fragment?.source == object,"Boundary selection copies the complete exact Typst block")
                let selectedSource = session.buffer.selection
                key(backward)
                let deleted = (backward ? prose : remaining)+"\n\n\n\n"+(backward ? remaining : prose)
                check(sourceIs(deleted) && editor.selectedRange().length == 0,"Second native Delete removes only the selected block and leaves a caret")
                let deletedSelection = session.buffer.selection
                session.switchMode(.source); RunLoop.main.run(until:Date().addingTimeInterval(0.05))
                undo()
                check(sourceIs(beforeBoundary) && session.buffer.selection == selectedSource && editor.string == beforeBoundary,"Keyboard Undo in Source restores exact code/table bytes and the whole-block source selection")
                undo(true)
                check(sourceIs(deleted) && session.buffer.selection == deletedSelection,"Keyboard Redo in Source restores deletion and its caret")
                for _ in 0..<10 where session.buffer.source != original { undo() }
                check(sourceIs(original),"Keyboard Undo restores the original Unicode paragraph and object after repeated Delete")
                session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            }
        }
        let code = "#{\n  let value = \"日本😀\"\n}"
        let original = "Before\n\n"+code+"\n\nAfter"
        for folded in [true,false] {
            for after in [false,true] {
                for withProse in [false,true] {
                    reset(original,folded:folded)
                    let block = session.buffer.projection.blocks[1]
                    let gap = after ? NSMaxRange(block.display) : block.display.location-1
                    let selected = NSRange(location:gap-(withProse && !after ? 2 : 0),length:withProse ? 3 : 1)
                    editor.setSelectedRange(selected); editor.captureSelection(); key(after)
                    check(sourceIs(original) && session.buffer.projection.blocks[1].collapsed == folded && editor.selectedRange() == NSUnionRange(selected,block.display),"Selected code separator/tail Delete selects complete code without joining it to prose")
                    let selectedSource = session.buffer.selection
                    key(after)
                    let deleted = withProse ? (after ? "Before\n\nter" : "Befo\n\nAfter") : "Before\n\nAfter"
                    let deletedSelection = session.buffer.selection
                    check(sourceIs(deleted) && editor.selectedRange().length == 0,"Second selected-boundary Delete removes exactly the selected prose/separator/code bytes")
                    undo(); check(sourceIs(original) && session.buffer.selection == selectedSource,"Selected-boundary Delete preserves exact keyboard Undo and selection")
                    undo(true); check(sourceIs(deleted) && session.buffer.selection == deletedSelection,"Selected-boundary Delete preserves exact keyboard Redo and caret")
                    undo()
                }
            }
        }
        for folded in [false,true] {
            for backward in [false,true] {
                reset(original,folded:folded)
                let block = session.buffer.projection.blocks[1]
                editor.setSelectedRange(NSRange(location:backward ? block.display.location : NSMaxRange(block.display),length:0)); editor.captureSelection()
                key(backward)
                check(sourceIs(original) && editor.selectedRange() == block.display,"Delete outward from code selects its block before joining neighboring prose")
            }
        }
        for folded in [false,true] {
            for backward in [false,true] {
                let emptyNeighbors = "Before\n\n\n\n"+code+"\n\n\n\nAfter"
                reset(emptyNeighbors)
                let index = session.buffer.projection.blocks.firstIndex { $0.kind == "source" }!
                if folded { editor.toggleCode(index) }
                let blocks = session.buffer.projection.blocks, empty = blocks[backward ? index+1 : index-1]
                check(empty.text.isEmpty,"Code boundary regression includes a real empty paragraph")
                editor.setSelectedRange(NSRange(location:empty.display.location,length:0)); editor.captureSelection(); key(backward)
                check(sourceIs(emptyNeighbors) && editor.selectedRange() == blocks[index].display,"Delete from an empty neighboring paragraph preserves code and selects it atomically")
                reset(code)
                if folded { editor.toggleCode(0) }
                let block = session.buffer.projection.blocks[0]
                let edge = backward ? block.display.location : NSMaxRange(block.display)
                editor.setSelectedRange(NSRange(location:edge,length:0)); editor.captureSelection(); key(backward)
                check(sourceIs(code) && editor.selectedRange() == NSRange(location:edge,length:0),"Outward Delete at the document edge stays a no-op")
            }
        }
        for backward in [false,true] {
            reset("Left Café\n\n日本 right")
            let blocks = session.buffer.projection.blocks
            editor.setSelectedRange(NSRange(location:backward ? blocks[1].display.location : NSMaxRange(blocks[0].display),length:0)); editor.captureSelection(); key(backward)
            check(sourceIs("Left Café日本 right") && session.buffer.projection.blocks.count == 1,"Ordinary paragraph boundaries still join through native Delete")
            undo(); check(sourceIs("Left Café\n\n日本 right"),"Ordinary paragraph joins retain exact keyboard Undo")
        }
        reset(original)
        let inside = (editor.string as NSString).range(of:"日本😀")
        editor.setSelectedRange(inside); editor.captureSelection(); key(false)
        check(sourceIs(original.replacingOccurrences(of:"日本😀",with:"")) && session.buffer.projection.blocks[1].kind == "source","Native Delete inside expanded code retains its shell and source kind")
        undo(); check(sourceIs(original),"Expanded-code interior Delete has exact keyboard Undo")
        let shell = session.buffer.projection.blocks[1]
        editor.setSelectedRange(NSRange(location:shell.display.location+1,length:0)); editor.captureSelection(); key(true)
        check(sourceIs(original),"Native Backspace still protects the expanded code opening delimiter")
        session.switchMode(.source); RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        let separator = (editor.string as NSString).range(of:"\n\n")
        editor.setSelectedRange(separator); editor.captureSelection(); key(false)
        check(sourceIs("Before"+code+"\n\nAfter"),"Source mode permits exact-character separator deletion")
        undo(); check(sourceIs(original),"Source separator Delete retains exact keyboard Undo")
        session.switchMode(.write); RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        reset(""); editor.setSelectedRange(NSRange(location:0,length:0)); editor.captureSelection()
    }
}
