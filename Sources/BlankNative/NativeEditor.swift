import AppKit
import SwiftUI
import BlankCore

struct NativeEditor: NSViewRepresentable {
    @ObservedObject var session: DocumentSession
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.drawsBackground = true
        let view = NativeTextView(usingTextLayoutManager:true)
        view.session = session; session.editor = view
        view.delegate = view; view.isRichText = true; view.importsGraphics = false
        view.allowsUndo = false; view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = true
        view.isGrammarCheckingEnabled = false; view.usesFindBar = false
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.minSize = NSSize(width:0,height:scroll.contentSize.height)
        view.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true; view.textContainer?.heightTracksTextView = false
        view.textContainer?.lineFragmentPadding = 0
        view.frame = NSRect(x:0,y:0,width:scroll.contentSize.width,height:scroll.contentSize.height)
        view.setAccessibilityLabel("\(session.mode.rawValue) editor")
        scroll.documentView = view
        view.refresh()
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NativeTextView { view.refresh() }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) { (scroll.documentView as? NativeTextView)?.slashPopover?.close() }
}

final class NativeTextView: NSTextView, NSTextViewDelegate {
    weak var session: DocumentSession?
    var refreshing = false
    var composing = false
    var compositionOriginal = ""
    var slashPopover: NSPopover?
    var slashStart: Int?
    var slashIndex = 0
    var slashQuery = ""
    var hoverBlock: Int?
    var grabbed: Int?
    var pressPoint = NSPoint.zero
    var dragPoint = NSPoint.zero
    var dragTarget = 0
    var draggingBlock = false
    var track: NSTrackingArea?
    var lastRevision = -1
    var lastMode: EditorMode?
    var lastPath = ""
    var lastAppearance = ""
    var insertionBold = false
    var insertionItalic = false
    private var undoProxy = UndoManager()
    override var undoManager: UndoManager? { undoProxy }
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size); updatePadding()
    }
    func updatePadding() {
        guard let session else { return }
        let padding: CGFloat = session.mode == .source ? 30 : max(48,(bounds.width-720)/2)
        let inset = NSSize(width:padding,height:session.mode == .source ? 30 : 54)
        if textContainerInset != inset { textContainerInset = inset }
        textContainer?.containerSize = NSSize(width:max(80,bounds.width-padding*2),height:CGFloat.greatestFiniteMagnitude)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let track { removeTrackingArea(track) }
        track = NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(track!)
    }
    func readingFont(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let base = NSFont(name:session?.fontFamily ?? "Iowan Old Style",size:size) ?? NSFont.systemFont(ofSize:size)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }; if italic { traits.insert(.italicFontMask) }
        return traits.isEmpty ? base : NSFontManager.shared.convert(base,toHaveTrait:traits)
    }
    func rendered() -> NSAttributedString {
        guard let session else { return NSAttributedString(string:"") }
        let b = session.buffer
        let source = session.mode == .source
        let result = NSMutableAttributedString(string:source ? b.source : b.projection.text)
        let all = NSRange(location:0,length:result.length)
        let size = CGFloat(session.fontSize)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = source ? 1.45 : 1.65
        style.paragraphSpacing = source ? 0 : 23
        let font = source ? NSFont.monospacedSystemFont(ofSize:14,weight:.regular) : readingFont(size:size)
        result.addAttributes([.font:font,.foregroundColor:NSColor(session.ink),.paragraphStyle:style,.ligature:1],range:all)
        if source {
            for run in b.parsed.styles {
                let start = b.source.utf16Offset(byte:run.start), end = b.source.utf16Offset(byte:run.end)
                guard end > start, end <= result.length else { continue }
                let color: NSColor
                switch run.tag {
                case "Comment": color = NSColor(calibratedWhite:0.57,alpha:1)
                case "Keyword", "Function": color = NSColor(calibratedRed:0.40,green:0.32,blue:0.52,alpha:1)
                case "String": color = NSColor(calibratedRed:0.31,green:0.44,blue:0.36,alpha:1)
                case "Number", "MathOperator", "MathDelimiter": color = NSColor(calibratedRed:0.55,green:0.39,blue:0.29,alpha:1)
                default: continue
                }
                result.addAttribute(.foregroundColor,value:color,range:NSRange(location:start,length:end-start))
            }
            func visit(_ node: SyntaxNode, bold: Bool = false, italic: Bool = false, heading: Int = 0) {
                let strong = bold || node.kind == "Strong", emph = italic || node.kind == "Emph"
                let level = node.kind == "Heading" ? b.source.bytes(node.span).prefix { $0 == "=" }.count : heading
                if strong || emph || level > 0 {
                    var f = NSFont.monospacedSystemFont(ofSize:level == 1 ? 24 : level == 2 ? 20 : level > 0 ? 17 : 14,weight:strong || level > 0 ? .bold : .regular)
                    if emph { f = NSFontManager.shared.convert(f,toHaveTrait:.italicFontMask) }
                    let a = b.source.utf16Offset(byte:node.start), z = b.source.utf16Offset(byte:node.end)
                    if z > a { result.addAttribute(.font,value:f,range:NSRange(location:a,length:z-a)) }
                }
                node.children.forEach { visit($0,bold:strong,italic:emph,heading:level) }
            }
            visit(b.parsed.tree)
        } else {
            for (index,block) in b.projection.blocks.enumerated() {
                let p = style.mutableCopy() as! NSMutableParagraphStyle
                var textSize = size
                if block.kind == "heading" {
                    textSize = size * (block.level == 1 ? 1.89 : block.level == 2 ? 1.33 : 1.056)
                    p.lineHeightMultiple = block.level == 1 ? 1.3 : 1.4
                    p.paragraphSpacingBefore = index == 0 ? 0 : block.level == 1 ? 32 : 28
                    p.paragraphSpacing = block.level == 1 ? 23 : 18
                }
                if ["bullet","number"].contains(block.kind) { p.firstLineHeadIndent = 25; p.headIndent = 25; p.paragraphSpacing = 5 }
                if block.kind == "quote" { p.firstLineHeadIndent = 24; p.headIndent = 24 }
                let raw = !block.editable
                if raw { p.lineHeightMultiple = 1.5; p.paragraphSpacingBefore = 12; p.paragraphSpacing = 26 }
                let range = block.display
                if range.length > 0 {
                    result.addAttributes([.paragraphStyle:p,.font:raw ? NSFont.monospacedSystemFont(ofSize:13,weight:.regular) : readingFont(size:textSize,bold:block.kind == "heading",italic:block.kind == "quote")],range:range)
                    if raw { result.addAttribute(.foregroundColor,value:NSColor.secondaryLabelColor,range:range) }
                    if session.paragraphFocus && !range.contains(selectedRange().location) { result.addAttribute(.foregroundColor,value:NSColor.tertiaryLabelColor,range:range) }
                    var at = range.location
                    for run in block.inlines.flatMap(\.runs) {
                        let r = NSRange(location:at,length:run.text.utf16.count)
                        if !raw && r.length > 0 {
                            result.addAttribute(.font,value:run.style.code ? NSFont.monospacedSystemFont(ofSize:size*0.83,weight:.regular) : readingFont(size:textSize,bold:run.style.bold || block.kind == "heading",italic:run.style.italic || block.kind == "quote"),range:r)
                            if let link = run.style.link { result.addAttributes([.link:link,.foregroundColor:NSColor(calibratedRed:0.27,green:0.41,blue:0.33,alpha:1)],range:r) }
                        }
                        at += r.length
                    }
                }
            }
        }
        return result
    }
    func refresh(reveal: Bool = false) {
        guard !composing, !hasMarkedText(), let session, session.mode != .preview else { return }
        updatePadding()
        let appearance = "\(session.fontFamily)/\(session.fontSize)/\(session.paragraphFocus)/\(session.paper)/\(session.ink)"
        guard reveal || lastRevision != session.buffer.revision || lastMode != session.mode || lastPath != session.active || lastAppearance != appearance else { return }
        refreshing = true; defer { refreshing = false }
        let attributed = rendered(), old = string
        if let patch = SourcePatch.difference(old,attributed.string) {
            let a = old.utf16Offset(byte:patch.start), z = old.utf16Offset(byte:patch.start+patch.removed.utf8.count)
            textStorage?.beginEditing()
            textStorage?.replaceCharacters(in:NSRange(location:a,length:z-a),with:patch.inserted)
            textStorage?.endEditing()
        }
        if attributed.length > 0 {
            textStorage?.beginEditing()
            attributed.enumerateAttributes(in:NSRange(location:0,length:attributed.length)) { attrs,range,_ in self.textStorage?.setAttributes(attrs,range:range) }
            textStorage?.endEditing()
        }
        let selected = session.buffer.selection
        let a = session.mode == .source ? session.buffer.source.utf16Offset(byte:selected.anchor) : session.buffer.projection.displayOffset(at:selected.anchor)
        let z = session.mode == .source ? session.buffer.source.utf16Offset(byte:selected.focus) : session.buffer.projection.displayOffset(at:selected.focus)
        setSelectedRange(NSRange(location:min(a,z),length:abs(z-a)))
        typingAttributes = [.font:session.mode == .source ? NSFont.monospacedSystemFont(ofSize:14,weight:.regular) : readingFont(size:CGFloat(session.fontSize)),.foregroundColor:NSColor(session.ink),.ligature:1]
        backgroundColor = NSColor(session.paper); insertionPointColor = NSColor(session.ink)
        enclosingScrollView?.backgroundColor = backgroundColor
        lastRevision = session.buffer.revision; lastMode = session.mode; lastPath = session.active; lastAppearance = appearance
        setAccessibilityLabel("\(session.mode.rawValue) editor")
        needsDisplay = true
        if reveal { scrollRangeToVisible(selectedRange()) }
        if session.typewriter { centerSelectionInVisibleArea(self) }
        updateSlash()
    }
    func captureSelection() {
        guard !refreshing, !composing, let session else { return }
        let r = selectedRange()
        let a = session.mode == .source ? string.byteOffset(utf16:r.location) : session.buffer.projection.sourceOffset(at:r.location)
        let z = session.mode == .source ? string.byteOffset(utf16:NSMaxRange(r)) : session.buffer.projection.sourceOffset(at:NSMaxRange(r))
        session.buffer.selection = EditSelection(a,z)
    }
    func captureReadingPosition() {
        captureSelection()
        guard let session, !visibleRect.intersects(rectFor(selectedRange().location)) else { return }
        let point = NSPoint(x:textContainerInset.width+35,y:visibleRect.minY+visibleRect.height*0.35)
        let index = characterIndexForInsertion(at:point)
        let byte = session.mode == .source ? string.byteOffset(utf16:index) : session.buffer.projection.sourceOffset(at:index)
        session.buffer.selection = EditSelection(byte,byte)
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        captureSelection(); if session?.paragraphFocus == true { lastAppearance = ""; refresh() }
        if let slashStart, selectedRange().location < slashStart || selectedRange().length > 0 { dismissSlash() }
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !refreshing, let text = replacementString, let session else { return true }
        if composing || hasMarkedText() { return true }
        captureSelection()
        if session.mode == .source { session.buffer.editSource(affectedCharRange,text:text) }
        else {
            var insertion = text
            if insertionBold && !text.isEmpty { insertion = "*"+escapeTypst(insertion)+"*" }
            if insertionItalic && !text.isEmpty { insertion = "_"+escapeTypst(insertion)+"_" }
            session.buffer.editWrite(affectedCharRange,text:insertion,raw:insertionBold || insertionItalic)
        }
        session.changed(); scrollRangeToVisible(selectedRange())
        if text == "/", session.mode == .write { slashStart = selectedRange().location-1; slashIndex = 0; updateSlash() }
        applyTypingShortcut(text)
        return false
    }
    func applyTypingShortcut(_ inserted: String) {
        guard let session, session.mode == .write, inserted == " " || inserted == "*" || inserted == "_" else { return }
        let index = session.buffer.projection.blockIndex(at:selectedRange().location), b = session.buffer.projection.blocks[index]
        let shortcuts: [String:(String,Int)] = ["= ":("heading",1),"== ":("heading",2),"=== ":("heading",3),"- ":("bullet",0),"+ ":("number",0)]
        if let (kind,level) = shortcuts[b.text], b.kind == "paragraph" {
            // Typing the prefix is already part of the same typing group.
            session.buffer.editWrite(b.display,text:"",group:"write")
            session.buffer.setKind(index,kind:kind,level:level); session.changed()
        } else if inserted == "*" || inserted == "_" {
            let marker = inserted
            if b.text.hasPrefix(marker), b.text.hasSuffix(marker), b.text.utf16.count > 2 {
                let body = String(b.text.dropFirst().dropLast())
                let replacement = marker+escapeTypst(body)+marker
                let caret = b.body.start+replacement.utf8.count
                session.buffer.commit(session.buffer.source.replacingBytes(b.body,with:replacement),selection:EditSelection(caret,caret)); session.changed()
            }
        }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        if composing || hasMarkedText() {
            super.insertText(insertString,replacementRange:replacementRange); composing = false; commitComposition(); return
        }
        if session?.mode == .source, text.count == 1, let character = text.first {
            let r = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
            let pairs: [Character:Character] = ["(":")","[":"]","{":"}","\"":"\"","*":"*","_":"_","$":"$","`":"`"]
            if r.length == 0, ")] }\"*_$`".contains(character), r.location < (string as NSString).length,
               (string as NSString).substring(with:NSRange(location:r.location,length:1)) == text {
                setSelectedRange(NSRange(location:r.location+1,length:0)); captureSelection(); return
            }
            if let closer = pairs[character] {
                let selected = (string as NSString).substring(with:r)
                super.insertText(text+selected+String(closer),replacementRange:r)
                setSelectedRange(NSRange(location:r.location+1,length:selected.utf16.count)); captureSelection(); return
            }
        }
        super.insertText(insertString,replacementRange:replacementRange)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !composing { captureSelection(); compositionOriginal = self.string; composing = true; session?.buffer.breakUndoGroup() }
        super.setMarkedText(string,selectedRange:selectedRange,replacementRange:replacementRange)
    }
    override func unmarkText() { super.unmarkText(); if composing { composing = false; commitComposition() } }
    func finishComposition() { if hasMarkedText() || composing { unmarkText() } }
    func commitComposition() {
        guard let session, let patch = SourcePatch.difference(compositionOriginal,string) else { refresh(); return }
        let range = NSRange(location:compositionOriginal.utf16Offset(byte:patch.start),length:patch.removed.utf16.count)
        if session.mode == .source { session.buffer.editSource(range,text:patch.inserted,group:"") }
        else { session.buffer.editWrite(range,text:patch.inserted,group:"") }
        session.changed()
    }
    override func keyDown(with event: NSEvent) {
        if slashStart != nil {
            switch event.keyCode {
            case 53: dismissSlash(); return
            case 125: slashIndex = min(slashIndex+1,max(0,slashMatches.count-1)); showSlash(); return
            case 126: slashIndex = max(0,slashIndex-1); showSlash(); return
            case 36,76: chooseSlash(); return
            default: break
            }
        }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "z" { session?.undo(event.modifierFlags.contains(.shift)); return }
            if event.charactersIgnoringModifiers == "b" { formatNative(false); return }
            if event.charactersIgnoringModifiers == "i" { formatNative(true); return }
        }
        if event.modifierFlags.contains(.option), [125,126].contains(event.keyCode), session?.mode == .write, let session {
            let index = session.buffer.projection.blockIndex(at:selectedRange().location)
            session.buffer.moveBlock(index,before:event.keyCode == 126 ? max(0,index-1) : min(session.buffer.projection.blocks.count,index+2)); session.changed(); return
        }
        super.keyDown(with:event)
    }
    func formatNative(_ italic: Bool) {
        if selectedRange().length == 0 { if italic { insertionItalic.toggle() } else { insertionBold.toggle() }; return }
        session?.format(italic:italic)
    }
    override func insertNewline(_ sender: Any?) {
        guard let session else { return }
        finishComposition(); captureSelection()
        if session.mode == .write { session.buffer.split(selectedRange()); session.changed(); scrollRangeToVisible(selectedRange()) }
        else { super.insertNewline(sender) }
        dismissSlash()
    }
    override func copy(_ sender: Any?) {
        guard let session, selectedRange().length > 0 else { return }
        let board = NSPasteboard.general; board.clearContents()
        let plain = (string as NSString).substring(with:selectedRange())
        board.setString(plain,forType:.string)
        if session.mode == .write {
            let fragment = session.buffer.copy(selectedRange())
            if let data = try? JSONEncoder().encode(fragment) { board.setData(data,forType:NSPasteboard.PasteboardType("local.blank.typst-fragment")) }
            if let data = try? textStorage?.attributedSubstring(from:selectedRange()).data(from:NSRange(location:0,length:selectedRange().length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf]) { board.setData(data,forType:.rtf) }
        }
    }
    override func cut(_ sender: Any?) { copy(sender); insertText("",replacementRange:selectedRange()) }
    override func paste(_ sender: Any?) {
        guard let session else { return }
        let board = NSPasteboard.general
        if session.mode == .write, let data = board.data(forType:NSPasteboard.PasteboardType("local.blank.typst-fragment")), let fragment = try? JSONDecoder().decode(RichFragment.self,from:data) {
            captureSelection(); session.buffer.paste(fragment,range:selectedRange()); session.changed(); return
        }
        if session.mode == .write, let data = board.data(forType:.rtf), let rich = try? NSAttributedString(data:data,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil) {
            var source = ""
            rich.enumerateAttributes(in:NSRange(location:0,length:rich.length)) { attrs,range,_ in
                var piece = escapeTypst((rich.string as NSString).substring(with:range))
                if let font = attrs[.font] as? NSFont {
                    let traits = NSFontManager.shared.traits(of:font)
                    if traits.contains(.italicFontMask) { piece = "_"+piece+"_" }; if traits.contains(.boldFontMask) { piece = "*"+piece+"*" }
                }
                source += piece
            }
            captureSelection(); session.buffer.editWrite(selectedRange(),text:source,raw:true,group:""); session.changed(); return
        }
        if let text = board.string(forType:.string) { insertText(text,replacementRange:selectedRange()) }
    }
    @objc func blankUndo(_ sender: Any?) { session?.undo() }
    @objc func blankRedo(_ sender: Any?) { session?.undo(true) }
    @objc func blankBold(_ sender: Any?) { formatNative(false) }
    @objc func blankItalic(_ sender: Any?) { formatNative(true) }
    func rectFor(_ offset: Int) -> NSRect {
        guard window != nil else { return .zero }
        var actual = NSRange()
        let screen = firstRect(forCharacterRange:NSRange(location:min(max(0,offset),(string as NSString).length),length:0),actualRange:&actual)
        let windowRect = window!.convertFromScreen(screen)
        return convert(windowRect,from:nil)
    }
    func blockRect(_ index: Int) -> NSRect {
        guard let b = session?.buffer.projection.blocks[index] else { return .zero }
        let first = rectFor(b.display.location), last = rectFor(NSMaxRange(b.display))
        return NSRect(x:textContainerInset.width,y:first.minY,width:max(100,bounds.width-2*textContainerInset.width),height:max(first.height,last.maxY-first.minY))
    }
    override func mouseMoved(with event: NSEvent) {
        guard session?.mode == .write, grabbed == nil, let session else { return }
        let point = convert(event.locationInWindow,from:nil)
        let next = session.buffer.projection.blocks.indices.first { index in
            let rect = blockRect(index); return point.y >= rect.minY-5 && point.y < rect.maxY+5 && point.x >= textContainerInset.width-38 && point.x < bounds.width-textContainerInset.width
        }
        if next != hoverBlock { hoverBlock = next; needsDisplay = true }
        if point.x >= textContainerInset.width-35 && point.x <= textContainerInset.width-8 && next != nil { NSCursor.openHand.set() } else { NSCursor.iBeam.set() }
    }
    override func mouseExited(with event: NSEvent) { if grabbed == nil { hoverBlock = nil; needsDisplay = true } }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if let hoverBlock, point.x >= textContainerInset.width-38 && point.x <= textContainerInset.width-6 {
            grabbed = hoverBlock; pressPoint = point; dragPoint = point; draggingBlock = false; NSCursor.closedHand.push(); needsDisplay = true; return
        }
        dismissSlash(); super.mouseDown(with:event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard grabbed != nil, let session else { super.mouseDragged(with:event); return }
        dragPoint = convert(event.locationInWindow,from:nil)
        if hypot(dragPoint.x-pressPoint.x,dragPoint.y-pressPoint.y) > 4 { draggingBlock = true }
        dragTarget = session.buffer.projection.blocks.count
        for i in session.buffer.projection.blocks.indices {
            if dragPoint.y < blockRect(i).midY { dragTarget = i; break }
        }
        autoscroll(with:event); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let index = grabbed else { super.mouseUp(with:event); return }
        NSCursor.pop(); grabbed = nil; needsDisplay = true
        if draggingBlock { session?.buffer.moveBlock(index,before:dragTarget); session?.changed() }
        else { showBlockMenu(index,event:event) }
        draggingBlock = false
    }
    func showBlockMenu(_ index: Int,event: NSEvent) {
        guard let session else { return }
        let block = session.buffer.projection.blocks[index]
        let menu = NSMenu()
        if block.editable {
            let turn = NSMenuItem(title:"Turn into",action:nil,keyEquivalent:""); let submenu = NSMenu()
            for command in SlashCommand.all.prefix(6) where command.kind != block.kind || command.level != block.level {
                let item = BlockMenuItem(title:command.label,action:#selector(blockMenuAction(_:)),keyEquivalent:""); item.target = self; item.blockIndex = index; item.command = command; submenu.addItem(item)
            }
            turn.submenu = submenu; menu.addItem(turn)
        } else {
            let edit = BlockMenuItem(title:"Edit \(block.kind == "table" ? "table" : "source")…",action:#selector(blockMenuAction(_:)),keyEquivalent:""); edit.target = self; edit.blockIndex = index; edit.blockAction = "edit"; menu.addItem(edit)
        }
        for title in ["Duplicate","Delete"] {
            let item = BlockMenuItem(title:title,action:#selector(blockMenuAction(_:)),keyEquivalent:""); item.target = self; item.blockIndex = index; item.blockAction = title.lowercased(); menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    @objc func blockMenuAction(_ item: BlockMenuItem) {
        guard let session else { return }
        if let command = item.command { session.buffer.setKind(item.blockIndex,kind:command.kind,level:command.level) }
        else if item.blockAction == "edit" { session.editObject(item.blockIndex); return }
        else { session.buffer.blockAction(item.blockIndex,action:item.blockAction) }
        session.changed()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard session?.mode == .write, let session else { return }
        for (index,b) in session.buffer.projection.blocks.enumerated() where ["bullet","number"].contains(b.kind) {
            let r = rectFor(b.display.location)
            guard r.intersects(visibleRect) else { continue }
            let label = b.kind == "bullet" ? "•" : "\(listNumber(index))."
            (label as NSString).draw(at:NSPoint(x:textContainerInset.width,y:r.minY),withAttributes:[.font:readingFont(size:CGFloat(session.fontSize)),.foregroundColor:NSColor.secondaryLabelColor])
        }
        if let grabbed, draggingBlock {
            let raw = session.buffer.projection.blocks[grabbed].text
            let preview = NSAttributedString(string:raw,attributes:[.font:readingFont(size:CGFloat(session.fontSize)),.foregroundColor:NSColor.labelColor.withAlphaComponent(0.45)])
            preview.draw(in:NSRect(x:dragPoint.x+18,y:dragPoint.y+12,width:350,height:150))
            let y: CGFloat
            if dragTarget == 0 { y = blockRect(0).minY-12 }
            else if dragTarget == session.buffer.projection.blocks.count { y = blockRect(dragTarget-1).maxY+12 }
            else { y = (blockRect(dragTarget-1).maxY+blockRect(dragTarget).minY)/2 }
            NSColor.separatorColor.setFill(); NSRect(x:textContainerInset.width,y:y-1,width:max(80,bounds.width-textContainerInset.width*2),height:2).fill()
        } else if let index = grabbed ?? hoverBlock {
            let rect = rectFor(session.buffer.projection.blocks[index].display.location)
            NSColor.tertiaryLabelColor.setFill()
            for row in 0..<3 { for column in 0..<2 { NSBezierPath(ovalIn:NSRect(x:textContainerInset.width-26+CGFloat(column*5),y:rect.midY-6+CGFloat(row*5),width:2,height:2)).fill() } }
        }
    }
    func listNumber(_ index: Int) -> Int {
        guard let blocks = session?.buffer.projection.blocks else { return 1 }
        var n = 1, i = index-1
        while i >= 0 && blocks[i].kind == "number" { n += 1; i -= 1 }; return n
    }
    var slashMatches: [SlashCommand] { SlashCommand.all.filter { slashQuery.isEmpty || ($0.label+" "+$0.keywords).localizedCaseInsensitiveContains(slashQuery) } }
    func updateSlash() {
        guard let start = slashStart else { return }
        let end = selectedRange().location
        guard end >= start+1, end <= (string as NSString).length else { dismissSlash(); return }
        slashQuery = (string as NSString).substring(with:NSRange(location:start+1,length:end-start-1))
        if slashQuery.contains("\n") || slashQuery.count > 40 { dismissSlash(); return }
        slashIndex = min(slashIndex,max(0,slashMatches.count-1)); showSlash()
    }
    func showSlash() {
        if slashPopover == nil { let p = NSPopover(); p.behavior = .applicationDefined; p.animates = false; slashPopover = p }
        let choices = slashMatches, chosen = slashIndex
        let content = SlashMenu(commands:choices,index:chosen,choose:{ [weak self] index in self?.slashIndex = index; self?.chooseSlash() })
        slashPopover?.contentViewController = NSHostingController(rootView:content)
        slashPopover?.contentSize = NSSize(width:280,height:min(390,CGFloat(max(1,choices.count))*46+12))
        if slashPopover?.isShown != true { slashPopover?.show(relativeTo:rectFor(slashStart ?? selectedRange().location),of:self,preferredEdge:.maxY) }
        window?.makeFirstResponder(self)
    }
    func dismissSlash() { slashPopover?.close(); slashPopover = nil; slashStart = nil; slashQuery = "" }
    func chooseSlash() {
        guard let start = slashStart, slashMatches.indices.contains(slashIndex), let session else { return }
        let command = slashMatches[slashIndex]
        let range = NSRange(location:start,length:selectedRange().location-start)
        session.buffer.editWrite(range,text:"",group:""); dismissSlash()
        let index = session.buffer.projection.blockIndex(at:start)
        if command.insertion { session.changed(); session.chooseInsertion(command.kind) }
        else { session.buffer.setKind(index,kind:command.kind,level:command.level); session.changed() }
    }
}
final class BlockMenuItem: NSMenuItem {
    var blockIndex = 0
    var command: SlashCommand?
    var blockAction = ""
}
