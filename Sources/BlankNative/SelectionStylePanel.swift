import AppKit
import SwiftUI
import BlankCore

func nativeHexColor(_ hex: String) -> NSColor? {
    guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(),radix:16) else { return nil }
    return NSColor(srgbRed:CGFloat((value >> 16)&255)/255,green:CGFloat((value >> 8)&255)/255,blue:CGFloat(value&255)/255,alpha:1)
}
func nativeAlignment(_ value: String?) -> NSTextAlignment {
    switch value { case "center": return .center; case "right": return .right; case "justified": return .justified; default: return .left }
}
let inlinePalette: [(String,String,String)] = [
    ("Gray","#737373","#e7e7e7"),("Brown","#936647","#ead9cb"),("Orange","#cf6a12","#ffe0c2"),
    ("Yellow","#ae8400","#fff2a6"),("Green","#238252","#c9efdb"),("Blue","#247cb7","#cee9ff"),
    ("Purple","#8758bb","#e8d9ff"),("Pink","#b74787","#f9dced"),("Red","#c83e3e","#ffd6d6")
]
final class SelectionStylePanel: NSPopover {
    var child: SelectionStylePanel?
    var isVisible: Bool { isShown }
    override init() {
        super.init(); behavior = .applicationDefined; animates = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func close() { child?.close(); child = nil; super.close() }
    func orderOut(_ sender: Any?) { close() }
}
@MainActor final class SelectionPanelTarget {
    weak var view: NativeTextView?
    let revision: Int, path: String, range: NSRange
    init(_ editor: NativeTextView) { view = editor; revision = editor.session?.buffer.revision ?? -1; path = editor.session?.active ?? ""; range = editor.selectedRange() }
    var editor: NativeTextView? {
        guard let view, let session = view.session, session.mode == .write, session.active == path,
              session.buffer.revision == revision, view.selectedRange() == range, !view.hasMarkedText() else { return nil }
        return view
    }
}
private enum SelectionPage { case blocks, colors, more }
struct SelectionStyleBar: View {
    let target: SelectionPanelTarget
    var editor: NativeTextView? { target.editor }
    let style: TextStyle
    let block: ProjectedBlock
    let inTable: Bool
    @NativeState private var page: SelectionPage?
    private func size(_ page: SelectionPage) -> NSSize {
        switch page {
        case .colors: return NSSize(width:280,height:294)
        case .more: return NSSize(width:240,height:326)
        case .blocks: return NSSize(width:240,height:CGFloat(SlashCommand.blockStyles.count)*34+52)
        }
    }
    var body: some View {
        bar.frame(width:inTable ? 330 : 450,height:44)
            .font(.system(size:12)).background(.background)
    }
    var bar: some View {
        HStack(spacing:5) {
            if !inTable {
                SelectionButton(width:110) { toggle(.blocks) } label: { Text(blockTitle).lineLimit(1) }
                    .accessibilityLabel("Block style: "+blockTitle)
                    .background(subpanel(.blocks,contents:AnyView(blocks)))
                Divider().frame(height:22)
            }
            mark("Bold","bold",.bold); mark("Italic","italic",.italic)
            mark("Underline","underline",.underline); mark("Strikethrough","strikethrough",.strikethrough)
            mark("Inline code","chevron.left.forwardslash.chevron.right",.code)
            SelectionButton { editor?.selectionLink() } label: { Image(systemName:"link") }.help("Link…").accessibilityLabel("Link").disabled(block.kind == "raw")
            SelectionButton { toggle(.colors) } label: { Image(systemName:"textformat.alt").foregroundStyle(Color(nsColor:style.color.flatMap(nativeHexColor) ?? .labelColor)) }
                .help("Text and highlight color").accessibilityLabel("Colors").disabled(block.kind == "raw")
                .background(subpanel(.colors,contents:AnyView(colors)))
            SelectionButton { toggle(.more) } label: { Image(systemName:"ellipsis") }.help("Superscript, subscript, and alignment").accessibilityLabel("More styles")
                .background(subpanel(.more,contents:AnyView(more)))
        }.controlSize(.small).padding(6)
    }
    var blockTitle: String { block.kind == "heading" ? "Heading \(block.level)" : SlashCommand.blockStyles.first { $0.kind == block.kind }?.label ?? "Text" }
    private func toggle(_ choice: SelectionPage) { page = page == choice ? nil : choice }
    private func subpanel(_ choice: SelectionPage,contents: AnyView) -> some View {
        SelectionSubpanelAnchor(editor:editor,isPresented:page == choice,size:size(choice),contents:AnyView(contents.frame(width:size(choice).width,height:size(choice).height).font(.system(size:12)).background(.background)),onClose:{ if page == choice { page = nil } })
            .allowsHitTesting(false)
    }
    func header(_ title: String) -> some View {
        HStack {
            SelectionButton(width:70) { page = nil } label: { Label("Close",systemImage:"xmark") }
                .accessibilityLabel("Close formatting options")
            Spacer(); Text(title).fontWeight(.medium); Spacer()
        }.padding(.horizontal,8).frame(height:38)
    }
    func row(_ label: String,_ icon: String,selected: Bool = false,enabled: Bool = true,action: @escaping ()->Void) -> some View {
        SelectionButton(width:nil,action:action) {
            HStack(spacing:10) { Image(systemName:icon).frame(width:20); Text(label); Spacer(); if selected { Image(systemName:"checkmark").foregroundStyle(.secondary) } }
                .padding(.horizontal,10).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
        }.accessibilityLabel(label).disabled(!enabled)
    }
    var blocks: some View {
        VStack(spacing:0) {
            header("Turn into"); Divider()
            VStack(spacing:2) {
                ForEach(SlashCommand.blockStyles) { command in
                    row(command.label,command.systemSymbol,selected:command.kind == block.kind && command.level == block.level) { editor?.selectionBlockStyle(command) }
                }
            }.padding(6)
        }
    }
    var more: some View {
        VStack(spacing:0) {
            header("More styles"); Divider()
            VStack(spacing:2) {
                row("Superscript","textformat.superscript",selected:style.superscript,enabled:block.kind != "raw") { editor?.formatNative(.superscript) }
                row("Subscript","textformat.subscript",selected:style.subscripted,enabled:block.kind != "raw") { editor?.formatNative(.subscripted) }
                Divider().padding(.vertical,3)
                row("Default alignment","text.alignleft",selected:block.alignment == nil) { editor?.selectionAlignment(nil) }
                ForEach(["left","center","right","justified"],id:\.self) { alignment in
                    row(alignment.capitalized,alignment == "justified" ? "text.justify" : "text.align"+alignment,selected:block.alignment == alignment,enabled:alignment != "justified" || block.kind == "paragraph") { editor?.selectionAlignment(alignment) }
                }
            }.padding(6)
        }
    }
    var colors: some View {
        VStack(alignment:.leading,spacing:0) {
            header("Colors"); Divider()
            VStack(alignment:.leading,spacing:8) {
                Text("Text Color").fontWeight(.medium)
                palette(highlight:false)
                Text("Highlight Color").fontWeight(.medium).padding(.top,4)
                palette(highlight:true)
            }.padding(12)
        }
    }
    func palette(highlight: Bool) -> some View {
        let entries: [(String,String?)] = [(highlight ? "None" : "Default",nil)]+inlinePalette.map { ($0.0,highlight ? $0.2 : $0.1) }
        return LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:6),count:5),spacing:4) {
            ForEach(entries,id:\.0) { name,hex in
                let color = Color(nsColor:hex.flatMap(nativeHexColor) ?? .labelColor)
                let selected = (highlight ? style.highlight : style.color) == hex
                SelectionButton(width:40) { editor?.selectionAttribute(highlight ? "highlight" : "color",hex) } label: {
                    ZStack {
                        Circle().fill(highlight && hex != nil ? color : .clear)
                        Circle().stroke(highlight ? Color.secondary.opacity(0.35) : color.opacity(0.6),lineWidth:1)
                        if !highlight { Text("A").font(.system(size:15,weight:.medium)).foregroundStyle(color) }
                        else if hex == nil { Image(systemName:"slash.circle").foregroundStyle(.secondary) }
                        if selected { Circle().stroke(Color.accentColor,lineWidth:2).padding(-3) }
                    }.frame(width:24,height:24)
                }.help(name+(highlight ? " highlight" : " text color")).accessibilityLabel(name+(highlight ? " highlight" : " text color"))
            }
        }
    }
    func mark(_ title: String,_ icon: String,_ mark: InlineMark) -> some View {
        SelectionButton { editor?.formatNative(mark) } label: { Image(systemName:icon).foregroundStyle(style[keyPath:mark.keyPath] ? Color.accentColor : Color.primary) }
            .help(title).accessibilityLabel(title).disabled(block.kind == "raw")
    }
}
// Keep the same quiet typography/background as slash and handle panels.
// AppKit owns cursor rectangles so editor tracking cannot leave an I-beam here.
struct SelectionMenuFace: ViewModifier {
    let width: CGFloat?
    @NativeState private var hovered = false
    func body(content: Content) -> some View {
        content.frame(width:width,height:32).contentShape(Rectangle())
            .background(hovered ? Color.primary.opacity(0.07) : .clear,in:RoundedRectangle(cornerRadius:5))
            .onHover { hovered = $0 }.background(SelectionButtonCursor().allowsHitTesting(false))
    }
}
struct SelectionButton<Label: View>: View {
    let width: CGFloat?
    let action: ()->Void
    let label: Label
    init(width: CGFloat? = 32,action: @escaping ()->Void,@ViewBuilder label: ()->Label) {
        self.width = width; self.action = action; self.label = label()
    }
    var body: some View {
        // The padded rectangle must belong to the actual Button label, rather
        // than an outer decoration or just its visible glyphs.
        Button(action:action) { label.modifier(SelectionMenuFace(width:width)) }.buttonStyle(.plain)
    }
}
// Anchor secondary native popovers to their toolbar buttons. Keeping the bar's
// hosting view mounted preserves its position and the editor's native selection.
private struct SelectionSubpanelAnchor: NSViewRepresentable {
    weak var editor: NativeTextView?
    let isPresented: Bool
    let size: NSSize
    let contents: AnyView
    let onClose: ()->Void
    func makeNSView(context: Context) -> SelectionSubpanelAnchorView { SelectionSubpanelAnchorView() }
    func updateNSView(_ view: SelectionSubpanelAnchorView,context: Context) {
        view.editor = editor; view.isPresented = isPresented; view.size = size; view.contents = contents; view.onClose = onClose
        view.updatePresentation()
    }
    static func dismantleNSView(_ view: SelectionSubpanelAnchorView,coordinator: ()) { view.dismiss() }
}
private final class SelectionSubpanelAnchorView: NSView, NSPopoverDelegate {
    weak var editor: NativeTextView?
    var isPresented = false
    var size = NSSize.zero
    var contents: AnyView?
    var onClose: (()->Void)?
    var popover: SelectionStylePanel?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updatePresentation() }
    override func layout() { super.layout(); if isPresented && popover?.isShown != true { updatePresentation() } }
    func updatePresentation() {
        guard isPresented else { dismiss(); return }
        guard window != nil, !bounds.isEmpty, let contents, let editor, let parent = editor.selectionPanel, parent.isShown else { return }
        let panel = popover ?? SelectionStylePanel(); popover = panel
        panel.delegate = self
        if parent.child !== panel { parent.child?.close(); parent.child = panel }
        panel.contentViewController = NSHostingController(rootView:contents); panel.contentSize = size
        panel.show(relativeTo:bounds,of:self,preferredEdge:.maxY)
        editor.window?.makeFirstResponder(editor)
    }
    func dismiss() {
        isPresented = false
        popover?.close()
        if editor?.selectionPanel?.child === popover { editor?.selectionPanel?.child = nil }
        popover = nil
    }
    func popoverDidClose(_ notification: Notification) {
        if editor?.selectionPanel?.child === notification.object as? SelectionStylePanel { editor?.selectionPanel?.child = nil }
        if isPresented {
            isPresented = false
            let closed = onClose
            DispatchQueue.main.async { closed?() }
        }
    }
}
struct SelectionButtonCursor: NSViewRepresentable {
    @Environment(\.isEnabled) var enabled
    func makeNSView(context: Context) -> SelectionButtonCursorView { SelectionButtonCursorView() }
    func updateNSView(_ view: SelectionButtonCursorView,context: Context) { view.enabled = enabled; view.window?.invalidateCursorRects(for:view) }
}
final class SelectionButtonCursorView: NSView {
    var enabled = true
    private var tracking: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:.zero,options:[.cursorUpdate,.mouseEnteredAndExited,.mouseMoved,.activeInActiveApp,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds,cursor:enabled ? .pointingHand : .arrow) }
    override func cursorUpdate(with event: NSEvent) { (enabled ? NSCursor.pointingHand : .arrow).set() }
    override func mouseEntered(with event: NSEvent) { cursorUpdate(with:event) }
    override func mouseMoved(with event: NSEvent) { cursorUpdate(with:event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}
extension NativeTextView {
    func scheduleInlinePanelFocusCheck() {
        // Resign-key arrives before the new key window is known. Wait for that
        // transition so the editor's own popovers can accept native clicks.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.ownsInlinePanelFocus else { return }
            self.selectionPanel?.orderOut(nil); self.dismissLinkHover()
        }
    }
    var ownsInlinePanelFocus: Bool {
        guard let key = NSApp.keyWindow else { return false }
        return key === window || [selectionPanel,selectionPanel?.child,linkPanel].compactMap({ $0 }).contains { $0.isShown && $0.contentViewController?.view.window === key }
    }
    func updateSelectionPanelCursor(for event: NSEvent) -> Bool {
        guard let eventWindow = event.window ?? window,
              let panel = [selectionPanel?.child,selectionPanel,linkPanel].compactMap({ $0 }).first(where:{ panel in
                  guard panel.isShown, let panelWindow = panel.contentViewController?.view.window else { return false }
                  return panelWindow.frame.contains(eventWindow.convertPoint(toScreen:event.locationInWindow))
              }), let content = panel.contentViewController?.view, let panelWindow = content.window else { return false }
        let screen = eventWindow.convertPoint(toScreen:event.locationInWindow)
        if panel === linkPanel { linkDismissWork?.cancel() }
        func controls(_ view: NSView) -> [SelectionButtonCursorView] {
            (view as? SelectionButtonCursorView).map { [$0] } ?? view.subviews.flatMap(controls)
        }
        let point = panelWindow.convertPoint(fromScreen:screen)
        let control = controls(content).first { $0.bounds.contains($0.convert(point,from:nil)) }
        if hoverBlock != nil { hoverBlock = nil; needsDisplay = true }
        (control?.enabled == true ? NSCursor.pointingHand : .arrow).set()
        return true
    }
    func applyInlineAppearance(_ style: TextStyle,to text: NSMutableAttributedString,range: NSRange) {
        // Link appearance is source-backed; AppKit's actionable .link attribute
        // would intercept the clicks needed to place a caret or select text.
        if let color = style.color.flatMap(nativeHexColor) ?? (style.link == nil ? nil : NSColor.linkColor) { text.addAttribute(.foregroundColor,value:color,range:range) }
        if let color = style.highlight.flatMap(nativeHexColor) {
            let background = effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? color.withAlphaComponent(0.25) : color
            text.addAttribute(.backgroundColor,value:background,range:range)
        }
        if style.superscript || style.subscripted, let font = text.attribute(.font,at:range.location,effectiveRange:nil) as? NSFont {
            text.addAttribute(.font,value:NSFontManager.shared.convert(font,toSize:font.pointSize*0.7),range:range)
            text.addAttribute(.baselineOffset,value:font.pointSize*(style.superscript ? 0.4 : -0.2),range:range)
        }
    }
    func scheduleSelectionPanel() {
        guard !selectionPanelUpdatePending else { return }; selectionPanelUpdatePending = true
        DispatchQueue.main.async { [weak self] in self?.selectionPanelUpdatePending = false; self?.updateSelectionPanel() }
    }
    func updateSelectionPanel(requireKeyWindow: Bool = true) {
        if selectedRange().length > 0 { dismissLinkHover() }
        guard let session, session.mode == .write, !session.contactSheet, session.sheet == nil,
              !composing, !hasMarkedText(), !selectingText, !draggingBlock, slashPopover?.isShown != true, blockPopover?.isShown != true,
              selectedRange().length > 0, let window, (!requireKeyWindow || ownsInlinePanelFocus || selectionPanel?.isShown == true || CommandLine.arguments.contains("--selection-style-ui-test")), window.firstResponder === self,
              let manager = layoutManager, let container = textContainer else { selectionPanel?.orderOut(nil); return }
        let range = selectedRange(), projection = session.buffer.projection
        let block = projection.blocks[projection.blockIndex(at:range.location)]
        guard block.editable || projection.tableCell(at:range) != nil,
              !projection.atomicRanges.contains(where:{ NSIntersectionRange($0,range).length > 0 }) else { selectionPanel?.orderOut(nil); return }
        let glyphs = manager.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
        var rect = manager.boundingRect(forGlyphRange:glyphs,in:container); rect.origin.x += textContainerInset.width; rect.origin.y += textContainerInset.height
        guard visibleRect.intersects(rect) else { selectionPanel?.orderOut(nil); return }
        let identity = "\(session.active)/\(session.buffer.revision)/\(range.location)/\(range.length)/\(effectiveAppearance.name.rawValue)"
        if selectionPanel?.isShown == true, selectionPanelIdentity == identity, selectionPanelAnchor == rect { return }
        let inTable = projection.tableCell(at:range) != nil
        let panel = selectionPanel ?? SelectionStylePanel(); selectionPanel = panel
        let width: CGFloat = inTable ? 330 : 450
        if !panel.isShown || selectionPanelIdentity != identity {
            panel.child?.close(); panel.child = nil
            panel.contentViewController = NSHostingController(rootView:SelectionStyleBar(target:SelectionPanelTarget(self),style:caretStyle(),block:block,inTable:inTable))
        }
        selectionPanelIdentity = identity; selectionPanelAnchor = rect
        panel.contentSize = NSSize(width:width,height:44)
        panel.show(relativeTo:rect,of:self,preferredEdge:.minY)
        window.makeFirstResponder(self)

    }
    func selectionAttribute(_ attribute: String,_ value: String?) {
        guard let session, session.mode == .write, selectedRange().length > 0, session.requestEditing() else { return }
        finishComposition(); session.synchronizeSelection()
        session.buffer.setInlineAttribute(selectedRange(),attribute:attribute,value:value); session.changed(); insertionExtra = caretStyle(); scheduleSelectionPanel()
    }
    func selectionAlignment(_ alignment: String?) {
        guard let session, session.mode == .write, session.requestEditing() else { return }
        finishComposition(); session.synchronizeSelection()
        session.buffer.setAlignment(selectedRange(),alignment:alignment); session.changed(); scheduleSelectionPanel()
    }
    func selectionBlockStyle(_ command: SlashCommand) {
        guard let session else { return }
        session.performBlockCommand(command); selectionPanel?.orderOut(nil)
    }
    func selectionLink() {
        guard let session, let window, session.mode == .write, selectedRange().length > 0 else { return }
        finishComposition(); session.synchronizeSelection()
        let range = selectedRange(), revision = session.buffer.revision, path = session.active
        let alert = NSAlert(); alert.messageText = "Link"; alert.addButton(withTitle:"Apply"); alert.addButton(withTitle:"Remove Link"); alert.addButton(withTitle:"Cancel")
        let field = NSTextField(string:caretStyle().link ?? ""); field.placeholderString = "https://example.com"
        field.frame = NSRect(x:0,y:0,width:360,height:24); field.setAccessibilityLabel("Link URL"); alert.accessoryView = field
        selectionPanel?.orderOut(nil)
        alert.beginSheetModal(for:window) { [weak self,weak session] response in
            guard let self, let session, session.active == path, session.buffer.revision == revision else { return }
            let value = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            if response == .alertFirstButtonReturn && !value.isEmpty || response == .alertSecondButtonReturn {
                self.setSelectedRange(range); self.selectionAttribute("link",response == .alertSecondButtonReturn ? nil : value)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self); self.scheduleSelectionPanel()
            }
        }
        alert.window.initialFirstResponder = field
    }
}
