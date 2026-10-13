import Foundation
import SwiftUI

// Foundation parses package Markdown on the project worker. Native Text renders
// inline emphasis/links; block intents supply paragraph breaks and typography.
struct UniverseReadmeBlock: Identifiable {
    let id: Int
    var text: AttributedString
    var heading: Int?
    var code = false
    var marker: String?
    var indent = 0
    var rows: [TableRow] = []
    struct TableRow: Identifiable {
        let id: Int
        let header: Bool
        var cells: [AttributedString] = []
    }
    static func parse(_ source: String) -> [Self] {
        guard let markdown = try? AttributedString(markdown:source) else { return [Self(id:0,text:AttributedString(source))] }
        var blocks: [Self] = []
        for run in markdown.runs {
            let components = run.presentationIntent?.components ?? []
            var content = AttributedString(markdown[run.range])
            content.presentationIntent = nil
            if let table = components.first(where:{ if case .table = $0.kind { return true }; return false }),
               let row = components.first(where:{ if case .tableRow = $0.kind { return true }; return $0.kind == .tableHeaderRow }),
               let cell = components.first(where:{ if case .tableCell = $0.kind { return true }; return false }),
               case let .tableCell(column) = cell.kind {
                if blocks.last?.id != table.identity { blocks.append(Self(id:table.identity,text:AttributedString())) }
                let blockIndex = blocks.count-1
                if blocks[blockIndex].rows.last?.id != row.identity {
                    blocks[blockIndex].rows.append(TableRow(id:row.identity,header:row.kind == .tableHeaderRow))
                }
                let rowIndex = blocks[blockIndex].rows.count-1
                while blocks[blockIndex].rows[rowIndex].cells.count <= column { blocks[blockIndex].rows[rowIndex].cells.append(AttributedString()) }
                blocks[blockIndex].rows[rowIndex].cells[column].append(content)
                continue
            }
            let id = components.first?.identity ?? 0
            if blocks.last?.id == id { blocks[blocks.count-1].text.append(content); continue }
            var block = Self(id:id,text:content)
            let nearestList = components.first { $0.kind == .orderedList || $0.kind == .unorderedList }
            let nearestItem = components.first { if case .listItem = $0.kind { return true }; return false }
            if let nearestItem, case let .listItem(ordinal) = nearestItem.kind { block.marker = nearestList?.kind == .orderedList ? "\(ordinal)." : "•" }
            for component in components {
                switch component.kind {
                case let .header(level): block.heading = level
                case .codeBlock: block.code = true
                case .orderedList, .unorderedList: block.indent += 1
                default: break
                }
            }
            blocks.append(block)
        }
        return blocks
    }
}
struct UniverseReadme: View {
    let blocks: [UniverseReadmeBlock]
    var body: some View {
        LazyVStack(alignment:.leading,spacing:12) {
            ForEach(blocks) { block in
                if !block.rows.isEmpty {
                    Grid(alignment:.topLeading,horizontalSpacing:16,verticalSpacing:10) {
                        ForEach(block.rows) { row in
                            GridRow {
                                ForEach(row.cells.indices,id:\.self) { index in
                                    Text(row.cells[index]).fontWeight(row.header ? .semibold : .regular).fixedSize(horizontal:false,vertical:true)
                                }
                            }
                        }
                    }
                } else {
                    HStack(alignment:.top,spacing:8) {
                        if let marker = block.marker { Text(marker).foregroundStyle(.secondary) }
                        Text(block.text)
                            .font(block.code ? .system(.callout,design:.monospaced) : block.heading.map { $0 == 1 ? .title2 : .headline } ?? .body)
                            .frame(maxWidth:.infinity,alignment:.leading)
                    }.padding(.leading,CGFloat(max(0,block.indent-1))*12)
                }
            }
        }
    }
}
