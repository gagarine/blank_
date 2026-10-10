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
    var isVisible: Bool { isShown }
    override init() {
        super.init(); behavior = .applicationDefined; animates = false
    }
    required init?(coder: NSCoder) { fatalError() }
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
struct SelectionStyleBar: View {
    let target: SelectionPanelTarget
    var editor: NativeTextView? { target.editor }
    let style: TextStyle
    let block: ProjectedBlock
    let inTable: Bool
    var body: some View {
        HStack(spacing:5) {
            if !inTable {
                Menu {
                    ForEach(SlashCommand.blockStyles) { command in
                        Button { editor?.selectionBlockStyle(command) } label: {
                            Label(command.label,systemImage:command.kind == block.kind && command.level == block.level ? "checkmark" : command.systemSymbol)
                        }
                    }
                } label: { Text(block.kind == "heading" ? "Heading \(block.level)" : SlashCommand.blockStyles.first { $0.kind == block.kind }?.label ?? "Text").lineLimit(1) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:110).modifier(SelectionMenuFace(width:110))
                Divider().frame(height:22)
            }
            mark("Bold","bold",.bold); mark("Italic","italic",.italic)
            mark("Underline","underline",.underline); mark("Strikethrough","strikethrough",.strikethrough)
            mark("Inline code","chevron.left.forwardslash.chevron.right",.code)
            Button { editor?.selectionLink() } label: { Image(systemName:"link") }.help("Link…").accessibilityLabel("Link").disabled(block.kind == "raw")
            Menu {
                Menu("Text Color") {
                    Button("Default") { editor?.selectionAttribute("color",nil) }
                    ForEach(inlinePalette,id:\.0) { name,color,_ in
                        Button { editor?.selectionAttribute("color",color) } label: { Label { Text(name) } icon: { Image(systemName:"circle.fill").foregroundStyle(Color(nsColor:nativeHexColor(color)!)) } }
                    }
                }
                Menu("Highlight Color") {
                    Button("None") { editor?.selectionAttribute("highlight",nil) }
                    ForEach(inlinePalette,id:\.0) { name,_,color in
                        Button { editor?.selectionAttribute("highlight",color) } label: { Label { Text(name) } icon: { Image(systemName:"circle.fill").foregroundStyle(Color(nsColor:nativeHexColor(color)!)) } }
                    }
                }
            } label: { Image(systemName:"textformat.alt") }.menuStyle(.borderlessButton).menuIndicator(.hidden).modifier(SelectionMenuFace(width:32)).help("Text and highlight color").accessibilityLabel("Colors").disabled(block.kind == "raw")
            Menu {
                Button(style.superscript ? "Remove Superscript" : "Superscript") { editor?.formatNative(.superscript) }.disabled(block.kind == "raw")
                Button(style.subscripted ? "Remove Subscript" : "Subscript") { editor?.formatNative(.subscripted) }.disabled(block.kind == "raw")
                Divider()
                ForEach(["left","center","right","justified"],id:\.self) { alignment in
                    Button { editor?.selectionAlignment(alignment) } label: { Label(alignment.capitalized,systemImage:alignment == "justified" ? "text.justify" : "text.align"+alignment) }
                    .disabled(alignment == "justified" && block.kind != "paragraph")
                }
            } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).modifier(SelectionMenuFace(width:32)).help("Superscript, subscript, and alignment").accessibilityLabel("More styles")
        }
        .buttonStyle(SelectionHoverButtonStyle()).controlSize(.small).font(.system(size:12)).padding(6)
        .background(.background,in:RoundedRectangle(cornerRadius:10))
    }
    func mark(_ title: String,_ icon: String,_ mark: InlineMark) -> some View {
        Button { editor?.formatNative(mark) } label: { Image(systemName:icon).foregroundStyle(style[keyPath:mark.keyPath] ? Color.accentColor : Color.primary) }
        .help(title).accessibilityLabel(title).disabled(block.kind == "raw")
    }
}
// Keep the same quiet typography/background as slash and handle panels.
// AppKit owns cursor rectangles so editor tracking cannot leave an I-beam here.
struct SelectionMenuFace: ViewModifier {
    let width: CGFloat
    @NativeState private var hovered = false
    func body(content: Content) -> some View {
        content.frame(width:width,height:32).contentShape(Rectangle())
            .background(hovered ? Color.primary.opacity(0.07) : .clear,in:RoundedRectangle(cornerRadius:5))
            .onHover { hovered = $0 }.background(SelectionButtonCursor().allowsHitTesting(false))
    }
}
struct SelectionHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.modifier(SelectionMenuFace(width:32)) }
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
    func applyInlineAppearance(_ style: TextStyle,to text: NSMutableAttributedString,range: NSRange) {
        if let color = style.color.flatMap(nativeHexColor) { text.addAttribute(.foregroundColor,value:color,range:range) }
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
        guard let session, session.mode == .write, !session.contactSheet, session.sheet == nil,
              !composing, !hasMarkedText(), !selectingText, !draggingBlock, slashPopover?.isShown != true, blockPopover?.isShown != true,
              selectedRange().length > 0, let window, (!requireKeyWindow || window.isKeyWindow || CommandLine.arguments.contains("--selection-style-ui-test")), window.firstResponder === self,
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
    func selectionAlignment(_ alignment: String) {
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
