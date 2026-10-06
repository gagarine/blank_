import AppKit
import SwiftUI

// The handle and slash menus share row geometry and typography. Only the
// app's explicit actions are presented here; AppKit's text context-menu
// additions (such as AutoFill) belong in the text's normal right-click menu.
struct BlockAction: Identifiable {
    let id = UUID()
    var item: NSMenuItem
    var children: [BlockAction]
    var symbol: String {
        if let command = (item as? BlockMenuItem)?.command { return command.systemSymbol }
        switch item.title {
        case "Turn into": return "arrow.triangle.branch"
        case "Duplicate": return "doc.on.doc"
        case "Delete": return "trash"
        case "Collapse code": return "chevron.up.chevron.down"
        case "Expand code": return "chevron.down"
        case "Row", "Column": return "tablecells"
        default: return item.title.hasPrefix("Edit") ? "square.and.pencil" : item.title.hasPrefix("Delete") ? "minus" : "plus"
        }
    }
    static func items(from menu: NSMenu) -> [BlockAction] {
        menu.items.filter { !$0.isSeparatorItem }.map { BlockAction(item:$0,children:$0.submenu.map(items(from:)) ?? []) }
    }
}
struct BlockActionMenu: View {
    var items: [BlockAction]
    var choose: (NSMenuItem) -> Void
    var resize: (NSSize) -> Void
    @NativeState private var path: [Int] = []
    @NativeState private var selection = 0
    @FocusState private var focused: Bool
    var choices: [BlockAction] { path.reduce(items) { $0[$1].children } }
    var size: NSSize {
        func widths(_ list: [BlockAction]) -> [CGFloat] {
            list.flatMap { [($0.item.title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12)]).width] + widths($0.children) }
        }
        return NSSize(width:ceil((widths(items).max() ?? 120)+94),height:min(390,CGFloat(choices.count)*46+12)+(path.isEmpty ? 0 : 34))
    }
    func activate(_ index: Int) {
        guard choices.indices.contains(index), choices[index].item.isEnabled else { return }
        if choices[index].children.isEmpty { choose(choices[index].item) }
        else { path.append(index); selection = 0 }
    }
    func back() { if !path.isEmpty { path.removeLast(); selection = 0 } }
    var body: some View {
        VStack(spacing:0) {
            if !path.isEmpty {
                Button(action:back) { Label("Back",systemImage:"chevron.left").font(.system(size:12)).frame(maxWidth:.infinity,alignment:.leading).padding(8).contentShape(Rectangle()) }.buttonStyle(.plain).frame(height:34)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing:2) {
                        ForEach(Array(choices.enumerated()),id:\.element.id) { index,entry in
                            MenuRowButton(label:entry.item.title,action:{ activate(index) },hover:{ if $0 { selection = index } }) {
                                HStack(spacing:12) {
                                    Image(systemName:entry.symbol).font(.system(size:16)).frame(width:28)
                                    Text(entry.item.title).font(.system(size:12,weight:.medium))
                                    Spacer(minLength:8)
                                    if !entry.children.isEmpty { Image(systemName:"chevron.right").font(.system(size:10)).foregroundStyle(.secondary) }
                                }.padding(.horizontal,10).frame(height:44).background(index == selection ? Color.primary.opacity(0.07) : .clear).clipShape(RoundedRectangle(cornerRadius:5))
                            }.disabled(!entry.item.isEnabled).opacity(entry.item.isEnabled ? 1 : 0.4).id(index)
                        }
                    }.padding(6)
                }.onChange(of:selection) { _,index in proxy.scrollTo(index) }
            }
        }.frame(width:size.width,height:size.height).background(.background)
        .background(SlashMenuCursorArea().allowsHitTesting(false))
        .focusable().focusEffectDisabled().focused($focused)
        .onAppear { focused = true }
        .onChange(of:path) { _,_ in resize(size) }
        .onKeyPress(.downArrow) { selection = min(selection+1,max(0,choices.count-1)); return .handled }
        .onKeyPress(.upArrow) { selection = max(0,selection-1); return .handled }
        .onKeyPress(.return) { activate(selection); return .handled }
        .onKeyPress(.rightArrow) { if choices.indices.contains(selection), !choices[selection].children.isEmpty { activate(selection) }; return .handled }
        .onKeyPress(.leftArrow) { back(); return .handled }
        .onKeyPress(.escape) { if path.isEmpty { choose(NSMenuItem()) } else { back() }; return .handled }
    }
}
