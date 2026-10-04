import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:500),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:720,height:500)); scroll.hasVerticalScroller = true
let text = NSTextView(usingTextLayoutManager:true)
text.frame = scroll.bounds; text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width:30,height:30)
scroll.documentView = text; window.contentView = scroll
let source = NSMutableAttributedString(string:"Before\nOne\nTwo\nThree\nFour\nAfter",attributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.labelColor])
let table = NSTextTable(); table.numberOfColumns = 2; table.collapsesBorders = true
for (i,word) in ["One","Two","Three","Four"].enumerated() {
    let block = NSTextTableBlock(table:table,startingRow:i/2,rowSpan:1,startingColumn:i%2,columnSpan:1)
    block.setWidth(1,type:.absoluteValueType,for:.border)
    block.setBorderColor(.separatorColor)
    block.setWidth(10,type:.absoluteValueType,for:.padding)
    let style = NSMutableParagraphStyle(); style.textBlocks = [block]
    let range = (source.string as NSString).range(of:word+"\n")
    source.addAttribute(.paragraphStyle,value:style,range:range)
}
text.textStorage!.setAttributedString(source)
window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text); app.activate(ignoringOtherApps:true)
RunLoop.main.run(until:Date().addingTimeInterval(0.2))
print("TextKit 2 after native table:",text.textLayoutManager != nil)
var rects: [NSRect] = []
for word in ["One","Two","Three","Four"] {
    var actual = NSRange()
    let range = (source.string as NSString).range(of:word)
    let rect = text.firstRect(forCharacterRange:range,actualRange:&actual); rects.append(rect)
    print(word,rect)
}
print("Native grid geometry:",abs(rects[0].minY-rects[1].minY)<1 && rects[1].minX>rects[0].maxX && abs(rects[2].minY-rects[3].minY)<1)
window.close()
