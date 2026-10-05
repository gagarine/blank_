import AppKit
import SwiftUI
import BlankCore

struct NativeEditor: NSViewRepresentable {
    @ObservedObject var session: DocumentSession
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.drawsBackground = true
        // Choose TextKit 1 at creation: NSTextTable requires its layout engine.
        let view = NativeTextView(usingTextLayoutManager:false)
        view.session = session; session.editor = view
        view.delegate = view; view.isRichText = true; view.importsGraphics = false
        view.allowsUndo = false; view.usesFindBar = false
        view.inputDefaults = NativeInputDefaults(view)
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.minSize = NSSize(width:0,height:scroll.contentSize.height)
        view.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true; view.textContainer?.heightTracksTextView = false
        view.textContainer?.lineFragmentPadding = 0
        view.frame = NSRect(x:0,y:0,width:scroll.contentSize.width,height:scroll.contentSize.height)
        view.setAccessibilityLabel("\(session.mode.rawValue) editor")
        view.registerForDraggedTypes([.fileURL,.png,.tiff])
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

struct NativeInputDefaults {
    var quotes: Bool, dashes: Bool, replacements: Bool, correction: Bool, spelling: Bool, grammar: Bool
    init(_ view: NSTextView) {
        quotes = view.isAutomaticQuoteSubstitutionEnabled; dashes = view.isAutomaticDashSubstitutionEnabled
        replacements = view.isAutomaticTextReplacementEnabled; correction = view.isAutomaticSpellingCorrectionEnabled
        spelling = view.isContinuousSpellCheckingEnabled; grammar = view.isGrammarCheckingEnabled
    }
    func apply(to view: NSTextView,source: Bool) {
        view.isAutomaticQuoteSubstitutionEnabled = !source && quotes; view.isAutomaticDashSubstitutionEnabled = !source && dashes
        view.isAutomaticTextReplacementEnabled = !source && replacements; view.isAutomaticSpellingCorrectionEnabled = !source && correction
        view.isContinuousSpellCheckingEnabled = !source && spelling; view.isGrammarCheckingEnabled = !source && grammar
    }
}
final class NativeTextView: NSTextView, NSTextViewDelegate {
    var inputDefaults: NativeInputDefaults?
    weak var session: DocumentSession?
    var refreshing = false
    var composing = false
    var compositionOriginal = ""
    var slashPopover: NSPopover?
    var slashStart: Int?
    var slashIndex = 0
    var slashQuery = ""
    var plainSlashQuery = false
    var hoverBlock: Int?
    var grabbed: Int?
    var pressPoint = NSPoint.zero
    var dragPoint = NSPoint.zero
    var dragTarget = 0
    var draggingBlock = false
    var dragImage: NSImage?
    var track: NSTrackingArea?
    var lastPresentationRevision = -1
    var codeButtons: [Int:CodeDisclosureButton] = [:]
    var tableButtons: [TableActionButton] = []
    var tableControlCell: (Int,Int)?
    var lastRevision = -1
    var lastMode: EditorMode?
    var lastPath = ""
    var lastAppearance = ""
    var objectViews: [Int:NSView] = [:]
    var positioningObjects = false
    var fontCache: [String:NSFont] = [:]
    var insertionBold: Bool?
    var insertionItalic: Bool?
    private var undoProxy = UndoManager()
    override var undoManager: UndoManager? { undoProxy }
    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren() ?? []
        // NSTextView exposes text rather than its overlay subviews by default.
        // Include the native controls so assistive tools can reach their menus.
        let controls: [NSView] = tableButtons.filter { !$0.isHidden } + codeButtons.values.filter { !$0.isHidden }
        return children + controls.filter { control in !children.contains { ($0 as? NSView) === control } }
    }
    override func setFrameSize(_ size: NSSize) {
        let changedWidth = abs(size.width-frame.width) > 1
        super.setFrameSize(size); updatePadding()
        if changedWidth, lastRevision >= 0 { lastRevision = -1; DispatchQueue.main.async { [weak self] in self?.refresh() } }
    }
    func updatePadding() {
        guard let session else { return }
        let padding = EditorLayout.textPadding(width:bounds.width,mode:session.mode)
        let inset = NSSize(width:padding,height:session.mode == .source ? 30 : 54)
        if textContainerInset != inset { textContainerInset = inset }
        textContainer?.containerSize = NSSize(width:max(80,bounds.width-padding*2),height:CGFloat.greatestFiniteMagnitude)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lastAppearance = ""
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let panel = session?.contentsCursorView, panel.window === window,
              !panel.isHiddenOrHasHiddenAncestor else { return }
        let covered = convert(panel.visibleRect,from:panel).intersection(visibleRect)
        guard !covered.isEmpty else { return }
        // NSTextView's full I-beam rect must not overlap floating native controls.
        discardCursorRects()
        let r = visibleRect
        for rect in [NSRect(x:r.minX,y:r.minY,width:r.width,height:covered.minY-r.minY),
                     NSRect(x:r.minX,y:covered.maxY,width:r.width,height:r.maxY-covered.maxY),
                     NSRect(x:r.minX,y:covered.minY,width:covered.minX-r.minX,height:covered.height),
                     NSRect(x:covered.maxX,y:covered.minY,width:r.maxX-covered.maxX,height:covered.height)] where !rect.isEmpty {
            addCursorRect(rect,cursor:.iBeam)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let track { removeTrackingArea(track) }
        track = NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.cursorUpdate,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(track!)
    }
    func readingFont(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let key = "\(session?.fontFamily ?? "System")/\(size)/\(bold)/\(italic)"
        if let cached = fontCache[key] { return cached }
        let family = session?.fontFamily ?? "System"
        let base = family == "System" ? NSFont.systemFont(ofSize:size) : NSFontManager.shared.font(withFamily:family,traits:[],weight:5,size:size) ?? NSFont.systemFont(ofSize:size)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }; if italic { traits.insert(.italicFontMask) }
        let font = traits.isEmpty ? base : NSFontManager.shared.convert(base,toHaveTrait:traits)
        if fontCache.count > 100 { fontCache.removeAll() }
        fontCache[key] = font; return font
    }
    func rendered(onlyBlock: Int? = nil) -> NSAttributedString {
        guard let session else { return NSAttributedString(string:"") }
        let b = session.buffer
        let source = session.mode == .source
        let result = NSMutableAttributedString(string:source ? b.source : b.projection.text)
        let all = NSRange(location:0,length:result.length)
        let size = CGFloat(session.fontSize)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1
        style.lineSpacing = source ? 4 : size * 0.3
        style.paragraphSpacing = source ? 0 : 18
        let font = source ? NSFont.monospacedSystemFont(ofSize:14,weight:.regular) : readingFont(size:size)
        let baseRange = onlyBlock.map { b.projection.blocks[$0].display } ?? all
        result.addAttributes([.font:font,.foregroundColor:session.inkColor,.paragraphStyle:style,.ligature:1],range:baseRange)
        if source {
            for run in b.parsed.styles {
                let start = b.source.utf16Offset(byte:run.start), end = b.source.utf16Offset(byte:run.end)
                guard end > start, end <= result.length else { continue }
                let color: NSColor
                switch run.tag {
                case "Comment": color = NSColor.secondaryLabelColor
                case "Keyword", "Function": color = NSColor.systemPurple
                case "String": color = NSColor.systemGreen
                case "Number", "MathOperator", "MathDelimiter": color = NSColor.systemOrange
                default: continue
                }
                result.addAttribute(.foregroundColor,value:color,range:NSRange(location:start,length:end-start))
            }
            func visit(_ node: SyntaxNode, bold: Bool = false, italic: Bool = false, heading: Int = 0) {
                let function = node.kind == "FuncCall" ? node.children.first.map { b.source.bytes($0.span) } : nil
                let strong = bold || node.kind == "Strong" || function == "strong", emph = italic || node.kind == "Emph" || function == "emph"
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
                if let onlyBlock, index != onlyBlock { continue }
                if !block.cellRanges.isEmpty {
                    renderTable(block,in:result,size:size)
                    continue
                }
                let p = style.mutableCopy() as! NSMutableParagraphStyle
                var textSize = size
                if block.kind == "heading" {
                    textSize = size * (block.level == 1 ? 1.89 : block.level == 2 ? 1.33 : 1.056)
                    p.lineSpacing = 2
                    p.paragraphSpacingBefore = index == 0 ? 0 : block.level == 1 ? 14 : 10
                }
                if ["bullet","number"].contains(block.kind) { p.firstLineHeadIndent = 25; p.headIndent = 25; p.paragraphSpacing = 5 }
                if block.kind == "quote" { p.firstLineHeadIndent = 24; p.headIndent = 24 }
                let raw = !block.editable
                if raw { p.lineSpacing = 4; p.paragraphSpacing = 12 }
                if block.collapsed { p.lineBreakMode = .byTruncatingTail }
                let range = block.display
                // Include the paragraph terminator: an empty next paragraph has
                // no glyphs from which TextKit can recover its preceding spacing.
                let paragraphRange = NSRange(location:range.location,length:range.length+(index+1 < b.projection.blocks.count ? 1 : 0))
                if paragraphRange.length > 0 { result.addAttribute(.paragraphStyle,value:p,range:paragraphRange) }
                if range.length > 0 {
                    result.addAttributes([.paragraphStyle:p,.font:raw ? NSFont.monospacedSystemFont(ofSize:13,weight:.regular) : readingFont(size:textSize,bold:block.kind == "heading",italic:block.kind == "quote")],range:range)
                    if raw { result.addAttribute(.foregroundColor,value:session.inkColor.withAlphaComponent(0.65),range:range) }
                    if block.text == "\u{FFFC}" {
                        let attachment = ObjectAttachment(editor:self,index:index,width:max(160,bounds.width-textContainerInset.width*2))
                        result.addAttribute(.attachment,value:attachment,range:range)
                        result.addAttribute(.baselineOffset,value:0,range:range)
                    }
                    if session.paragraphFocus && !range.contains(selectedRange().location) { result.addAttribute(.foregroundColor,value:NSColor.tertiaryLabelColor,range:range) }
                    var at = range.location
                    for run in block.inlines.flatMap(\.runs) {
                        let r = NSRange(location:at,length:run.text.utf16.count)
                        if !raw && r.length > 0 {
                            result.addAttribute(.font,value:run.style.code ? NSFont.monospacedSystemFont(ofSize:size*0.83,weight:.regular) : readingFont(size:textSize,bold:run.style.bold || block.kind == "heading",italic:run.style.italic || block.kind == "quote"),range:r)
                            if let link = run.style.link { result.addAttributes([.link:link,.foregroundColor:NSColor.linkColor],range:r) }
                        }
                        at += r.length
                    }
                }
            }
        }
        if !source, plainSlashQuery, let start = slashStart, start < result.length {
            let end = max(start,min(b.projection.displayOffset(at:b.selection.focus),result.length))
            let range = NSRange(location:start,length:end-start)
            if range.length > 0 {
                result.addAttributes([.font:readingFont(size:size),.foregroundColor:session.inkColor],range:range)
                result.removeAttribute(.link,range:range)
            }
        }
        return result
    }
    private func renderTable(_ block: ProjectedBlock,in result: NSMutableAttributedString,size: CGFloat) {
        guard let session else { return }
        let table = NSTextTable(); table.numberOfColumns = block.columns
        table.collapsesBorders = true; table.hidesEmptyCells = false
        // NSTextTable's width is its content width; allow its outer cell padding
        // and border inside the text container so the right border is visible.
        table.setValue(max(80,(textContainer?.containerSize.width ?? 720)-21),type:.absoluteValueType,for:.width)
        for (index,cell) in block.cellRanges.enumerated() {
            let native = NSTextTableBlock(table:table,startingRow:index/block.columns,rowSpan:1,startingColumn:index%block.columns,columnSpan:1)
            native.setValue(100/CGFloat(block.columns),type:.percentageValueType,for:.width)
            native.setWidth(0.5,type:.absoluteValueType,for:.border)
            native.setBorderColor(session.systemColors ? .separatorColor : session.inkColor.withAlphaComponent(0.22))
            native.setWidth(10,type:.absoluteValueType,for:.padding)
            let style = NSMutableParagraphStyle(); style.textBlocks = [native]
            style.lineSpacing = 3; style.paragraphSpacing = 8
            let range = NSRange(location:block.display.location+cell.location,length:cell.length+1)
            result.addAttributes([.paragraphStyle:style,.font:readingFont(size:size*0.85,bold:index < block.columns),.foregroundColor:session.inkColor],range:range)
            for part in block.cellProjections[index].blocks {
                var at = range.location+part.display.location
                for run in part.inlines.flatMap(\.runs) {
                    let r = NSRange(location:at,length:run.text.utf16.count)
                    if r.length > 0 {
                        result.addAttribute(.font,value:run.style.code ? NSFont.monospacedSystemFont(ofSize:size*0.8,weight:.regular) : readingFont(size:size*0.85,bold:run.style.bold || index < block.columns,italic:run.style.italic),range:r)
                        if let link = run.style.link { result.addAttributes([.link:link,.foregroundColor:NSColor.linkColor],range:r) }
                    }
                    at += r.length
                }
            }
        }
    }
    func ensureNativeLayout() {
        guard let textContainer else { return }
        layoutManager?.ensureLayout(forBoundingRect:visibleRect.offsetBy(dx:-textContainerOrigin.x,dy:-textContainerOrigin.y),in:textContainer)
    }
    func refresh(reveal: Bool = false) {
        effectiveAppearance.performAsCurrentDrawingAppearance { refreshContent(reveal:reveal) }
    }
    private func refreshContent(reveal: Bool) {
        guard !composing, !hasMarkedText(), let session, session.mode != .preview else { return }
        if reveal && session.mode == .write {
            let selection = session.buffer.selection
            let hidden = session.buffer.projection.blocks.indices.filter { index in
                let block = session.buffer.projection.blocks[index]
                return block.collapsed && (selection.anchor > block.source.start && selection.anchor < block.source.end || selection.focus > block.source.start && selection.focus < block.source.end)
            }
            for index in hidden { session.buffer.setSourceCollapsed(index,false) }
        }
        updatePadding()
        let appearance = "\(effectiveAppearance.name.rawValue)/\(session.systemColors)/\(session.fontFamily)/\(session.fontSize)/\(session.paragraphFocus)/\(session.paper)/\(session.ink)"
        guard reveal || lastPresentationRevision != session.buffer.presentationRevision || lastRevision != session.buffer.revision || lastMode != session.mode || lastPath != session.active || lastAppearance != appearance else { return }
        if lastMode != session.mode {
            if lastMode == .write { inputDefaults = NativeInputDefaults(self) }
            inputDefaults?.apply(to:self,source:session.mode == .source)
        }
        refreshing = true; defer { refreshing = false }
        let local = session.mode == .write && lastMode == .write && lastPath == session.active && lastAppearance == appearance && lastRevision == session.buffer.revision-1 && session.buffer.lastEditWasLocal
        let localIndex = local ? session.buffer.projection.blockIndex(at:session.buffer.projection.displayOffset(at:session.buffer.selection.focus)) : nil
        if !local { objectViews.values.forEach { $0.removeFromSuperview() }; objectViews.removeAll() }
        let attributed = rendered(onlyBlock:localIndex), old = string
        let displayPatch = SourcePatch.difference(old,attributed.string)
        if let patch = displayPatch {
            let start = old.utf16Offset(byte:patch.start)
            let end = old.utf16Offset(byte:patch.start+patch.removed.utf8.count)
            // Keep AppKit's selection and input state in the same edit lifecycle
            // as a native keystroke, even when the source model owns the edit.
            _ = shouldChangeText(in:NSRange(location:start,length:end-start),replacementString:patch.inserted)
        }
        var textChanged = false
        // Insert text and attributes in one storage transaction. An attachment
        // character inserted without its attachment can be laid out as plain text.
        textStorage?.beginEditing()
        if let patch = displayPatch {
            textChanged = true
            let a = old.utf16Offset(byte:patch.start), z = old.utf16Offset(byte:patch.start+patch.removed.utf8.count)
            let start = attributed.string.utf16Offset(byte:patch.start)
            let replacement = attributed.attributedSubstring(from:NSRange(location:start,length:patch.inserted.utf16.count))
            textStorage?.replaceCharacters(in:NSRange(location:a,length:z-a),with:replacement)
        }
        if attributed.length > 0 {
            let range = localIndex.map { session.buffer.projection.blocks[$0].display } ?? NSRange(location:0,length:attributed.length)
            attributed.enumerateAttributes(in:range) { attrs,range,_ in self.textStorage?.setAttributes(attrs,range:range) }
        }
        textStorage?.endEditing()
        if textChanged { didChangeText() }
        if !local {
            layoutManager?.invalidateLayout(forCharacterRange:NSRange(location:0,length:string.utf16.count),actualCharacterRange:nil)
            ensureNativeLayout()
        }
        let selected = session.buffer.selection
        let a = session.mode == .source ? session.buffer.source.utf16Offset(byte:selected.anchor) : session.buffer.projection.displayOffset(at:selected.anchor)
        let z = session.mode == .source ? session.buffer.source.utf16Offset(byte:selected.focus) : session.buffer.projection.displayOffset(at:selected.focus)
        setSelectedRange(NSRange(location:min(a,z),length:abs(z-a)))
        typingAttributes = [.font:session.mode == .source ? NSFont.monospacedSystemFont(ofSize:14,weight:.regular) : readingFont(size:CGFloat(session.fontSize)),.foregroundColor:session.inkColor,.ligature:1]
        backgroundColor = session.paperColor; insertionPointColor = session.systemColors ? .textInsertionPointColor : session.inkColor
        enclosingScrollView?.backgroundColor = backgroundColor
        lastPresentationRevision = session.buffer.presentationRevision
        lastRevision = session.buffer.revision; lastMode = session.mode; lastPath = session.active; lastAppearance = appearance
        setAccessibilityLabel("\(session.mode.rawValue) editor")
        needsDisplay = true
        if reveal { scrollRangeToVisible(selectedRange()) }
        if session.typewriter { centerSelectionInVisibleArea(self) }
        updateSlash()
        positionObjects(); positionCodeControls(); positionTableControls()
        // Restart AppKit's insertion point after layout and the final selection.
        updateInsertionPointStateAndRestartTimer(true)
        // keyDown can finish its own insertion-point bookkeeping after the
        // command returns. Reconcile on the next main-loop turn, using the
        // current selection so later keys and composition are never overwritten.
        if textChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder === self, !self.hasMarkedText() else { return }
                self.updateInsertionPointStateAndRestartTimer(true)
            }
        }
    }
    override func layout() { super.layout(); positionObjects(); positionCodeControls() }
    func positionObjects() {
        guard !positioningObjects, let session, session.mode == .write, window != nil else { return }
        positioningObjects = true; defer { positioningObjects = false }
        var visible = Set<Int>()
        for (index,block) in session.buffer.projection.blocks.enumerated() where block.text == "\u{FFFC}" {
            guard let attachment = textStorage?.attribute(.attachment,at:block.display.location,effectiveRange:nil) as? ObjectAttachment else { continue }
            let rect = rectFor(block.display.location)
            let frame = NSRect(x:textContainerInset.width,y:rect.minY,width:attachment.width,height:attachment.height)
            guard frame.intersects(visibleRect.insetBy(dx:0,dy:-120)) else { continue }
            visible.insert(index)
            if objectViews[index] == nil {
                let view = FigureBlockView(editor:self,index:index,frame:frame)
                objectViews[index] = view; addSubview(view)
            }
            objectViews[index]?.frame = frame
        }
        for index in Array(objectViews.keys) where !visible.contains(index) { objectViews.removeValue(forKey:index)?.removeFromSuperview() }
    }
    func captureSelection() {
        guard !refreshing, !composing, let session else { return }
        let r = selectedRange()
        if session.mode == .write {
            let old = session.buffer.selection, projection = session.buffer.projection
            if projection.displayOffset(at:old.anchor) == r.location && projection.displayOffset(at:old.focus) == NSMaxRange(r) { return }
            insertionBold = nil; insertionItalic = nil
        }
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
    func textView(_ textView: NSTextView,willChangeSelectionFromCharacterRange old: NSRange,toCharacterRange proposed: NSRange) -> NSRange {
        guard !refreshing, let session, session.mode == .write else { return proposed }
        var result = proposed
        for block in session.buffer.projection.blocks where block.collapsed {
            if result.length == 0 && result.location > block.display.location && result.location < NSMaxRange(block.display) {
                result.location = result.location > old.location ? NSMaxRange(block.display) : block.display.location
            } else if result.length > 0 && NSIntersectionRange(result,block.display).length > 0 { result = NSUnionRange(result,block.display) }
        }
        return result
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        captureSelection(); if session?.paragraphFocus == true { lastAppearance = ""; refresh() }
        if !refreshing, session?.mode == .write {
            tableControlCell = session?.buffer.projection.tableCell(at:selectedRange()).map { ($0.block,$0.cell) }
            positionTableControls()
        }
        if let slashStart, selectedRange().location < slashStart || selectedRange().length > 0 { dismissSlash() }
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !refreshing, let text = replacementString, let session else { return true }
        if composing || hasMarkedText() { return true }
        captureSelection()
        var editRange = affectedCharRange
        let block = session.buffer.projection.blocks[session.buffer.projection.blockIndex(at:editRange.location)]
        let emptyingBlock = session.mode == .write && block.editable && text.isEmpty && editRange.length > 0 && editRange == block.display
        let startsPlainSlash = session.mode == .write && text == "/" && block.editable && (block.text.isEmpty || editRange == block.display)
        if startsPlainSlash { insertionBold = nil; insertionItalic = nil; session.buffer.breakUndoGroup() }
        if session.mode == .write {
            let folded = session.buffer.projection.blocks.indices.filter { session.buffer.projection.blocks[$0].collapsed && NSIntersectionRange(session.buffer.projection.blocks[$0].display,NSRange(location:affectedCharRange.location,length:max(1,affectedCharRange.length))).length > 0 }
            // A folded summary is one atomic block, including boundary deletes.
            if editRange.length > 0 {
                for index in folded { editRange = NSUnionRange(editRange,session.buffer.projection.blocks[index].display) }
            }
            let a = session.buffer.projection.sourceOffset(at:editRange.location), z = session.buffer.projection.sourceOffset(at:NSMaxRange(editRange))
            for index in folded { session.buffer.setSourceCollapsed(index,false) }
            if !folded.isEmpty { refresh(); let start = session.buffer.projection.displayOffset(at:a), end = session.buffer.projection.displayOffset(at:z); editRange = NSRange(location:start,length:end-start) }
        }
        if session.mode == .source { session.buffer.editSource(editRange,text:text) }
        else {
            var style = caretStyle()
            if let insertionBold { style.bold = insertionBold }; if let insertionItalic { style.italic = insertionItalic }
            session.buffer.editWrite(editRange,text:text,styleOverride:startsPlainSlash ? TextStyle() : insertionBold != nil || insertionItalic != nil ? style : nil)
        }
        if emptyingBlock { insertionBold = nil; insertionItalic = nil }
        session.changed(); scrollRangeToVisible(selectedRange())
        if text == "/", session.mode == .write {
            slashStart = selectedRange().location-1; slashIndex = 0; plainSlashQuery = startsPlainSlash
            if plainSlashQuery { lastRevision = -1; refresh() }
            updateSlash()
        }
        applyTypingShortcut(text)
        return false
    }
    func applyTypingShortcut(_ inserted: String) {
        guard let session, session.mode == .write, inserted == " " || inserted == "*" || inserted == "_" else { return }
        let index = session.buffer.projection.blockIndex(at:selectedRange().location), b = session.buffer.projection.blocks[index]
        let before = (b.text as NSString).substring(to:max(0,min(b.display.length,selectedRange().location-b.display.location))) as NSString
        let prefix = before as String
        var shortcut: (String,Int)?
        if prefix.hasSuffix(" "), prefix.dropLast().allSatisfy({ $0 == "=" }), prefix.count > 1 { shortcut = ("heading",prefix.count-1) }
        else if prefix == "- " { shortcut = ("bullet",0) } else if prefix == "+ " { shortcut = ("number",0) }
        if let (kind,level) = shortcut, b.kind == "paragraph" {
            session.buffer.editWrite(NSRange(location:b.display.location,length:before.length),text:"",group:"write")
            session.buffer.setKind(index,kind:kind,level:level); session.changed()
        } else if (inserted == "*" || inserted == "_"), !caretStyle().code, before.length > 2 {
            let close = before.length-1, open = before.range(of:inserted,options:.backwards,range:NSRange(location:0,length:close)).location
            guard open != NSNotFound, close-open > 1, before.substring(with:NSRange(location:close-1,length:1)) != inserted else { return }
            let preceding = open > 0 ? before.substring(with:NSRange(location:open-1,length:1)) : ""
            let inner = before.substring(with:NSRange(location:open+1,length:close-open-1))
            guard preceding != inserted, preceding != "\\", inner.first?.isWhitespace != true, inner.last?.isWhitespace != true, !inner.contains("\n"), !inner.contains("\u{FFFC}") else { return }
            if preceding.unicodeScalars.contains(where:CharacterSet.alphanumerics.contains), inner.unicodeScalars.first.map(CharacterSet.alphanumerics.contains) == true { return }
            let copy = DocumentBuffer(session.buffer.source), fragment = copy.copy(NSRange(location:b.display.location+open+1,length:inner.utf16.count))
            copy.editWrite(NSRange(location:b.display.location+open,length:close-open+1),text:fragment.source,raw:true)
            let marked = NSRange(location:b.display.location+open,length:inner.utf16.count)
            copy.format(marked,italic:inserted == "_")
            let caret = copy.projection.sourceOffset(at:NSMaxRange(marked))
            session.buffer.commit(copy.source,selection:EditSelection(caret,caret),group:"write")
            insertionBold = false; insertionItalic = false; session.changed()
        }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if composing || hasMarkedText() {
            super.insertText(insertString,replacementRange:replacementRange); composing = false; commitComposition(); return
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
        if session?.mode == .write, [36,76].contains(event.keyCode), event.modifierFlags.intersection([.shift,.command,.option,.control]) == [.shift] {
            insertLineBreak(nil); return
        }
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
        guard session?.mode == .write else { return }
        if selectedRange().length == 0 { let style = caretStyle(); if italic { insertionItalic = !(insertionItalic ?? style.italic) } else { insertionBold = !(insertionBold ?? style.bold) }; return }
        session?.format(italic:italic)
        let style = caretStyle(); insertionBold = style.bold; insertionItalic = style.italic
    }
    func caretStyle() -> TextStyle {
        guard let session else { return TextStyle() }
        let block = session.buffer.projection.blocks[session.buffer.projection.blockIndex(at:selectedRange().location)]
        var offset = block.display.location
        for run in block.inlines.flatMap(\.runs) {
            let at = selectedRange().location, end = offset+run.text.utf16.count
            if selectedRange().length > 0 ? at >= offset && at < end : at > offset && at <= end { return run.style }
            offset += run.text.utf16.count
        }
        return TextStyle()
    }
    override func insertNewline(_ sender: Any?) {
        guard let session else { return }
        finishComposition(); captureSelection()
        if session.mode == .write { session.buffer.split(selectedRange()); session.changed(); scrollRangeToVisible(selectedRange()) }
        else {
            let range = selectedRange(), line = (string as NSString).substring(to:range.location).components(separatedBy:"\n").last ?? ""
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            session.buffer.editSource(range,text:"\n"+indent); session.changed()
        }
        dismissSlash()
    }
    override func insertLineBreak(_ sender: Any?) {
        guard let session else { return }
        finishComposition(); captureSelection()
        if session.mode == .write { session.buffer.lineBreak(selectedRange()) }
        else { session.buffer.editSource(selectedRange(),text:"\n",group:"") }
        session.changed(); scrollRangeToVisible(selectedRange()); dismissSlash()
    }
    func focusTableCell(_ blockIndex: Int,_ cell: Int) {
        guard let blocks = session?.buffer.projection.blocks, blocks.indices.contains(blockIndex), blocks[blockIndex].cellRanges.indices.contains(cell) else { return }
        let block = blocks[blockIndex], range = block.cellRanges[cell]
        setSelectedRange(NSRange(location:block.display.location+range.location,length:range.length))
        captureSelection(); scrollRangeToVisible(selectedRange()); window?.makeFirstResponder(self)
        tableControlCell = (blockIndex,cell); positionTableControls()
    }
    override func insertTab(_ sender: Any?) {
        guard let session, session.mode == .write, let cell = session.buffer.projection.tableCell(at:selectedRange()) else { super.insertTab(sender); return }
        let block = session.buffer.projection.blocks[cell.block]
        if cell.cell+1 < block.tableCells.count { focusTableCell(cell.block,cell.cell+1); return }
        captureSelection()
        let raw = session.buffer.source.bytes(block.source), at = block.source.end-1
        let comma = raw.dropLast().trimmingCharacters(in:.whitespacesAndNewlines).hasSuffix(",") ? "" : ","
        let insertion = comma+"\n"+(0..<block.columns).map { _ in "  [],\n" }.joined()
        session.buffer.commit(session.buffer.source.replacingBytes(ByteSpan(at,at),with:insertion),selection:session.buffer.selection)
        session.changed(); focusTableCell(cell.block,block.tableCells.count)
    }
    override func insertBacktab(_ sender: Any?) {
        guard let session, session.mode == .write, let cell = session.buffer.projection.tableCell(at:selectedRange()) else { super.insertBacktab(sender); return }
        if cell.cell > 0 { focusTableCell(cell.block,cell.cell-1) }
        else {
            let at = max(0,session.buffer.projection.blocks[cell.block].display.location-1)
            setSelectedRange(NSRange(location:at,length:0)); captureSelection(); scrollRangeToVisible(selectedRange())
        }
    }
    override func copy(_ sender: Any?) {
        guard let session, selectedRange().length > 0 else { return }
        let board = NSPasteboard.general; board.clearContents()
        let plain = session.mode == .write ? session.buffer.copy(selectedRange()).plain : (string as NSString).substring(with:selectedRange())
        board.setString(session.mode == .write ? plain.replacingOccurrences(of:"\u{2028}",with:"\n") : plain,forType:.string)
        if session.mode == .write {
            let fragment = session.buffer.copy(selectedRange())
            if let data = try? JSONEncoder().encode(fragment) { board.setData(data,forType:NSPasteboard.PasteboardType("local.blank.typst-fragment")) }
            if !session.buffer.projection.blocks.contains(where:{ $0.collapsed && NSIntersectionRange($0.display,selectedRange()).length > 0 }), let data = try? textStorage?.attributedSubstring(from:selectedRange()).data(from:NSRange(location:0,length:selectedRange().length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf]) { board.setData(data,forType:.rtf) }
        }
    }
    override func cut(_ sender: Any?) { copy(sender); insertText("",replacementRange:selectedRange()) }
    override func paste(_ sender: Any?) {
        guard let session else { return }
        let board = NSPasteboard.general
        if session.mode == .write, let data = board.data(forType:NSPasteboard.PasteboardType("local.blank.typst-fragment")), let fragment = try? JSONDecoder().decode(RichFragment.self,from:data) {
            captureSelection(); session.buffer.paste(fragment,range:selectedRange()); session.changed(); return
        }
        if session.mode == .write, let image = NSImage(pasteboard:board), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let data = bitmap.representation(using:.png,properties:[:]) {
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blank-paste-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let url = directory.appendingPathComponent("pasted-image.png"); try data.write(to:url)
                let path = try session.importImage(url); try? FileManager.default.removeItem(at:directory)
                captureSelection(); session.insertionAnchor = session.buffer.selection
                session.insertSource("#figure(image(\(jsonString(path)), width: 85%))",block:true)
            } catch { session.error = error.localizedDescription }
            return
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
        var rect = convert(windowRect,from:nil)
        // A zero-width native caret is an empty NSRect. Give popover positioning
        // a nonempty anchor at the same insertion location.
        rect.size.width = max(1,rect.width)
        return rect
    }
    func blockRect(_ index: Int) -> NSRect {
        guard let b = session?.buffer.projection.blocks[index] else { return .zero }
        let first = rectFor(b.display.location), last = rectFor(NSMaxRange(b.display))
        return NSRect(x:textContainerInset.width,y:first.minY,width:max(100,bounds.width-2*textContainerInset.width),height:max(first.height,last.maxY-first.minY))
    }
    func hoveredBlock(at point: NSPoint) -> Int? {
        guard let session, session.mode == .write else { return nil }
        return session.buffer.projection.blocks.indices.first { index in
            let rect = blockRect(index)
            if tableBlockHandleRect(index)?.contains(point) == true { return true }
            return point.y >= rect.minY-5 && point.y < rect.maxY+5 && point.x >= textContainerInset.width-38 && point.x < bounds.width-textContainerInset.width
        }
    }
    func tableBlockHandleRect(_ index: Int) -> NSRect? {
        guard let blocks = session?.buffer.projection.blocks, blocks.indices.contains(index), blocks[index].kind == "table",
              let firstCell = tableCellRect(block:index,cell:0) else { return nil }
        return NSRect(x:textContainerInset.width-38,y:firstCell.minY-30,width:32,height:28)
    }
    func isOverBlockHandle(_ point: NSPoint,index: Int) -> Bool {
        if let rect = tableBlockHandleRect(index) { return rect.contains(point) }
        return point.x >= textContainerInset.width-38 && point.x <= textContainerInset.width-6
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with:event) }
    private func updateSlashMenuCursor(for event: NSEvent) -> Bool {
        guard slashPopover?.isShown == true,
              let popoverWindow = slashPopover?.contentViewController?.view.window,
              let eventWindow = event.window ?? window,
              popoverWindow.frame.contains(eventWindow.convertPoint(toScreen:event.locationInWindow)) else { return false }
        if hoverBlock != nil { hoverBlock = nil; needsDisplay = true }
        NSCursor.arrow.set(); return true
    }
    override func cursorUpdate(with event: NSEvent) {
        if updateSlashMenuCursor(for:event) || updateContentsCursor(for:event) { return }
        if session?.mode != .write { super.cursorUpdate(with:event) }
        else if grabbed != nil { NSCursor.closedHand.set() }
        else { mouseMoved(with:event) }
    }
    private func updateContentsCursor(for event: NSEvent) -> Bool {
        guard session?.contentsCursorView?.updateCursor(for:event) == true else { return false }
        if hoverBlock != nil { hoverBlock = nil; needsDisplay = true }
        return true
    }
    override func mouseMoved(with event: NSEvent) {
        if updateSlashMenuCursor(for:event) || updateContentsCursor(for:event) { return }
        guard session?.mode == .write, grabbed == nil else { return }
        let point = convert(event.locationInWindow,from:nil)
        if codeButtons.values.contains(where:{ $0.frame.contains(point) }) || tableButtons.contains(where:{ $0.trackingMenu || !$0.isHidden && $0.frame.insetBy(dx:-6,dy:-6).contains(point) }) { NSCursor.arrow.set(); return }
        let offset = characterIndexForInsertion(at:point)
        if let cell = session?.buffer.projection.tableCell(at:NSRange(location:offset,length:0)), tableCellRect(block:cell.block,cell:cell.cell)?.contains(point) == true { tableControlCell = (cell.block,cell.cell) }
        else if tableControlReachRect()?.contains(point) != true { tableControlCell = session?.buffer.projection.tableCell(at:selectedRange()).map { ($0.block,$0.cell) } }
        positionTableControls()
        let next = bounds.contains(point) ? hoveredBlock(at:point) : nil
        if next != hoverBlock { hoverBlock = next; needsDisplay = true }
        if let next, isOverBlockHandle(point,index:next) { NSCursor.openHand.set() }
        else { (bounds.contains(point) ? NSCursor.iBeam : NSCursor.arrow).set() }
    }
    override func mouseExited(with event: NSEvent) {
        if updateContentsCursor(for:event) { return }
        if grabbed == nil { hoverBlock = nil; needsDisplay = true; NSCursor.arrow.set() }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if grabbed == nil { hoverBlock = hoveredBlock(at:point); needsDisplay = true }
        if let hoverBlock = hoveredBlock(at:point), isOverBlockHandle(point,index:hoverBlock) {
            self.hoverBlock = hoverBlock
            grabbed = hoverBlock; pressPoint = point; dragPoint = point; draggingBlock = false
            let region = blockRect(hoverBlock)
            if let bitmap = bitmapImageRepForCachingDisplay(in:region) { cacheDisplay(in:region,to:bitmap); let image = NSImage(size:region.size); image.addRepresentation(bitmap); dragImage = image }
            NSCursor.closedHand.push(); needsDisplay = true; return
        }
        if event.clickCount == 2, let session, session.mode == .write {
            let index = session.buffer.projection.blockIndex(at:characterIndexForInsertion(at:point))
            if session.buffer.projection.blocks[index].collapsed { toggleCode(index); return }
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
        draggingBlock = false; dragImage = nil
        mouseMoved(with:event)
    }
    func dropIndicatorRect() -> NSRect? {
        guard draggingBlock, let grabbed, let blocks = session?.buffer.projection.blocks, blocks.indices.contains(grabbed) else { return nil }
        let target = max(0,min(dragTarget,blocks.count)), y: CGFloat
        if target == 0 { y = blockRect(0).minY-12 }
        else if target == blocks.count { y = blockRect(target-1).maxY+12 }
        else { y = (blockRect(target-1).maxY+blockRect(target).minY)/2 }
        return NSRect(x:textContainerInset.width,y:y-1,width:max(80,bounds.width-textContainerInset.width*2),height:2)
    }
    func showBlockMenu(_ index: Int,event: NSEvent) {
        guard let session else { return }
        let block = session.buffer.projection.blocks[index]
        let menu = NSMenu()
        if block.editable {
            let turn = NSMenuItem(title:"Turn into",action:nil,keyEquivalent:""); let submenu = NSMenu()
            for command in SlashCommand.all.prefix(7) where command.kind != block.kind || command.level != block.level {
                let item = BlockMenuItem(title:command.label,action:#selector(blockMenuAction(_:)),keyEquivalent:""); item.target = self; item.blockIndex = index; item.command = command; submenu.addItem(item)
            }
            turn.submenu = submenu; menu.addItem(turn)
        } else if block.kind == "table", !block.cellRanges.isEmpty {
            addTableMenus(to:menu,block:index,cell:0)
        } else {
            if block.kind == "source" {
                let fold = BlockMenuItem(title:block.collapsed ? "Expand code" : "Collapse code",action:#selector(blockMenuAction(_:)),keyEquivalent:"")
                fold.target = self; fold.blockIndex = index; fold.blockAction = "fold"; menu.addItem(fold)
            }
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
        else if item.blockAction == "fold" { toggleCode(item.blockIndex); return }
        else if item.blockAction == "edit" { session.editObject(item.blockIndex); return }
        else { session.buffer.blockAction(item.blockIndex,action:item.blockAction) }
        session.changed()
    }
    override func draw(_ dirtyRect: NSRect) {
        // Keep TextKit's text-container clip out of the gutter-overlay pass.
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        positionObjects(); positionCodeControls()
        guard session?.mode == .write, let session else { return }
        for (index,b) in session.buffer.projection.blocks.enumerated() where ["bullet","number"].contains(b.kind) {
            let r = rectFor(b.display.location)
            guard r.intersects(visibleRect) else { continue }
            let label = b.kind == "bullet" ? "•" : "\(listNumber(index))."
            (label as NSString).draw(at:NSPoint(x:textContainerInset.width,y:r.minY),withAttributes:[.font:readingFont(size:CGFloat(session.fontSize)),.foregroundColor:session.inkColor.withAlphaComponent(0.6)])
        }
        if let grabbed, draggingBlock {
            let raw = session.buffer.projection.blocks[grabbed].text
            let preview = NSAttributedString(string:raw,attributes:[.font:readingFont(size:CGFloat(session.fontSize)),.foregroundColor:session.inkColor.withAlphaComponent(0.45)])
            if let dragImage { dragImage.draw(in:NSRect(x:dragPoint.x+18,y:dragPoint.y+12,width:min(550,dragImage.size.width),height:dragImage.size.height),from:.zero,operation:.sourceOver,fraction:0.45,respectFlipped:true,hints:nil) }
            else { preview.draw(in:NSRect(x:dragPoint.x+18,y:dragPoint.y+12,width:350,height:150)) }
            if let line = dropIndicatorRect() { session.inkColor.withAlphaComponent(0.45).setFill(); line.fill() }
        } else if let index = grabbed ?? hoverBlock {
            let rect = rectFor(session.buffer.projection.blocks[index].display.location)
            let centerY = tableBlockHandleRect(index)?.midY ?? rect.midY
            session.inkColor.withAlphaComponent(0.45).setFill()
            for row in 0..<3 { for column in 0..<2 { NSBezierPath(ovalIn:NSRect(x:textContainerInset.width-26+CGFloat(column*5),y:centerY-6+CGFloat(row*5),width:3,height:3)).fill() } }
        }
    }
    func listNumber(_ index: Int) -> Int {
        guard let blocks = session?.buffer.projection.blocks else { return 1 }
        var n = 1, i = index-1
        while i >= 0 && blocks[i].kind == "number" { n += 1; i -= 1 }; return n
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses:[NSURL.self,NSImage.self],options:nil) { return .copy }
        return super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let session, session.mode == .write else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation,from:nil), offset = characterIndexForInsertion(at:point)
        setSelectedRange(NSRange(location:offset,length:0)); captureSelection()
        session.insertionAnchor = session.buffer.selection
        if let urls = sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] {
            do {
                let imports = try urls.map { try session.importImage($0) }
                session.insertSource(imports.map { "#figure(image(\(jsonString($0)), width: 85%))" }.joined(separator:"\n\n"),block:true)
                return true
            } catch { session.error = error.localizedDescription; return false }
        }
        return false
    }
    var slashMatches: [SlashCommand] {
        let inCell = session?.buffer.projection.tableCell(at:NSRange(location:slashStart ?? selectedRange().location,length:0)) != nil
        return SlashCommand.all.filter { (!inCell || $0.supportedInTableCell) && (slashQuery.isEmpty || ($0.label+" "+$0.keywords).localizedCaseInsensitiveContains(slashQuery)) }
    }
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
        let height = min(390,CGFloat(max(1,choices.count))*46+12)
        let width = SlashMenu.contentWidth(choices)
        // ScrollView has no intrinsic height. Constrain the hosted root so
        // AppKit's automatic popover sizing cannot collapse its visible rows.
        let controller = NSHostingController(rootView:content.frame(width:width,height:height))
        slashPopover?.contentViewController = controller
        slashPopover?.contentSize = NSSize(width:width,height:height)
        ensureNativeLayout()
        // Filtering changes the hosted view's size. Re-associate the popover
        // with the current native caret rectangle after each layout update.
        slashPopover?.show(relativeTo:rectFor(slashStart ?? selectedRange().location),of:self,preferredEdge:.maxY)
        window?.makeFirstResponder(self)
    }
    func dismissSlash() {
        let restoreTypography = plainSlashQuery
        slashPopover?.close(); slashPopover = nil; slashStart = nil; slashQuery = ""; plainSlashQuery = false
        if restoreTypography {
            lastRevision = -1
            if refreshing { DispatchQueue.main.async { [weak self] in self?.refresh() } }
            else { refresh() }
        }
    }
    func chooseSlash() {
        guard let start = slashStart, slashMatches.indices.contains(slashIndex), let session else { return }
        let command = slashMatches[slashIndex]
        let range = NSRange(location:start,length:selectedRange().location-start)
        let copy = DocumentBuffer(session.buffer.source); copy.selection = session.buffer.selection
        copy.editWrite(range,text:"",group:"")
        if !command.insertion { copy.setKind(at:NSRange(location:copy.projection.displayOffset(at:copy.selection.focus),length:0),kind:command.kind,level:command.level) }
        session.buffer.commit(copy.source,selection:copy.selection); dismissSlash(); session.changed()
        if command.insertion { session.chooseInsertion(command.kind) }
    }
}
final class BlockMenuItem: NSMenuItem {
    var blockIndex = 0
    var command: SlashCommand?
    var blockAction = ""
}

final class CodeDisclosureButton: NSButton { var blockIndex = 0; var collapsed = false }
final class TableActionButton: NSPopUpButton, NSMenuDelegate {
    var trackingMenu = false
    weak var editor: NativeTextView?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds,cursor:.arrow) }
    func menuWillOpen(_ menu: NSMenu) { trackingMenu = true }
    func menuDidClose(_ menu: NSMenu) { trackingMenu = false; editor?.positionTableControls() }
}
final class TableMenuItem: NSMenuItem {
    var blockIndex = 0
    var cell = 0
    var column = false
    var operation = "after"
}

extension NativeTextView {
    func toggleCode(_ index: Int) {
        guard let session, session.buffer.projection.blocks.indices.contains(index) else { return }
        finishComposition(); captureSelection()
        let block = session.buffer.projection.blocks[index]
        session.buffer.setSourceCollapsed(index,!block.collapsed)
        session.buffer.selection = EditSelection(block.source.start,block.source.start)
        refresh(); window?.makeFirstResponder(self)
    }
    @objc func codeDisclosure(_ sender: CodeDisclosureButton) { toggleCode(sender.blockIndex) }
    func positionCodeControls() {
        guard let session, session.mode == .write, window != nil else {
            codeButtons.values.forEach { $0.removeFromSuperview() }; codeButtons.removeAll(); return
        }
        var visible = Set<Int>()
        for (index,block) in session.buffer.projection.blocks.enumerated() where block.kind == "source" && (block.collapsed || block.text.contains("\n")) {
            let rect = rectFor(block.display.location)
            guard rect.intersects(visibleRect) else { continue }
            visible.insert(index)
            let button = codeButtons[index] ?? CodeDisclosureButton()
            if codeButtons[index] == nil {
                button.isBordered = false; button.bezelStyle = .smallSquare
                button.target = self; button.action = #selector(codeDisclosure(_:)); addSubview(button); codeButtons[index] = button
            }
            button.blockIndex = index
            if button.image == nil || button.collapsed != block.collapsed {
                button.collapsed = block.collapsed
                button.image = NSImage(systemSymbolName:block.collapsed ? "chevron.right" : "chevron.down",accessibilityDescription:nil)
                button.setAccessibilityLabel(block.collapsed ? "Expand code block" : "Collapse code block")
                button.toolTip = block.collapsed ? "Expand code" : "Collapse code"
            }
            let frame = NSRect(x:textContainerInset.width-50,y:rect.midY-9,width:18,height:18)
            if button.frame != frame { button.frame = frame }
        }
        for index in Array(codeButtons.keys) where !visible.contains(index) { codeButtons.removeValue(forKey:index)?.removeFromSuperview() }
    }
    func tableMenu(block: Int,cell: Int,column: Bool) -> NSMenu {
        let menu = NSMenu()
        guard let b = session?.buffer.projection.blocks[block] else { return menu }
        let dimension = column ? "Column" : "Row"
        for (title,action) in [("Add \(dimension) Before","before"),("Add \(dimension) After","after"),("Delete \(dimension)","delete")] {
            let item = TableMenuItem(title:title,action:#selector(changeTable(_:)),keyEquivalent:"")
            item.target = self; item.blockIndex = block; item.cell = cell; item.column = column; item.operation = action
            item.isEnabled = action != "delete" || (column ? b.columns : b.tableCells.count/b.columns) > 1
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }
    func addTableMenus(to menu: NSMenu,block: Int,cell: Int) {
        for column in [false,true] {
            let item = NSMenuItem(title:column ? "Column" : "Row",action:nil,keyEquivalent:"")
            item.submenu = tableMenu(block:block,cell:cell,column:column); menu.addItem(item)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for:event)
        if let session, session.mode == .write, let cell = session.buffer.projection.tableCell(at:NSRange(location:characterIndexForInsertion(at:convert(event.locationInWindow,from:nil)),length:0)) {
            let result = menu ?? NSMenu(); result.insertItem(.separator(),at:0)
            let controls = NSMenu(); addTableMenus(to:controls,block:cell.block,cell:cell.cell)
            for item in controls.items.reversed() { controls.removeItem(item); result.insertItem(item,at:0) }
            return result
        }
        return menu
    }
    @objc func changeTable(_ item: TableMenuItem) {
        guard let session else { return }
        finishComposition(); captureSelection()
        let b = session.buffer.projection.blocks[item.blockIndex], cols = b.columns
        if session.buffer.changeTable(item.blockIndex,cell:item.cell,column:item.column,action:item.operation) {
            session.changed()
            let next = session.buffer.projection.blocks[item.blockIndex]
            let row = item.cell/cols, col = item.cell%cols
            let targetRow = row+(item.column ? 0 : item.operation == "after" ? 1 : 0)
            let targetCol = col+(item.column && item.operation == "after" ? 1 : 0)
            focusTableCell(item.blockIndex,min(next.tableCells.count-1,min(targetRow,next.tableCells.count/next.columns-1)*next.columns+min(targetCol,next.columns-1)))
        } else { session.error = "This table's structure must be edited in Source." }
    }
    func positionTableControls() {
        guard !tableButtons.contains(where:{ $0.trackingMenu }) else { return }
        guard let session, session.mode == .write, let (index,cell) = tableControlCell, session.buffer.projection.blocks.indices.contains(index) else { tableButtons.forEach { $0.isHidden = true }; return }
        let block = session.buffer.projection.blocks[index]
        guard block.cellRanges.indices.contains(cell), block.columns > 0 else { tableButtons.forEach { $0.isHidden = true }; return }
        if tableButtons.isEmpty {
            for column in [false,true] {
                let button = TableActionButton(frame:.zero,pullsDown:true)
                button.editor = self
                button.isBordered = true; button.bezelStyle = .rounded
                button.imagePosition = .imageOnly
                (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
                button.setAccessibilityLabel(column ? "Table column actions" : "Table row actions")
                addSubview(button); tableButtons.append(button)
            }
        }
        guard let rowRect = tableCellRect(block:index,cell:cell/block.columns*block.columns),
              let columnRect = tableCellRect(block:index,cell:cell%block.columns) else { tableButtons.forEach { $0.isHidden = true }; return }
        for (offset,button) in tableButtons.enumerated() {
            let column = offset == 1, menu = tableMenu(block:index,cell:cell,column:column)
            let label = NSMenuItem(title:"",action:nil,keyEquivalent:""); label.image = NSImage(systemSymbolName:"ellipsis",accessibilityDescription:nil); menu.insertItem(label,at:0)
            menu.delegate = button
            button.menu = menu; button.isHidden = false
            button.toolTip = column ? "Column \(cell%block.columns+1) actions" : "Row \(cell/block.columns+1) actions"
            button.frame = column ? NSRect(x:columnRect.midX-14,y:columnRect.minY-30,width:28,height:28) : NSRect(x:rowRect.minX-30,y:rowRect.midY-14,width:28,height:28)
        }
    }
    func tableCellRect(block index: Int,cell: Int) -> NSRect? {
        guard let blocks = session?.buffer.projection.blocks, blocks.indices.contains(index),
              let storage = textStorage, let layoutManager else { return nil }
        let block = blocks[index]
        guard block.cellRanges.indices.contains(cell) else { return nil }
        let native = block.cellRanges[cell], range = NSRange(location:block.display.location+native.location,length:native.length+1)
        guard NSMaxRange(range) <= storage.length,
              let style = storage.attribute(.paragraphStyle,at:range.location,effectiveRange:nil) as? NSParagraphStyle,
              let textBlock = style.textBlocks.first as? NSTextTableBlock else { return nil }
        layoutManager.ensureLayout(forCharacterRange:range)
        let glyphs = layoutManager.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
        let rect = layoutManager.boundsRect(for:textBlock,glyphRange:glyphs)
        return rect.isEmpty ? nil : rect.offsetBy(dx:textContainerOrigin.x,dy:textContainerOrigin.y)
    }
    func tableControlReachRect() -> NSRect? {
        guard let (index,cell) = tableControlCell, let blocks = session?.buffer.projection.blocks, blocks.indices.contains(index) else { return nil }
        let block = blocks[index]
        guard block.columns > 0, let active = tableCellRect(block:index,cell:cell),
              let row = tableCellRect(block:index,cell:cell/block.columns*block.columns),
              let column = tableCellRect(block:index,cell:cell%block.columns) else { return nil }
        return active.union(row).union(column).insetBy(dx:-36,dy:-36)
    }
}
