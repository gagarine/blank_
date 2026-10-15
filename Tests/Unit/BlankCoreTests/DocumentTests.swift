import Foundation
import Testing
import BlankCore

@Suite(.serialized)
final class DocumentTests {
    @Test("File relocation preserves typing, redo, Unicode selections and history identities")
    func testRelocationHistory() {
        let original = "#include \"chapter.typ\"\n\nCafé 👩🏽‍💻"
        let buffer = DocumentBuffer(original)
        buffer.selection = EditSelection(original.utf8.count,original.utf8.count)
        buffer.editSource(NSRange(location:original.utf16.count,length:0),text:" 日本")
        buffer.breakUndoGroup()
        let first = buffer.undoID
        buffer.editSource(NSRange(location:buffer.source.utf16.count,length:0),text:" Second")
        let second = buffer.undoID
        buffer.undo()
        buffer.relocateSource { source,selection in
            let range = (source as NSString).range(of:"chapter.typ")
            guard range.location != NSNotFound else { return (source,selection) }
            let start = source.byteOffset(utf16:range.location)
            let text = source.replacingBytes(ByteSpan(start,start+"chapter.typ".utf8.count),with:"Paper-assets/chapter.typ")
            let delta = "Paper-assets/".utf8.count
            return (text,EditSelection(selection.anchor > start ? selection.anchor+delta : selection.anchor,selection.focus > start ? selection.focus+delta : selection.focus))
        }
        expectEqual(buffer.undoID,first); expectEqual(buffer.redoID,second)
        let relocated = original.replacingOccurrences(of:"chapter.typ",with:"Paper-assets/chapter.typ")
        expectEqual(buffer.source,relocated+" 日本")
        expectEqual(buffer.selection,EditSelection(buffer.source.utf8.count,buffer.source.utf8.count))
        buffer.redo(); expectEqual(buffer.source,relocated+" 日本 Second")
        buffer.undo(); buffer.undo(); expectEqual(buffer.source,relocated)
        expectEqual(buffer.selection,EditSelection(relocated.utf8.count,relocated.utf8.count))
        buffer.redo(); buffer.redo(); expectEqual(buffer.source,relocated+" 日本 Second")
    }
    @Test("Selection styles, raw code, alignment, tables and history")
    func testSelectionStyles() {
        let original = "// Keep\nBefore *café 👩🏽‍💻* after\n\n#let custom = 42"
        let buffer = DocumentBuffer(original)
        let range = (buffer.projection.text as NSString).range(of:"café 👩🏽‍💻")
        buffer.format(range,mark:.superscript)
        expectTrue(buffer.projection.blocks.flatMap(\.inlines).flatMap(\.runs).filter { $0.style.superscript }.map(\.text).joined() == "café 👩🏽‍💻")
        buffer.format(range,mark:.subscripted)
        expectFalse(buffer.projection.blocks.flatMap(\.inlines).flatMap(\.runs).contains { $0.style.superscript })
        buffer.setInlineAttribute(range,attribute:"color",value:"#247cb7")
        buffer.setInlineAttribute(range,attribute:"highlight",value:"#fff2a6")
        buffer.setInlineAttribute(range,attribute:"link",value:"https://example.com/café?q=\"x\"")
        expectEqual(buffer.projection.text,DocumentBuffer(original).projection.text)
        expectFalse(buffer.parsed.erroneous)
        expectTrue(buffer.projection.blocks.flatMap(\.inlines).flatMap(\.runs).contains { $0.style.link == "https://example.com/café?q=\"x\"" })
        expectTrue(buffer.source.hasPrefix("// Keep\nBefore ")); expectTrue(buffer.source.hasSuffix("\n\n#let custom = 42"))
        buffer.setInlineAttribute(range,attribute:"color",value:nil)
        expectFalse(buffer.projection.blocks.flatMap(\.inlines).flatMap(\.runs).contains { $0.style.color != nil })
        let code = DocumentBuffer("Before café 👩🏽‍💻 after")
        let selection = (code.projection.text as NSString).range(of:"café 👩🏽‍💻")
        code.format(selection,mark:.code); expectEqual(code.projection.text,"Before café 👩🏽‍💻 after")
        expectTrue(code.projection.blocks[0].inlines.flatMap(\.runs).contains { $0.style.code })
        code.editWrite(NSRange(location:selection.location+4,length:0),text:"#_*")
        expectEqual(code.projection.text,"Before café#_* 👩🏽‍💻 after"); expectFalse(code.parsed.erroneous)
        code.undo(); code.format(selection,mark:.code); expectEqual(code.source,"Before café 👩🏽‍💻 after")
        for text in ["#let x = 2\n日本", "```quoted`", "", "  leading\n\ntrailing  "] {
            let raw = DocumentBuffer(rawTypst(text,block:true))
            expectEqual(raw.projection.blocks[0].kind,"raw"); expectEqual(raw.projection.text,text)
            raw.editWrite(NSRange(location:0,length:0),text:"é`#")
            expectEqual(raw.projection.text,"é`#"+text); expectFalse(raw.parsed.erroneous)
            raw.undo(); expectEqual(raw.source,rawTypst(text,block:true))
        }
        for text in ["日本`#", " leading` ", "````"] {
            let inline = DocumentBuffer("Before "+rawTypst(text)+" after")
            expectEqual(inline.projection.text,"Before "+text+" after"); expectFalse(inline.parsed.erroneous)
        }
        let tagged = DocumentBuffer("```typ\n#let x = 2\n```")
        tagged.editWrite(NSRange(location:0,length:0),text:"日本`")
        expectTrue(tagged.source.hasPrefix("```typ\n")); expectEqual(tagged.projection.text,"日本`#let x = 2")
        for alignment in ["left","center","right","justified"] {
            let aligned = DocumentBuffer("Before\n\n*日本👩🏽‍💻* after\n\nAfter")
            let selected = aligned.projection.blocks[1].display
            aligned.setAlignment(selected,alignment:alignment)
            let source = aligned.source
            aligned.selection = EditSelection(aligned.projection.sourceOffset(at:selected.location+2),aligned.projection.sourceOffset(at:selected.location+2))
            aligned.split(NSRange(location:selected.location+2,length:0))
            expectEqual(aligned.projection.blocks.count,4); expectEqual(aligned.projection.blocks[1].alignment,alignment); expectEqual(aligned.projection.blocks[2].alignment,alignment)
            expectEqual(aligned.projection.blocks[1].text,"日本"); expectEqual(aligned.projection.blocks[2].text,"👩🏽‍💻 after"); expectFalse(aligned.parsed.erroneous)
            aligned.undo(); expectEqual(aligned.source,source)
            aligned.setAlignment(selected,alignment:nil)
            expectEqual(aligned.source,"Before\n\n*日本👩🏽‍💻* after\n\nAfter")
            expectTrue(aligned.projection.blocks[1].alignment == nil)
            expectEqual(aligned.selection,EditSelection(aligned.projection.sourceOffset(at:selected.location),aligned.projection.sourceOffset(at:NSMaxRange(selected))))
            aligned.undo(); expectEqual(aligned.source,source)
            aligned.redo(); expectEqual(aligned.source,"Before\n\n*日本👩🏽‍💻* after\n\nAfter")
            aligned.undo(); expectEqual(aligned.source,source)
            aligned.editWrite(NSRange(location:selected.location+2,length:0),text:"first\nsecond")
            expectEqual(aligned.projection.blocks.count,4); expectEqual(aligned.projection.blocks[2].alignment,alignment); expectFalse(aligned.parsed.erroneous)
            aligned.undo(); expectEqual(aligned.source,source)
        }
        let block = DocumentBuffer("Before\n\n= Café *日本*\n\nAfter")
        let heading = block.projection.blocks[1]
        block.setAlignment(heading.display,alignment:"center")
        expectEqual(block.projection.blocks[1].kind,"heading"); expectEqual(block.projection.blocks[1].alignment,"center")
        expectEqual(block.projection.blocks[1].text,"Café 日本")
        block.setKind(1,kind:"raw"); expectEqual(block.projection.blocks[1].kind,"raw")
        block.setKind(1,kind:"paragraph"); expectEqual(block.projection.blocks[1].text,"Café 日本")
        block.undo(); block.undo(); block.undo(); expectEqual(block.source,"Before\n\n= Café *日本*\n\nAfter")
        let table = DocumentBuffer("#table(columns: 2, inset: 8pt, /*Keep*/ [日本 👋], [Other])")
        let cell = table.projection.blocks[0].cellRanges[0]
        table.setAlignment(cell,alignment:"right")
        let alignedTable = table.source
        table.setAlignment(cell,alignment:nil)
        expectEqual(table.source,"#table(columns: 2, inset: 8pt, /*Keep*/ [日本 👋], [Other])")
        table.undo(); expectEqual(table.source,alignedTable)
        table.redo(); expectEqual(table.source,"#table(columns: 2, inset: 8pt, /*Keep*/ [日本 👋], [Other])")
        table.setInlineAttribute(cell,attribute:"color",value:"#247cb7"); table.format(cell,mark:.superscript)
        expectTrue(table.source.contains("inset: 8pt, /*Keep*/")); expectEqual(table.projection.text,"日本 👋\nOther\n")
        table.undo(); table.undo(); expectEqual(table.source,"#table(columns: 2, inset: 8pt, /*Keep*/ [日本 👋], [Other])")
    }
    @Test("Underline and strikethrough source, Unicode, clipboard and history")
    func testUnderlineAndStrikethrough() {
        let original = "// Keep café\nBefore *café 👩🏽‍💻* and _日本_ after\n\n#let custom = 42"
        let b = DocumentBuffer(original), text = b.projection.text
        let range = (text as NSString).range(of:"café 👩🏽‍💻")
        b.selection = EditSelection(b.projection.sourceOffset(at:range.location),b.projection.sourceOffset(at:NSMaxRange(range)))
        let selection = b.selection
        b.format(range,mark:.underline)
        expectEqual(b.source,original.replacingOccurrences(of:"*café 👩🏽‍💻*",with:"#underline[*café 👩🏽‍💻*]"))
        b.format(range,mark:.strikethrough)
        expectEqual(b.projection.text,text); expectFalse(b.parsed.erroneous)
        expectEqual(b.projection.blocks.flatMap(\.inlines).flatMap(\.runs).filter { $0.style.bold && $0.style.underline && $0.style.strikethrough }.map(\.text).joined(),"café 👩🏽‍💻")
        let decorated = b.source, afterSelection = b.selection
        let fragment = b.copy(range)
        let pasted = DocumentBuffer("Start end")
        pasted.paste(fragment,range:NSRange(location:6,length:0))
        expectTrue(pasted.projection.blocks.flatMap(\.inlines).flatMap(\.runs).contains { $0.style.underline && $0.style.strikethrough && $0.style.bold })
        b.undo(); b.undo(); expectEqual(Array(b.source.utf8),Array(original.utf8)); expectEqual(b.selection,selection)
        b.redo(); b.redo(); expectEqual(b.source,decorated); expectEqual(b.selection,afterSelection)
        b.format(range,mark:.underline); b.format(range,mark:.strikethrough)
        expectEqual(Array(b.source.utf8),Array(original.utf8))

        let custom = DocumentBuffer("Before #underline(stroke: red, /* Keep */ offset: 2pt)[*Café 日本*] after")
        let interior = (custom.projection.text as NSString).range(of:"日本")
        custom.editWrite(interior,text:"👩🏽‍💻",group:"")
        expectEqual(custom.source,"Before #underline(stroke: red, /* Keep */ offset: 2pt)[*Café 👩🏽‍💻*] after")
        custom.undo()
        custom.format(interior,mark:.underline)
        expectEqual(custom.projection.text,"Before Café 日本 after")
        expectTrue(custom.projection.blocks[0].inlines.flatMap(\.runs).contains { $0.text.contains("日本") && $0.style.bold && !$0.style.underline })
        expectTrue(custom.source.contains("/* Keep */")); expectFalse(custom.parsed.erroneous)
        let mixed = DocumentBuffer("#underline[A]B #strike[C]D")
        mixed.format(NSRange(location:0,length:2),mark:.underline)
        expectEqual(mixed.projection.text,"AB CD"); expectEqual(mixed.projection.blocks[0].inlines.flatMap(\.runs).filter { $0.style.underline }.map(\.text).joined(),"AB")
        mixed.format(NSRange(location:0,length:2),mark:.underline)
        expectEqual(mixed.source,"AB #strike[C]D")

        let cellSource = "#table(columns: 2, inset: 8pt, /*Keep*/ [日本 👋], [Other])\n\nAfter"
        let table = DocumentBuffer(cellSource), cell = table.projection.blocks[0].cellRanges[0]
        table.format(cell,mark:.underline); table.format(cell,mark:.strikethrough)
        expectEqual(table.source,cellSource.replacingOccurrences(of:"[日本 👋]",with:"[#strike[#underline[日本 👋]]]"))
        expectTrue(table.projection.blocks[0].cellProjections[0].blocks[0].inlines.flatMap(\.runs).allSatisfy { $0.style.underline && $0.style.strikethrough })
        table.undo(); table.undo(); expectEqual(table.source,cellSource)
        for mark in [InlineMark.underline,.strikethrough] {
            let empty = DocumentBuffer("#"+mark.function+"[é👩🏽‍💻]")
            empty.editWrite(NSRange(location:0,length:empty.projection.text.utf16.count),text:"")
            expectEqual(empty.source,""); empty.undo()
            expectTrue(empty.projection.blocks[0].inlines.flatMap(\.runs).allSatisfy { $0.style[keyPath:mark.keyPath] })
        }
        let oldStyle = try! JSONDecoder().decode(TextStyle.self,from:Data("{\"bold\":true,\"italic\":false,\"code\":false}".utf8))
        expectTrue(oldStyle.bold); expectFalse(oldStyle.underline || oldStyle.strikethrough)
    }
    @Test("Label presentation spans survive local Unicode edits")
    func testLabelPresentationSpans() {
        let source = "Café 👩🏽‍💻 <first>\n\n日本 <later>\n\n#table(columns: 1, [Cell <cell>], [Other])\n\n#let value = <code-value>\n// <comment>\n`<raw>`"
        let buffer = DocumentBuffer(source)
        func labels() -> [String] { buffer.projection.blocks.flatMap(\.labelSpans).map { buffer.source.bytes($0) } }
        expectEqual(labels(),["<first>","<later>","<cell>"])
        expectEqual(buffer.literalLabels,["first","later","cell"])
        let originalSelection = EditSelection(0,0); buffer.selection = originalSelection
        buffer.editWrite(NSRange(location:0,length:0),text:"日本 👋 ",group:"")
        expectTrue(buffer.lastEditWasLocal)
        expectEqual(labels(),["<first>","<later>","<cell>"])
        let full = Projection(source:buffer.source,parsed:ParsedSource.parse(buffer.source))
        expectEqual(buffer.projection.blocks.flatMap(\.labelSpans),full.blocks.flatMap(\.labelSpans))
        let table = buffer.projection.blocks.first { $0.kind == "table" }!, cellSource = buffer.source.bytes(table.tableCells[0])
        expectEqual(table.cellProjections[0].blocks.flatMap(\.labelSpans).map { cellSource.bytes($0) },["<cell>"])
        buffer.undo(); expectEqual(Array(buffer.source.utf8),Array(source.utf8)); expectEqual(buffer.selection,originalSelection)
        expectEqual(labels(),["<first>","<later>","<cell>"])
        buffer.redo(); expectEqual(labels(),["<first>","<later>","<cell>"])
    }
    @Test("Literal figure fields preserve source")
    func testFigureFieldEdits() {
        let source = "#figure( /* keep */ image(\"assets/café 日本.svg\", fit: \"contain\", width: /*w*/ 85%, alt: \"A \\\"quote\\\"\"), caption: /*c*/ [Hello \\*world\\*], placement: top, supplement: [Diagram]) <fig:one> // keep tail"
        let edit = FigureFieldEdit(source)!
        expectEqual(edit.path,"assets/café 日本.svg"); expectEqual(edit.caption,"Hello *world*"); expectEqual(edit.alt,"A \"quote\""); expectEqual(edit.width,85)
        expectEqual(Array(edit.applying(path:edit.path,caption:edit.caption,alt:edit.alt,width:edit.width).utf8),Array(source.utf8))
        expectEqual(edit.applying(path:"new.svg",caption:edit.caption,alt:edit.alt,width:85),source.replacingOccurrences(of:typstStringLiteral(edit.path),with:typstStringLiteral("new.svg")))
        expectEqual(edit.applying(path:edit.path,caption:edit.caption,alt:"New alternative",width:85),source.replacingOccurrences(of:typstStringLiteral(edit.alt),with:typstStringLiteral("New alternative")))
        expectEqual(edit.applying(path:edit.path,caption:edit.caption,alt:edit.alt,width:40),source.replacingOccurrences(of:"85%",with:"40%"))
        let nextPath = "assets/日本/new \"image\".svg", nextCaption = "Café 👩🏽‍💻 #@[]*_\\", nextAlt = "é slash / emoji 👋"
        let changed = edit.applying(path:nextPath,caption:nextCaption,alt:nextAlt,width:40)
        let expected = source.replacingOccurrences(of:typstStringLiteral(edit.path),with:typstStringLiteral(nextPath))
            .replacingOccurrences(of:"85%",with:"40%")
            .replacingOccurrences(of:typstStringLiteral(edit.alt),with:typstStringLiteral(nextAlt))
            .replacingOccurrences(of:"[Hello \\*world\\*]",with:"["+escapeTypst(nextCaption)+"]")
        expectEqual(Array(changed.utf8),Array(expected.utf8)); expectFalse(ParsedSource.parse(changed).erroneous)
        let reparsed = FigureFieldEdit(changed)!
        expectEqual(reparsed.path,nextPath); expectEqual(reparsed.caption,nextCaption); expectEqual(reparsed.alt,nextAlt); expectEqual(reparsed.width,40)
        expectEqual(edit.applying(path:edit.path,caption:"Changed",alt:edit.alt,width:85),source.replacingOccurrences(of:"[Hello \\*world\\*]",with:"[Changed]"))
        // Canonically equivalent strings still require exact-byte field changes.
        let decomposed = "#figure(image(\"café.svg\", width: 85%, alt: \"é\"), caption: [é])"
        let unicode = FigureFieldEdit(decomposed)!
        expectEqual(Array(unicode.applying(path:"café.svg",caption:"é",alt:"é",width:85).utf8),Array("#figure(image(\"café.svg\", width: 85%, alt: \"é\"), caption: [é])".utf8))
        for (path,caption,alt) in [("café.svg",unicode.caption,unicode.alt),(unicode.path,"é",unicode.alt),(unicode.path,unicode.caption,"é")] {
            let history = DocumentBuffer(decomposed), selection = EditSelection(2,7)
            history.selection = selection
            let normalized = unicode.applying(path:path,caption:caption,alt:alt,width:85)
            let after = EditSelection(3,normalized.utf8.count), revision = history.revision
            expectTrue(history.commit(normalized,selection:after))
            expectTrue(history.revision > revision && history.canUndo)
            expectEqual(Array(history.source.utf8),Array(normalized.utf8)); expectEqual(history.selection,after)
            history.undo(); expectEqual(Array(history.source.utf8),Array(decomposed.utf8)); expectEqual(history.selection,selection)
            history.redo(); expectEqual(Array(history.source.utf8),Array(normalized.utf8)); expectEqual(history.selection,after)
            let unchangedRevision = history.revision
            expectFalse(history.commit(normalized,selection:after)); expectEqual(history.revision,unchangedRevision)
        }
        for bare in ["#figure(image(\"a.svg\", width: 85%))","#figure(image(\"a.svg\", width: 85%, /* keep */), /* keep */)"] {
            let missing = FigureFieldEdit(bare)!
            expectEqual(missing.applying(path:missing.path,caption:"",alt:"",width:85),bare)
            let added = missing.applying(path:missing.path,caption:"Caption",alt:"Alternative",width:85)
            expectFalse(ParsedSource.parse(added).erroneous)
            expectEqual(FigureFieldEdit(added)!.caption,"Caption"); expectEqual(FigureFieldEdit(added)!.alt,"Alternative")
            expectEqual(added.components(separatedBy:"/* keep */").count,bare.components(separatedBy:"/* keep */").count)
        }
        for unsupported in [
            "#image(\"a.svg\", width: 85%)", "#figure(image(path, width: 85%))",
            "#figure(image(\"a.svg\"))", "#figure(image(\"a.svg\", width: auto))",
            "#figure(image(\"a.svg\", width: 85.5%))", "#figure(image(\"a.svg\", width: 101%))",
            "#figure(image(\"a.svg\", width: 85%, alt: text))",
            "#figure(image(\"a.svg\", width: 85%), caption: [*Rich*])",
            "#figure(image(\"a.svg\", width: 85%), caption: [A /* keep */ caption])",
            "#figure(image(\"a.svg\", width: 85%), caption: [\\u{41}])",
            "#figure(image(\"a.svg\", width: 85%), caption: [A\n\nparagraph])",
            "#figure(image(\"a.svg\", width: 85%, width: 40%))",
            "#figure(image(\"a.svg\", width: 85%), caption: [A], caption: [B])",
            "#figure(image(\"a.svg\", width: 85%, ..options))",
            "#figure(image(\"a.svg\", width: 85%), ..options)",
            "#figure([#image(\"a.svg\", width: 85%)])",
            "#figure(image(\"a.svg\", width: 85%), image(\"b.svg\"))",
            "#figure(custom.image(\"a.svg\", width: 85%))", "#figure(image(\"a.svg\", width: 85%)"
        ] { expectTrue(FigureFieldEdit(unsupported) == nil) }
        let document = "// before café 👩🏽‍💻\n\n"+source+"\n\nAfter 日本."
        let model = DocumentBuffer(document), start = "// before café 👩🏽‍💻\n\n".utf8.count
        let originalSelection = EditSelection(start+2,start+8); model.selection = originalSelection
        model.commit(document.replacingBytes(ByteSpan(start,start+source.utf8.count),with:changed),selection:EditSelection(start,start+changed.utf8.count))
        model.undo(); expectEqual(Array(model.source.utf8),Array(document.utf8)); expectEqual(model.selection,originalSelection)
        model.redo(); expectEqual(Array(model.source.utf8),Array(document.replacingBytes(ByteSpan(start,start+source.utf8.count),with:changed).utf8))
    }

    @Test("Literal markup labels")
    func testLiteralMarkupLabels() {
        let source = """
        = Café <sec:cafe\u{301}>

        // <comment>
        /* <block-comment> */
        `<raw>` \\<escaped> "<prose>"
        #let text = "<string>"
        #let value = <code-value>
        #cite(<citation-key>) @reference
        #figure([Caption]) <fig:one>
        #table(columns:1,[Cell <cell>])
        #[Nested <nested>]
        <fig:one>
        """
        let model = DocumentBuffer(source)
        expectEqual(model.literalLabels,["sec:cafe\u{301}","prose","fig:one","cell","nested","fig:one"])
        expectEqual(model.source,source)
        expectFalse(model.canUndo)
        model.editSource(NSRange(location:source.utf16.count,length:0),text:"\n<unsaved>",group:"")
        expectEqual(model.literalLabels.last,"unsaved")
        model.undo(); expectEqual(model.literalLabels.last,"fig:one")
        let standalone = DocumentBuffer("#ref(<sec:end.>);")
        expectEqual(standalone.projection.blocks[0].kind,"paragraph")
        expectEqual(standalone.projection.text,standalone.source)
        expectEqual(standalone.literalLabels,[])
        expectEqual(model.source,source)
    }
    @Test("Unicode source mapping")
    func testUnicodeSourceOffsets() {
        let text = "a👩🏽‍💻e\u{301}日本"
        for byte in 0...text.utf8.count where byte == text.utf8.count || Array(text.utf8)[byte] & 0xC0 != 0x80 {
            expectEqual(text.byteOffset(utf16:text.utf16Offset(byte:byte)),byte)
        }
        expectEqual("😀".byteOffset(utf16:1),0)
    }
    @Test("Lossless styled edit")
    func testProjectionAndLosslessEdit() {
        let original = "// a comment\n#set text(size: 11pt)\n#let custom = 42\n\n= Title\n\nA *bold* and _italic_ café 👋.\n\n#custom\n"
        let b = DocumentBuffer(original)
        let paragraph = b.projection.blocks.first { $0.text.hasPrefix("A ") }!
        expectEqual(paragraph.text,"A bold and italic café 👋.")
        expectTrue(paragraph.inlines.flatMap(\.runs).contains { $0.style.bold })
        b.editWrite(NSRange(location:paragraph.display.location+2,length:4),text:"strong")
        expectTrue(b.source.contains("// a comment\n#set text(size: 11pt)\n#let custom = 42"))
        expectTrue(b.source.hasSuffix("#custom\n"))
        expectTrue(b.projection.text.contains("A strong and italic café 👋."))
        b.undo(); expectEqual(b.source,original)
        b.redo(); expectTrue(b.projection.text.contains("strong"))
    }
    @Test("List continuation and exit")
    func testListContinueAndExit() {
        let b = DocumentBuffer("- first")
        b.selection = EditSelection(7,7)
        b.split(NSRange(location:5,length:0))
        expectTrue(b.source.contains("\n- "))
        expectEqual(b.projection.blocks.count,2)
        b.split(NSRange(location:b.projection.text.utf16.count,length:0))
        expectFalse(b.source.hasSuffix("- "))
    }
    @Test("Clearing inline marks without stale formatting")
    func testDeletingCompleteMarks() {
        for marked in ["*café 👋*","_café 👋_","*_café 👋_*","#strong[#emph[café 👋]]","`café 👋`"] {
            let original = "// Keep\n= "+marked+"\n\n#let untouched = 42\n\nAfter"
            let model = DocumentBuffer(original), heading = model.projection.blocks.first { $0.kind == "heading" }!
            model.selection = EditSelection(model.projection.sourceOffset(at:heading.display.location),model.projection.sourceOffset(at:NSMaxRange(heading.display)))
            model.editWrite(heading.display,text:"",group:"")
            let cleared = "// Keep\n= \n\n#let untouched = 42\n\nAfter"
            expectEqual(model.source,cleared)
            expectEqual(model.projection.blocks.first { $0.kind == "heading" }!.text,"")
            let caret = model.projection.displayOffset(at:model.selection.focus)
            model.editWrite(NSRange(location:caret,length:0),text:"/",group:"")
            expectFalse(model.projection.blocks.first { $0.kind == "heading" }!.inlines.flatMap(\.runs).contains { $0.style.bold || $0.style.italic || $0.style.code })
            model.undo(); expectEqual(model.source,cleared)
            model.undo(); expectEqual(model.source,original)
            model.redo(); expectEqual(model.source,cleared)
        }
        let partial = DocumentBuffer("Before *bold* after")
        partial.editWrite(NSRange(location:8,length:2),text:"",group:"")
        expectEqual(partial.source,"Before *bd* after")
        let custom = DocumentBuffer("#strong(delta: 2)[abc]")
        custom.editWrite(custom.projection.blocks[0].display,text:"",group:"")
        expectEqual(custom.source,"#strong(delta: 2)[]")
    }
    @Test("Paragraph joining")
    func testParagraphJoinKeepsFormatting() {
        let b = DocumentBuffer("one *bold*\n\ntwo _italic_")
        let first = b.projection.blocks[0], second = b.projection.blocks[1]
        b.editWrite(NSRange(location:NSMaxRange(first.display),length:second.display.location-NSMaxRange(first.display)),text:"")
        expectEqual(b.projection.blocks.count,1)
        expectTrue(b.source.contains("*bold*")); expectTrue(b.source.contains("_italic_"))
        b.undo(); expectEqual(b.source,"one *bold*\n\ntwo _italic_")
    }
    @Test("Paragraph and soft line breaks")
    func testParagraphAndLineBreaks() {
        let b = DocumentBuffer("First *bold* second")
        let at = "First bold".utf16.count
        b.selection = EditSelection(b.projection.sourceOffset(at:at),b.projection.sourceOffset(at:at))
        let originalSelection = b.selection
        b.split(NSRange(location:at,length:0))
        expectEqual(b.projection.blocks.count,2)
        expectEqual(b.projection.blocks[0].text,"First bold")
        // Return preserves the existing word separator as literal prose.
        expectEqual(b.projection.blocks[1].text," second")
        let splitSource = "First *bold*\n\n second", splitSelection = b.selection
        expectEqual(b.source,splitSource)
        let splitCaret = "First *bold*\n\n".utf8.count
        expectEqual(splitSelection,EditSelection(splitCaret,splitCaret))
        expectEqual(b.projection.displayOffset(at:splitSelection.focus),b.projection.blocks[1].display.location)
        expectEqual(b.projection.sourceOffset(at:b.projection.blocks[1].display.location),splitSelection.focus)
        expectTrue(b.projection.blocks[0].inlines.flatMap(\.runs).last!.style.bold)
        b.undo(); expectEqual(b.source,"First *bold* second")
        expectEqual(b.selection,originalSelection)
        b.redo(); expectEqual(b.source,splitSource); expectEqual(b.selection,splitSelection)
        expectEqual(b.projection.blocks.map(\.text),["First bold"," second"])
        b.undo()
        b.lineBreak(NSRange(location:at,length:0))
        expectEqual(b.projection.blocks.count,1)
        expectEqual(b.projection.text,"First bold\u{2028}second")
        expectFalse(b.parsed.erroneous)
        expectEqual(b.projection.displayOffset(at:b.selection.focus),at+1)
        b.undo(); expectEqual(b.source,"First *bold* second")
        let list = DocumentBuffer("- First")
        list.lineBreak(NSRange(location:5,length:0))
        expectEqual(list.projection.blocks.count,1)
        expectEqual(list.projection.blocks[0].kind,"bullet")
        expectEqual(list.projection.text,"First\u{2028}")
        list.editWrite(NSRange(location:6,length:0),text:"next")
        expectEqual(list.projection.text,"First\u{2028}next")
        expectEqual(list.projection.blocks.count,1)
        expectFalse(list.parsed.erroneous)
        let empty = DocumentBuffer()
        empty.split(NSRange(location:0,length:0))
        expectEqual(empty.projection.blocks.count,2)
        empty.split(NSRange(location:1,length:0))
        expectEqual(empty.projection.blocks.count,3)
        empty.editWrite(NSRange(location:2,length:0),text:"Third")
        expectEqual(empty.projection.blocks.map(\.text),["","","Third"])
        let between = DocumentBuffer("First\n\nSecond")
        between.selection = EditSelection(5,5)
        between.split(NSRange(location:5,length:0))
        expectEqual(between.projection.blocks.map(\.text),["First","","Second"])
        expectEqual(between.projection.displayOffset(at:between.selection.focus),6)
        between.editWrite(NSRange(location:6,length:0),text:"Middle")
        expectEqual(between.projection.blocks.map(\.text),["First","Middle","Second"])
        let heading = DocumentBuffer("= Tutorial\n\nLearn by trying.")
        let headingEnd = NSMaxRange(heading.projection.blocks[0].display)
        let sourceEnd = heading.projection.sourceOffset(at:headingEnd)
        heading.selection = EditSelection(sourceEnd,sourceEnd)
        heading.split(NSRange(location:headingEnd,length:0))
        expectEqual(heading.projection.blocks.map(\.text),["Tutorial","","Learn by trying."])
        expectEqual(heading.projection.displayOffset(at:heading.selection.focus),headingEnd+1)
    }
    @Test("Structured clipboard")
    func testClipboardHeadingAndList() {
        let b = DocumentBuffer("== A *heading*\n\n- An _item_")
        let fragment = b.copy(NSRange(location:0,length:b.projection.text.utf16.count))
        let target = DocumentBuffer()
        target.paste(fragment,range:NSRange(location:0,length:0))
        expectEqual(target.source,b.source)
        expectEqual(target.projection.blocks[0].level,2)
        expectEqual(target.projection.blocks[1].kind,"bullet")
    }
    @Test("Structured paste at caret")
    func testStructuredPasteAtCaret() {
        let heading = DocumentBuffer("= Heading"), fragment = heading.copy(NSRange(location:0,length:heading.projection.text.utf16.count))
        for (source,caret,expected) in [("HelloWorld",5,["Hello","Heading","World"]),("Café 👋*bold* tail",9,["Café 👋bo","Heading","ld tail"]),("- HelloWorld",5,["Hello","Heading","World"])] {
            let original = "// unchanged\n#set text(size: 11pt)\n\n"+source+"\n\n#custom"
            let target = DocumentBuffer(original), block = target.projection.blocks.first { $0.editable }!
            let range = NSRange(location:block.display.location+caret,length:0), at = target.projection.sourceOffset(at:range.location)
            target.selection = EditSelection(at,at)
            target.paste(fragment,range:range)
            expectEqual(target.projection.blocks.filter(\.editable).map(\.text),expected)
            expectFalse(target.parsed.erroneous)
            expectTrue(target.source.hasPrefix("// unchanged\n#set text(size: 11pt)\n\n")); expectTrue(target.source.hasSuffix("\n\n#custom"))
            expectEqual(target.projection.blocks.first { $0.text == "Heading" }?.kind,"heading")
            target.undo(); expectEqual(target.source,original); expectEqual(target.selection,EditSelection(at,at))
            target.redo(); expectEqual(target.projection.blocks.filter(\.editable).map(\.text),expected)
        }
    }
    @Test("Typst string literals")
    func testTypstStringLiterals() {
        for text in ["assets/café image.png","../chapters/one.typ","https://typst.app/docs","a \"quote\" and \\ backslash"] {
            let literal = typstStringLiteral(text)
            expectFalse(literal.contains("\\/"))
            expectEqual(try! JSONDecoder().decode(String.self,from:Data(literal.utf8)),text)
            expectFalse(ParsedSource.parse("#let value = "+literal).erroneous)
        }
    }
    @Test("Bibliography preservation")
    func testBibliographyPreservation() {
        let original = "% Keep café 日本\n@string{press = \"Press\"}\n@comment{Do not parse @book{fake,title={Fake}}}\n@book(other, title = {Unrelated}, year = 1999)\n@book{linked,\n  % Keep this comment\n  title = {Old {nested} title},\n  note = {Custom 👩🏽‍💻},\n  x-blank-zotero-key = {ABCD1234},\n  x-blank-zotero-library = {groups/123},\n}\n"
        let export = "@book{linked, title={New \"quoted\" 日本}, year={2026},}"
        let annotated = try! BibLaTeX.annotate(export,key:"ABCD1234",library:"groups/123")
        let updated = try! BibLaTeX.merge(original,key:"linked",exported:annotated)
        expectEqual(BibLaTeX.entries(original).map(\.key),["other","linked"])
        expectTrue(updated.hasPrefix(original.components(separatedBy:"@book{linked")[0]))
        expectTrue(updated.contains("% Keep this comment\n")); expectTrue(updated.contains("note = {Custom 👩🏽‍💻}"))
        expectEqual(BibLaTeX.linked(updated).first?.0.key,"linked")
        expectEqual(BibLaTeX.entries(updated).last?.value("title",in:updated),"New \"quoted\" 日本")
        let removed = try! BibLaTeX.merge(annotated,key:"linked",exported:BibLaTeX.annotate("@article{linked, title={New},}",key:"ABCD1234",library:"groups/123"))
        expectTrue(removed.hasPrefix("@article")); expectFalse(BibLaTeX.entries(removed).first!.fields.keys.contains("year"))
        let source = "// untouched\n#bibliography((\"works.bib\", \"/refs/二.yaml\"), style: \"styles/apa.csl\")\n"
        expectEqual(literalAssetPaths(source,ParsedSource.parse(source)),["works.bib","/refs/二.yaml","styles/apa.csl"])
        expectEqual(bibliographyCalls(source,ParsedSource.parse(source)).first?.inputs.count,2)
        let embedded = "#bibliography(bytes(\n```bib\n@book{key, title={A Book}}\n```.text\n), style: \"apa\")"
        expectEqual(bibliographyCalls(embedded,ParsedSource.parse(embedded)).first?.inputs.first?.embedded,"@book{key, title={A Book}}")
        let variable = "#let works = \"refs/works.bib\"\n#bibliography(works, style: \"apa\")"
        expectEqual(bibliographyCalls(variable,ParsedSource.parse(variable)).first?.inputs.first?.path,"refs/works.bib")
        let escape = "#include \"chapters/\\u{65e5}.typ\""
        expectEqual(DocumentBuffer(escape).includes.first?.path,"chapters/日.typ")
        let yaml = "# Comment\nmanual:\n  type: Book\n  title: Unrelated\n\nlinked:\n  type: Book\n  title: Old\n  # Keep custom notes\n  note: Custom\n  x-blank-zotero-key: \"ABCD1234\"\n  x-blank-zotero-library: \"personal\"\n"
        let revised = try! Hayagriva.merge(yaml,key:"linked",exported:"linked:\n  type: Book\n  title: New\n",itemKey:"ABCD1234",library:"personal")
        expectTrue(revised.hasPrefix(yaml.components(separatedBy:"linked:")[0])); expectTrue(revised.contains("  # Keep custom notes\n  note: Custom\n"))
        expectEqual(try! Hayagriva.linked(revised).first?.0,"linked")
        let indented = "linked: # preserve header\n    type: Book\n    title: Old\n    x-blank-zotero-key: ABCD1234\n    x-blank-zotero-library: users/0"
        let noNewline = try! Hayagriva.merge(indented,key:"linked",exported:"linked:\n  type: Book\n  title: New\n  date: 2026\n",itemKey:"ABCD1234",library:"users/0")
        expectTrue(noNewline.contains("linked: # preserve header\n    type: Book\n    title: New\n")); expectTrue(noNewline.contains("\n    date: 2026\n"))
        expectEqual(try! Hayagriva.linked(noNewline).first?.0,"linked")
        let model = DocumentBuffer(embedded); model.selection = EditSelection(0,0)
        model.commit(embedded+"\n日本",selection:EditSelection(embedded.utf8.count+7,embedded.utf8.count+7))
        model.undo(); expectEqual(model.source,embedded); expectEqual(model.selection,EditSelection(0,0))
    }
    @Test("Grouped history and selections")
    func testHistoryGroupingAndSelections() {
        let b = DocumentBuffer()
        b.commit("a",selection:EditSelection(1,1),group:"typing",now:1)
        b.commit("ab",selection:EditSelection(2,2),group:"typing",now:1.2)
        b.commit("abc",selection:EditSelection(3,3),group:"typing",now:1.4)
        b.undo(); expectEqual(b.source,""); expectEqual(b.selection,EditSelection(0,0))
        b.redo(); expectEqual(b.source,"abc"); expectEqual(b.selection,EditSelection(3,3))
        expectLessThan(b.historyBytes,10)
    }
    @Test("Cross-mark deletion")
    func testCrossMarkupDeletionRemainsValid() {
        let b = DocumentBuffer("plain *bold* middle _italic_ end")
        b.editWrite(NSRange(location:3,length:20),text:"X")
        expectFalse(b.source.contains("**"))
        b.undo(); expectEqual(b.source,"plain *bold* middle _italic_ end")
    }
    @Test("Code block shells, editing and history")
    func testCodeBlockEditing() {
        let shell = "#{\n  let café = \"日本 👋\"\n}"
        let original = "Before 👩🏽‍💻\n\n"+shell+"\n\nAfter // keep"
        func block(_ model: DocumentBuffer) -> ProjectedBlock { model.projection.blocks.first { $0.kind == "source" }! }
        for offset in [0,1,shell.utf16.count-1] {
            let model = DocumentBuffer(original), at = block(model).display.location+offset
            model.editWrite(NSRange(location:at,length:1),text:"")
            expectEqual(model.source,original); expectFalse(model.canUndo)
            model.editWrite(NSRange(location:at,length:1),text:"replacement")
            expectEqual(model.source,original)
            model.paste(RichFragment(source:"Text",plain:"Text",block:true),range:NSRange(location:at,length:1))
            expectEqual(model.source,original)
            model.split(NSRange(location:at,length:1)); expectEqual(model.source,original)
        }
        let model = DocumentBuffer(original), raw = block(model)
        model.editWrite(NSRange(location:raw.display.location+1,length:0),text:"x")
        expectEqual(model.source,original)
        let text = (model.projection.text as NSString).range(of:"café")
        model.editWrite(text,text:"résumé")
        expectEqual(model.source,original.replacingOccurrences(of:"café",with:"résumé"))
        model.undo(); expectEqual(model.source,original)
        model.selection = EditSelection(raw.source.end-2,raw.source.end-2)
        let at = model.projection.displayOffset(at:model.selection.focus)
        model.split(NSRange(location:at,length:0))
        expectTrue(model.source.contains("\"日本 👋\"\n  \n}")); expectFalse(model.parsed.erroneous)
        model.undo(); expectEqual(model.source,original)
        model.editWrite(block(model).display,text:"")
        expectFalse(model.source.contains(shell)); expectTrue(model.source.contains("After // keep"))
        model.undo(); expectEqual(model.source,original)
        model.redo(); expectFalse(model.source.contains(shell))
        model.undo()
        model.editSource(NSRange(location:model.source.utf16Offset(byte:raw.source.end-1),length:1),text:"")
        expectFalse(model.source.contains("\n}")); model.undo(); expectEqual(model.source,original)
        // An unfinished string must not make the known closing brace editable.
        let body = (model.projection.text as NSString).range(of:"let café = \"日本 👋\"")
        model.editWrite(body,text:"let café = \"")
        expectTrue(model.parsed.erroneous)
        let incomplete = model.source
        let closingByte = incomplete.range(of:"\n}\n")!.lowerBound
        let close = incomplete[..<closingByte].utf8.count+1
        let closeDisplay = model.projection.displayOffset(at:close)
        model.editWrite(NSRange(location:closeDisplay,length:1),text:"")
        expectEqual(model.source,incomplete)
        let copy = model.editingCopy(); copy.editWrite(NSRange(location:closeDisplay,length:1),text:"")
        expectEqual(copy.source,incomplete)
        model.undo(); expectEqual(model.source,original)
        // Offsets remain correct after moving the shell past Unicode prose.
        model.editSource(NSRange(location:0,length:0),text:"日本 👋 ")
        let shifted = block(model)
        model.editWrite(NSRange(location:shifted.display.location,length:1),text:"")
        expectTrue(model.source.hasPrefix("日本 👋 Before")); expectTrue(model.source.contains(shell))
    }
    @Test("Consecutive code")
    func testConsecutiveCodeBlocksStayTogether() {
        let b = DocumentBuffer("#set text(size: 11pt)\n#let custom = 3\n#show heading: it => it\n\nBody")
        expectEqual(b.projection.blocks.filter { $0.kind == "source" }.count,1)
        expectTrue(b.projection.blocks[0].text.contains("#show"))
    }
    @Test("Section movement")
    func testMoveSectionPreservesNestedSource() {
        let original = "= First\n\nA\n\n== Child\n\n#custom\n\n= Second\n\nB\n"
        let b = DocumentBuffer(original)
        let target = b.projection.blocks.firstIndex { $0.text == "Second" }!
        b.moveSection(target,before:0)
        expectTrue(b.source.hasPrefix("= Second")); expectTrue(b.source.contains("== Child\n\n#custom"))
        b.undo(); expectEqual(b.source,original)
        let last = b.projection.blocks.firstIndex { $0.text == "Second" }!
        expectTrue(b.moveSection(0,after:last))
        expectTrue(b.source.hasPrefix("= Second\n\nB\n"))
        expectTrue(b.source.hasSuffix("= First\n\nA\n\n== Child\n\n#custom\n\n"))
        let moved = b.source, selection = b.selection
        b.undo(); expectEqual(b.source,original)
        b.redo(); expectEqual(b.source,moved); expectEqual(b.selection,selection)
        let end = DocumentBuffer("= First\n\n日本 👋\n\n= Last\n\nTail")
        expectTrue(end.moveSection(0,after:end.projection.blocks.firstIndex { $0.text == "Last" }!))
        expectTrue(end.source.contains("Tail\n\n= First\n\n日本 👋"))
        expectFalse(end.parsed.erroneous)
        expectFalse(end.moveSection(0,after:0))
    }
    @Test("Section parent movement")
    func testMoveSectionAcrossParents() {
        let original = "= Alpha\n\n// intro\n\n== Shared\n\n日本 👋 *bold*\n\n=== Nested\n\n#let custom = 42\n\n== Remaining\n\nKeep\n\n= Beta\n\nIntro\n\n== Existing\n\nBody\n\n= Empty\n"
        let b = DocumentBuffer(original)
        func heading(_ title: String,_ level: Int) -> Int { b.projection.blocks.firstIndex { $0.kind == "heading" && $0.text == title && $0.level == level }! }
        let raw = "== Shared\n\n日本 👋 *bold*\n\n=== Nested\n\n#let custom = 42\n\n"
        expectTrue(b.moveSection(heading("Shared",2),into:heading("Beta",1)))
        expectTrue(b.source.contains("== Existing\n\nBody\n\n"+raw+"= Empty"))
        expectTrue(b.source.hasPrefix("= Alpha\n\n// intro\n\n== Remaining"))
        expectFalse(b.parsed.erroneous)
        let moved = b.source, selection = b.selection
        b.undo(); expectEqual(b.source,original)
        b.redo(); expectEqual(b.source,moved); expectEqual(b.selection,selection)
        b.undo()
        expectTrue(b.moveSection(heading("Shared",2),into:heading("Empty",1)))
        expectTrue(b.source.hasSuffix("= Empty\n\n"+raw))
        b.undo(); expectEqual(b.source,original)
        // Same-level insertion changes parents naturally without changing heading levels.
        expectTrue(b.moveSection(heading("Shared",2),before:heading("Existing",2)))
        expectTrue(b.source.contains("= Beta\n\nIntro\n\n"+raw+"== Existing"))
        b.undo()
        expectTrue(b.moveSection(heading("Nested",3),into:heading("Existing",2)))
        expectTrue(b.source.contains("== Existing\n\nBody\n\n=== Nested\n\n#let custom = 42"))
        b.undo()
        expectFalse(b.moveSection(heading("Alpha",1),into:heading("Nested",3)))
        expectFalse(b.moveSection(heading("Shared",2),into:heading("Nested",3)))
        expectFalse(b.moveSection(heading("Shared",2),into:heading("Shared",2)))
        expectFalse(b.moveSection(heading("Remaining",2),into:heading("Alpha",1)))
        expectFalse(b.moveSection(heading("Shared",2),after:heading("Nested",3)))
        expectEqual(b.source,original)
        let crlf = DocumentBuffer("= A\r\n\r\n== Child\r\n\r\n日本\r\n\r\n= B\r\n")
        let child = crlf.projection.blocks.firstIndex { $0.text == "Child" }!
        let parent = crlf.projection.blocks.firstIndex { $0.text == "B" }!
        expectTrue(crlf.moveSection(child,into:parent))
        expectEqual(crlf.source,"= A\r\n\r\n= B\r\n\r\n== Child\r\n\r\n日本\r\n\r\n")
    }
    @Test("Formatting toggles")
    func testFormatTogglePreservesOtherMarks() {
        let b = DocumentBuffer("plain *bold and _italic_* tail")
        let range = NSRange(location:6,length:15)
        b.format(range,italic:false)
        expectEqual(b.projection.text,"plain bold and italic tail")
        expectFalse(b.projection.blocks[0].inlines.flatMap(\.runs).contains { $0.style.bold })
        expectTrue(b.projection.blocks[0].inlines.flatMap(\.runs).contains { $0.style.italic })
        b.format(range,italic:false)
        expectTrue(b.projection.blocks[0].inlines.flatMap(\.runs).contains { $0.style.bold })
    }
    @Test("Incremental spaces and Unicode")
    func testIncrementalSpacesAndUnicode() {
        let b = DocumentBuffer()
        let text = "A quiet café 👩🏽‍💻"
        for character in text.unicodeScalars {
            let at = b.projection.displayOffset(at:b.selection.focus)
            b.editWrite(NSRange(location:at,length:0),text:String(character))
        }
        expectEqual(b.projection.text,text)
        b.undo(); expectEqual(b.source,"")
    }
    @Test("Paragraph-end whitespace with full parsing, citations and history")
    func testParagraphEndWhitespace() {
        for prefix in ["Café 👩🏽‍💻", "*Café 👩🏽‍💻*", "= Café 👩🏽‍💻", "- Café 👩🏽‍💻", "+ Café 👩🏽‍💻"] {
            let original = DocumentBuffer(prefix)
            for spaces in [" ","  ","\t"] {
                for ending in ["","\n","\r\n","\n\nNext","\r\n\r\nNext"] {
                    let source = prefix+spaces+ending, buffer = DocumentBuffer(source)
                    let block = buffer.projection.blocks[0]
                    expectEqual(block.kind,original.projection.blocks[0].kind)
                    if block.text != original.projection.text+spaces { print("Whitespace fixture: prefix=\(prefix.debugDescription) ending=\(ending.debugDescription) kind=\(block.kind) actual=\(block.text.debugDescription)") }
                    expectEqual(block.text,original.projection.text+spaces)
                    let end = prefix.utf8.count+spaces.utf8.count
                    expectEqual(buffer.projection.sourceOffset(at:NSMaxRange(block.display)),end)
                    expectEqual(buffer.projection.displayOffset(at:end),NSMaxRange(block.display))
                    expectEqual(buffer.source,source)
                    if prefix.hasPrefix("*") {
                        expectFalse(block.inlines.flatMap(\.runs).last!.style.bold)
                    }
                }
            }
        }
        for deletedCitation in [false,true] {
            let original = "Café 👩🏽‍💻\n\n#cite(<book>);\n\n#bibliography(\"references.yml\")\n\nNext"
            let buffer = DocumentBuffer(original)
            func reference(_ text: String,_ kind: String) -> ReferencePresentation {
                let range = (original as NSString).range(of:text)
                return ReferencePresentation(source:ByteSpan(original.byteOffset(utf16:range.location),original.byteOffset(utf16:NSMaxRange(range))),text:kind == "citation" ? "[1]" : "Book",kind:kind)
            }
            buffer.setReferencePresentations([reference("#cite(<book>);","citation"),reference("#bibliography(\"references.yml\")","bibliography")])
            if deletedCitation {
                let range = buffer.projection.atomicRanges.first!
                buffer.selection = EditSelection(buffer.projection.sourceOffset(at:range.location),buffer.projection.sourceOffset(at:NSMaxRange(range)))
                buffer.editWrite(range,text:"",group:"")
                expectTrue(buffer.renderedReferences.contains { $0.kind == "bibliography" })
            }
            let before = buffer.source, block = buffer.projection.blocks[0]
            let sourceEnd = buffer.projection.sourceOffset(at:NSMaxRange(block.display))
            buffer.selection = EditSelection(sourceEnd,sourceEnd)
            for (index,text) in [" "," ","suite 日本"].enumerated() {
                let at = buffer.projection.displayOffset(at:buffer.selection.focus)
                buffer.editWrite(NSRange(location:at,length:0),text:text,group:"")
                let inserted = index == 0 ? " " : index == 1 ? "  " : "  suite 日本"
                expectEqual(buffer.source,before.replacingBytes(ByteSpan(sourceEnd,sourceEnd),with:inserted))
                expectEqual(buffer.projection.blocks[0].text,block.text+inserted)
                expectEqual(buffer.projection.blockIndex(at:buffer.projection.displayOffset(at:buffer.selection.focus)),0)
                expectEqual(buffer.selection,EditSelection(sourceEnd+inserted.utf8.count,sourceEnd+inserted.utf8.count))
                let full = Projection(source:buffer.source,parsed:ParsedSource.parse(buffer.source),references:buffer.renderedReferences)
                expectEqual(buffer.projection.text,full.text)
                expectEqual(buffer.projection.blocks.map(\.source),full.blocks.map(\.source))
                expectEqual(full.sourceOffset(at:full.displayOffset(at:buffer.selection.focus)),buffer.selection.focus)
            }
            buffer.undo(); buffer.undo(); buffer.undo()
            expectEqual(buffer.source,before); expectEqual(buffer.selection,EditSelection(sourceEnd,sourceEnd))
            buffer.redo(); buffer.redo(); buffer.redo()
            expectEqual(buffer.source,before.replacingBytes(ByteSpan(sourceEnd,sourceEnd),with:"  suite 日本"))
            expectEqual(buffer.projection.blocks[0].text,block.text+"  suite 日本")
        }
    }
    @Test("Empty paragraph whitespace, native cell mapping and structural trivia")
    func testEmptyParagraphWhitespace() {
        for source in [" "," \n\n#bibliography(\"r.bib\")","Before\n\n ","Before\n\n \n\nNext","Before\r\n\r\n \r\n\r\nNext","#let x = 1\n\n \n\nNext"] {
            let buffer = DocumentBuffer(source)
            let index = buffer.projection.blocks.firstIndex { $0.kind == "paragraph" && $0.text == " " }!
            let block = buffer.projection.blocks[index], end = NSMaxRange(block.display)
            expectEqual(block.source.count,1); expectEqual(block.body,block.source)
            let byte = buffer.projection.sourceOffset(at:end)
            expectEqual(buffer.projection.displayOffset(at:byte),end)
            buffer.selection = EditSelection(byte,byte)
            buffer.editWrite(NSRange(location:end,length:0),text:"x",group:"")
            expectEqual(buffer.source,source.replacingBytes(ByteSpan(byte,byte),with:"x"))
            expectEqual(buffer.projection.blocks[index].text," x")
            expectEqual(buffer.projection.text,DocumentBuffer(buffer.source).projection.text)
            buffer.undo(); expectEqual(buffer.source,source); expectEqual(buffer.selection,EditSelection(byte,byte))
            buffer.redo(); expectEqual(buffer.projection.blocks[index].text," x")
        }
        for source in ["= Title ","- Item ","+ Item ","#align(center)[Title]  ","#quote[Title]  ","#let x = 1  ","  #let x = 1"] {
            let buffer = DocumentBuffer(source)
            expectEqual(buffer.projection.blocks.count,1)
            expectEqual(buffer.source,source)
        }
        let indented = DocumentBuffer("Before\n\n  Next")
        expectEqual(indented.projection.blocks[1].text,"  Next")
        for offset in 0...6 {
            let block = indented.projection.blocks[1], display = block.display.location+offset
            expectEqual(indented.projection.sourceOffset(at:display),block.body.start+offset)
            expectEqual(indented.projection.displayOffset(at:block.body.start+offset),display)
        }
        for source in ["Before\n\n  #let x = 1","Before\n\n  // keep","Before\n\n  #align(center)[Title]","Before\n\n  #quote[Title]","Before\n\n  #figure[Title]","Before\n\n  #table(columns:1,[Title])","Before\n\n  = Heading","Before\n\n  - Item"] {
            let buffer = DocumentBuffer(source)
            expectEqual(buffer.projection.blocks.count,2)
            expectEqual(buffer.source,source)
            expectFalse(buffer.projection.blocks.contains { $0.text == "  " })
        }
        let source = "// Preserve options\n#table(columns:1,inset:8pt,[ ])\n\n#bibliography(\"r.bib\")"
        let buffer = DocumentBuffer(source), table = buffer.projection.blocks.first { $0.kind == "table" }!
        expectEqual(table.cellProjections[0].text," ")
        let end = table.display.location+NSMaxRange(table.cellRanges[0]), byte = buffer.projection.sourceOffset(at:end)
        buffer.selection = EditSelection(byte,byte); buffer.editWrite(NSRange(location:end,length:0),text:"日本",group:"")
        expectEqual(buffer.source,source.replacingBytes(ByteSpan(byte,byte),with:"日本"))
        expectEqual(buffer.projection.blocks.first { $0.kind == "table" }!.cellProjections[0].text," 日本")
        buffer.undo(); expectEqual(buffer.source,source); expectEqual(buffer.selection,EditSelection(byte,byte))
        buffer.redo(); expectEqual(buffer.source,source.replacingBytes(ByteSpan(byte,byte),with:"日本"))
    }
    @Test("Local projection equals full parsing")
    func testLocalProjectionMatchesFullParse() {
        let original = "// keep\n#set text(size: 11pt)\n\n= Heading\n\nA *bold* paragraph.\n\n- An _item_\n\n#custom(1)\n\nLast 👋 paragraph."
        let b = DocumentBuffer(original)
        for index in [2,3,5] {
            guard b.projection.blocks.indices.contains(index), b.projection.blocks[index].editable else { continue }
            let block = b.projection.blocks[index]
            b.editWrite(NSRange(location:block.display.location+min(2,block.display.length),length:0),text:"café")
            let full = DocumentBuffer(b.source)
            expectEqual(b.projection.text,full.projection.text)
            expectEqual(b.projection.blocks.map(\.source),full.projection.blocks.map(\.source))
            for offset in 0...b.projection.text.utf16.count { expectEqual(b.projection.sourceOffset(at:offset),full.projection.sourceOffset(at:offset)) }
        }
        expectTrue(b.source.hasPrefix("// keep\n#set text(size: 11pt)"))
        expectEqual(b.parsed.tree.end,b.source.utf8.count)
    }
    @Test("Typing inside formatting")
    func testTypingInsideFormattingKeepsWrappers() {
        let b = DocumentBuffer("A *bold* and #link(\"https://typst.app\")[café].")
        b.editWrite(NSRange(location:4,length:0),text:"X")
        expectEqual(b.source,"A *boXld* and #link(\"https://typst.app\")[café].")
        expectFalse(b.parsed.erroneous)
        let link = (b.projection.text as NSString).range(of:"café")
        b.editWrite(NSRange(location:link.location+3,length:1),text:"è")
        expectTrue(b.source.contains("[cafè]")); expectFalse(b.parsed.erroneous)
        b.undo(); b.undo(); expectEqual(b.source,"A *bold* and #link(\"https://typst.app\")[café].")
    }
    @Test("Empty headings and lists")
    func testEmptyStructuredBlockInsertion() {
        for original in ["/", "Before\n\n/", "Before\n\n/\n\nAfter", "Before\n\n/\n\n"] {
            for (kind,marker) in [("heading","= "),("bullet","- "),("number","+ ")] {
                let b = DocumentBuffer(original), slash = (b.projection.text as NSString).range(of:"/")
                let index = b.projection.blockIndex(at:slash.location)
                b.editWrite(slash,text:"",group:"")
                b.setKind(at:NSRange(location:b.projection.displayOffset(at:b.selection.focus),length:0),kind:kind,level:1)
                expectEqual(b.source,original.replacingOccurrences(of:"/",with:marker))
                expectEqual(b.projection.displayOffset(at:b.selection.focus),b.projection.blocks[index].display.location)
                expectEqual(b.projection.blocks[index].body.start,b.selection.focus)
                b.editWrite(NSRange(location:b.projection.displayOffset(at:b.selection.focus),length:0),text:"Café 👩🏽‍💻",group:"")
                expectEqual(b.projection.blocks[index].text,"Café 👩🏽‍💻")
                b.undo(); b.undo(); b.undo(); expectEqual(b.source,original)
            }
        }
        for original in ["- First\n- ", "+ First\n+ ", "- First\n- \n- Third"] {
            let b = DocumentBuffer(original), index = 1
            b.selection = EditSelection(b.projection.blocks[index].body.start,b.projection.blocks[index].body.start)
            b.setKind(index,kind:"paragraph")
            expectEqual(b.projection.blocks[index].kind,"paragraph")
            expectEqual(b.projection.blocks[index].text,"")
            expectEqual(b.projection.displayOffset(at:b.selection.focus),b.projection.blocks[index].display.location)
            b.editWrite(NSRange(location:b.projection.displayOffset(at:b.selection.focus),length:0),text:"Body 👋",group:"")
            expectEqual(b.projection.blocks[index].text,"Body 👋")
            b.undo(); b.undo(); expectEqual(b.source,original)
        }
        for (kind,level,prefix) in [("heading",2,"== "),("bullet",0,"- "),("number",0,"+ ")] {
            let b = DocumentBuffer(); b.setKind(0,kind:kind,level:level)
            for c in "A café" { b.editWrite(NSRange(location:b.projection.text.utf16.count,length:0),text:String(c)) }
            expectEqual(b.source,prefix+"A café"); expectEqual(b.projection.blocks[0].kind,kind)
            expectEqual(b.projection.text,"A café")
        }
    }
    @Test("Rendered references preserve canonical source")
    func testRenderedReferencesPreserveSource() {
        let original = "// Keep café\n\nBefore #cite(<smith>, supplement: [p. 7]) after.\n\n#bibliography(\"works.bib\", style: \"apa\")"
        let b = DocumentBuffer(original)
        let cite = (original as NSString).range(of:"#cite(<smith>, supplement: [p. 7])")
        let bib = (original as NSString).range(of:"#bibliography(\"works.bib\", style: \"apa\")")
        let citeSpan = ByteSpan(original.byteOffset(utf16:cite.location),original.byteOffset(utf16:NSMaxRange(cite)))
        let bibSpan = ByteSpan(original.byteOffset(utf16:bib.location),original.byteOffset(utf16:NSMaxRange(bib)))
        b.setReferencePresentations([ReferencePresentation(source:citeSpan,text:"(Smith, 2020, p. 7)"),ReferencePresentation(source:bibSpan,text:"References\n\nSmith, J. (2020). Book.",kind:"bibliography")])
        expectEqual(b.source,original); expectFalse(b.canUndo)
        expectTrue(b.projection.text.contains("(Smith, 2020, p. 7)")); expectFalse(b.projection.text.contains("#cite")); expectFalse(b.projection.text.contains("#bibliography"))
        let rendered = (b.projection.text as NSString).range(of:"(Smith, 2020, p. 7)")
        expectEqual(b.projection.sourceOffset(at:rendered.location),citeSpan.start)
        expectEqual(b.projection.sourceOffset(at:NSMaxRange(rendered)),citeSpan.end)
        let copied = b.copy(NSRange(location:rendered.location+2,length:3))
        expectEqual(copied.source,original.bytes(citeSpan)); expectEqual(copied.plain,"(Smith, 2020, p. 7)")
        b.editWrite(NSRange(location:rendered.location,length:0),text:"日本 ",group:"")
        expectTrue(b.projection.text.contains("日本 (Smith, 2020, p. 7)"))
        let shifted = (b.projection.text as NSString).range(of:"(Smith, 2020, p. 7)")
        b.editWrite(NSRange(location:NSMaxRange(shifted)-1,length:1),text:"",group:"")
        expectFalse(b.source.contains("#cite")); expectTrue(b.source.hasPrefix("// Keep café")); expectTrue(b.source.contains("#bibliography"))
        b.undo(); b.undo(); expectEqual(b.source,original)
        let table = DocumentBuffer("#table(columns: 1, [Before #cite(<smith>) after])")
        let span = (table.source as NSString).range(of:"#cite(<smith>)")
        table.setReferencePresentations([ReferencePresentation(source:ByteSpan(span.location,NSMaxRange(span)),text:"(Smith, 2020)")])
        let displayed = (table.projection.text as NSString).range(of:"(Smith, 2020)")
        expectEqual(table.copy(displayed).source,"#cite(<smith>)")
        expectEqual(table.copy(displayed).plain,"(Smith, 2020)")
        table.editWrite(NSRange(location:displayed.location,length:0),text:"日本 ",group:"")
        expectTrue(table.source.contains("[Before 日本 #cite(<smith>) after]"))
        table.undo(); expectEqual(table.source,"#table(columns: 1, [Before #cite(<smith>) after])")
        for original in ["#emph[#cite(<smith>)] #cite(<doe>).", "*#cite(<smith>)* #cite(<doe>).", "#cite(<smith>) *#cite(<doe>)*.", "#emph[日本 before #cite(<smith>)] #cite(<doe>).", "#cite(<smith>) *#cite(<doe>) after*.", "#cite(<smith>) /* keep */ #cite(<doe>).", "#cite(<smith>) // café keep\n#cite(<doe>)."] {
            let grouped = DocumentBuffer(original)
            let first = original.range(of:"#cite")!.lowerBound, last = original.range(of:")",options:.backwards)!.upperBound
            grouped.setReferencePresentations([ReferencePresentation(source:ByteSpan(original[..<first].utf8.count,original[..<last].utf8.count),text:"(Doe, 2021; Smith, 2020)")])
            expectTrue(grouped.projection.text.contains("(Doe, 2021; Smith, 2020)")); expectFalse(grouped.projection.text.contains("Citation"))
            if original.contains("before") { expectTrue(grouped.projection.text.hasPrefix("日本 before ")) }
            if original.contains("after") { expectTrue(grouped.projection.text.hasSuffix(" after.")) }
            let range = grouped.projection.atomicRanges.first!
            let fragment = grouped.copy(range)
            expectEqual(fragment.source,String(original.dropLast()))
            let pasted = DocumentBuffer(); pasted.paste(fragment,range:NSRange(location:0,length:0)); expectFalse(pasted.parsed.erroneous)
            grouped.editWrite(range,text:""); expectFalse(grouped.parsed.erroneous); expectEqual(grouped.source,".")
            grouped.undo(); expectEqual(grouped.source,original)
        }
        let overlapSource = "#cite(<a>) *#cite(<b>) middle #cite(<c>)* #cite(<d>)."
        let overlap = DocumentBuffer(overlapSource)
        let bEnd = overlapSource.range(of:"#cite(<b>)")!.upperBound, cStart = overlapSource.range(of:"#cite(<c>)")!.lowerBound
        overlap.setReferencePresentations([ReferencePresentation(source:ByteSpan(0,overlapSource[..<bEnd].utf8.count),text:"(A; B)"),ReferencePresentation(source:ByteSpan(overlapSource[..<cStart].utf8.count,overlapSource.utf8.count-1),text:"(C; D)")])
        expectEqual(overlap.projection.text,"(A; B) middle (C; D).")
        expectEqual(overlap.copy(overlap.projection.atomicRanges.first!).source,String(overlapSource.dropLast()))
        expectEqual(overlap.renderedReferences.count,1)
        for original in ["*Before #cite(<smith>) after*.", "#emph[日本 Before #cite(<smith>) after].", "#table(columns: 1, [*Before #cite(<smith>) after*])"] {
            let single = DocumentBuffer(original), raw = original.range(of:"#cite(<smith>)")!
            single.setReferencePresentations([ReferencePresentation(source:ByteSpan(original[..<raw.lowerBound].utf8.count,original[..<raw.upperBound].utf8.count),text:"(Smith, 2020)")])
            let before = (single.projection.text as NSString).range(of:"Before")
            expectFalse(single.copy(before).source.contains("#cite"))
            single.editWrite(before,text:"Updated")
            expectTrue(single.source.contains("#cite(<smith>)")); expectTrue(single.source.contains("after")); expectFalse(single.parsed.erroneous)
            single.undo(); expectEqual(single.source,original)
        }
    }
    @Test("Formatting inside words")
    func testExplicitFormattingInsideWords() {
        let b = DocumentBuffer("word")
        b.format(NSRange(location:1,length:2),italic:false)
        expectEqual(b.projection.text,"word"); expectFalse(b.parsed.erroneous)
        var style = TextStyle(); style.bold = true
        let empty = DocumentBuffer(); empty.editWrite(NSRange(location:0,length:0),text:"A",styleOverride:style)
        expectEqual(empty.projection.text,"A"); expectTrue(empty.projection.blocks[0].editable)
        empty.editWrite(NSRange(location:1,length:0),text:"B",styleOverride:style)
        style.bold = false; empty.editWrite(NSRange(location:2,length:0),text:"C",styleOverride:style)
        expectEqual(empty.projection.text,"ABC"); expectFalse(empty.parsed.erroneous)
        expectFalse(empty.projection.blocks[0].inlines.flatMap(\.runs).last!.style.bold)
    }
    @Test("Literal includes and prose statistics")
    func testIncludesAndStatistics() {
        let b = DocumentBuffer("// #include \"ignored.typ\"\n#include \"chapters/one.typ\"\n\n= Title\n\nHello *café* 👋\n\n#let hidden = \"not prose\"\n\n#table(columns: 2, [One], [Two])")
        expectEqual(b.includes.map(\.path),["chapters/one.typ"])
        expectEqual(b.counts.words,5); expectEqual(b.counts.headings,1)
        expectEqual(b.counts.characters,"TitleHello café 👋OneTwo".unicodeScalars.count)
        b.editSource(NSRange(location:b.source.utf16.count,length:0),text:"\n\nMore words")
        expectEqual(b.counts.words,7); b.undo(); expectEqual(b.counts.words,5)
        let cell = DocumentBuffer("#table(columns: 1, [#link(\"https://typst.app\")[A]])")
        expectEqual(cell.projection.blocks[0].tableCells.count,1)
    }
    @Test("Include movement and conditional boundaries")
    func testIncludeMovementPreservesSource() {
        let source = "#include \"a.typ\" // a\r\n// untouched\r\n#include \"β.typ\" // b\r\n\n#if true [#include \"dynamic.typ\"]"
        let b = DocumentBuffer(source)
        expectEqual(b.includes.map(\.path),["a.typ","β.typ"])
        expectTrue(b.moveInclude(1,before:0))
        expectEqual(b.source,"#include \"β.typ\" // b\r\n// untouched\r\n#include \"a.typ\" // a\r\n\n#if true [#include \"dynamic.typ\"]")
        b.undo(); expectEqual(b.source,source); b.redo(); expectEqual(b.includes.map(\.path),["β.typ","a.typ"])
        b.undo(); expectTrue(b.moveInclude(0,after:1))
        expectEqual(b.source,"#include \"β.typ\" // b\r\n// untouched\r\n#include \"a.typ\" // a\r\n\n#if true [#include \"dynamic.typ\"]")
        b.undo(); expectEqual(b.source,source)
        let inline = DocumentBuffer("Before #include \"a.typ\"\n#include \"b.typ\"")
        expectFalse(inline.moveInclude(1,before:0))
    }
    @Test("Literal dependencies ignore commented examples")
    func testLiteralDependenciesIgnoreComments() {
        let source = "// #image(\"not-real.png\")\n`#read(\"example.csv\")`\n#import \"tools.typ\": *\n#image(\"a\\\"b.png\")\n#read(\"table.csv\")\n#bibliography(\"refs.bib\", style: \"custom.csl\")"
        let b = DocumentBuffer(source)
        expectEqual(b.imports.map(\.path),["tools.typ"])
        expectEqual(literalAssetPaths(source,b.parsed),["a\"b.png","table.csv","refs.bib","custom.csl"])
    }
    @Test("Unicode patch round trips")
    func testRandomUnicodePatchRoundtrip() {
        let pool = ["a","é","😀","中","e\u{301}","\n","*","\\"]
        for i in 0..<200 {
            let old = (0..<20).map { pool[($0+i)%pool.count] }.joined(), new = (0..<15).map { pool[($0*3+i)%pool.count] }.joined()
            let p = SourcePatch.difference(old,new)!
            expectEqual(old.replacingBytes(p.oldSpan,with:p.inserted),new)
            expectEqual(new.replacingBytes(p.newSpan,with:p.removed),old)
        }
    }
    @Test("Lossless table cells, mapping and history")
    func testLosslessTableEditing() {
        let original = "// before\n#let custom = 42\n\n#table(\n  columns: 2,\n  stroke: 0.5pt, // keep this option\n  [*Café* 👩🏽‍💻], [_Next_],\n  [], [#custom],\n)\n\nAfter _table_."
        let model = DocumentBuffer(original)
        func range(_ cell: Int) -> NSRange {
            let block = model.projection.blocks.first { !$0.cellRanges.isEmpty }!, local = block.cellRanges[cell]
            return NSRange(location:block.display.location+local.location,length:local.length)
        }
        let table = model.projection.blocks.first { !$0.cellRanges.isEmpty }!
        expectEqual(table.cellProjections.count,4)
        for (index,span) in table.tableCells.enumerated() {
            let local = table.cellProjections[index]
            for offset in 0...local.text.utf16.count {
                expectEqual(model.projection.sourceOffset(at:table.display.location+table.cellRanges[index].location+offset),span.start+local.sourceOffset(at:offset))
            }
            for run in local.blocks.flatMap(\.inlines).flatMap(\.runs) where run.literal {
                for character in 1..<max(1,run.text.utf16.count) {
                    let byte = span.start+run.source.start+run.text.byteOffset(utf16:character)
                    let at = model.projection.displayOffset(at:byte)
                    expectEqual(model.projection.sourceOffset(at:at),span.start+local.sourceOffset(at:at-table.display.location-table.cellRanges[index].location))
                }
            }
        }
        model.selection = EditSelection(table.tableCells[0].start+1,table.tableCells[0].start+1)
        model.editWrite(NSRange(location:range(0).location+2,length:0),text:"日本")
        expectTrue(model.source.contains("[*Ca日本fé* 👩🏽‍💻]"))
        expectTrue(model.source.contains("stroke: 0.5pt, // keep this option"))
        expectTrue(model.source.contains("[_Next_],\n  [], [#custom]"))
        model.undo(); expectEqual(model.source,original)
        model.redo(); expectFalse(model.parsed.erroneous)
        model.format(range(1),italic:false)
        expectTrue(model.source.contains("[*_Next_*]"))
        let fragment = model.copy(range(1))
        model.paste(fragment,range:range(2))
        expectTrue(model.source.contains("[*_Next_*], [#custom]"))
        let end = NSMaxRange(range(2)), sourceEnd = model.projection.sourceOffset(at:end)
        model.selection = EditSelection(sourceEnd,sourceEnd)
        model.split(NSRange(location:end,length:0))
        expectTrue(model.source.contains("[*_Next_*\n\n], [#custom]"))
        expectFalse(model.parsed.erroneous)
        model.undo(); expectTrue(model.source.contains("[*_Next_*], [#custom]"))
        let beforeSelection = model.source
        model.editWrite(NSRange(location:range(0).location+2,length:NSMaxRange(range(1))-range(0).location-2),text:"X")
        expectFalse(model.parsed.erroneous)
        expectTrue(model.projection.blocks.first { !$0.cellRanges.isEmpty }!.cellProjections[0].text.hasPrefix("CaX"))
        expectTrue(model.source.contains("stroke: 0.5pt, // keep this option"))
        expectEqual(model.projection.blocks.first { !$0.cellRanges.isEmpty }!.tableCells.count,4)
        model.undo(); expectEqual(model.source,beforeSelection)
        let boundary = DocumentBuffer("Before\n\n#table(columns: 2, [A], [B])\n\nAfter")
        let grid = boundary.projection.blocks[1]
        boundary.editWrite(NSRange(location:grid.display.location-1,length:1),text:"")
        expectEqual(boundary.source,"Before\n\n#table(columns: 2, [A], [B])\n\nAfter")
        boundary.editWrite(NSRange(location:NSMaxRange(grid.display),length:1),text:"")
        expectEqual(boundary.source,"Before\n\n#table(columns: 2, [A], [B])\n\nAfter")
        let wholeTable = model.projection.blocks.first { !$0.cellRanges.isEmpty }!
        let copy = model.copy(wholeTable.display)
        expectEqual(copy.source,model.source.bytes(wholeTable.source))
        let target = DocumentBuffer(); target.paste(copy,range:NSRange(location:0,length:0))
        expectEqual(target.source,copy.source)
        model.editWrite(wholeTable.display,text:"")
        expectFalse(model.source.contains("#table(")); expectTrue(model.source.hasSuffix("After _table_."))
        model.undo(); expectEqual(model.source,beforeSelection)
    }
}

extension DocumentTests {
    @Test("Incomplete block markers remain visible")
    func testIncompleteBlockMarkersStayVisible() {
        for prefix in ["=","==","===","-","+"] {
            let model = DocumentBuffer()
            for character in prefix { model.editWrite(NSRange(location:model.projection.displayOffset(at:model.selection.focus),length:0),text:String(character)) }
            expectEqual(model.projection.text,prefix)
            expectEqual(model.projection.blocks[0].kind,"paragraph")
            model.editWrite(NSRange(location:prefix.utf16.count,length:0),text:" text")
            expectEqual(model.projection.text,prefix+" text")
            expectFalse(model.parsed.erroneous)
            model.undo(); expectEqual(model.source,"")
        }
    }
}
extension DocumentTests {
    @Test("Source folding preserves bytes and offsets")
    func testSourceFoldingPreservesBytesAndOffsets() {
        let raw = "#set text(size: 11pt)\n#let café = \"日本😀\"\n\nAfter *bold*"
        let model = DocumentBuffer(raw)
        let code = model.projection.blocks.firstIndex { $0.kind == "source" && $0.text.contains("\n") }!
        model.setSourceCollapsed(code,true)
        let block = model.projection.blocks[code]
        expectTrue(block.collapsed); expectFalse(block.text.contains("\n"))
        expectEqual(model.source,raw); expectFalse(model.canUndo)
        expectEqual(model.copy(block.display).source,raw.bytes(block.source))
        expectEqual(model.projection.sourceOffset(at:block.display.location),block.source.start)
        expectEqual(model.projection.sourceOffset(at:NSMaxRange(block.display)),block.source.end)
        let after = model.projection.blocks.last!
        model.editWrite(NSRange(location:NSMaxRange(after.display),length:0),text:"!")
        expectTrue(model.projection.blocks[code].collapsed)
        model.undo(); expectEqual(model.source,raw)
        model.setSourceCollapsed(code,false)
        expectEqual(model.projection.text,DocumentBuffer(raw).projection.text)
        expectEqual(model.projection.blocks[code].text,raw.bytes(block.source))
    }
    @Test("Table dimension transactions preserve source")
    func testTableDimensionsPreserveSource() {
        let raw = "// outside\n#table(columns: 2, inset: 9pt, // options\n [日本 *bold*], /* keep */ [B],\n [C], [D]\n)\n\nAfter"
        for column in [false,true] {
            for action in ["before","after","delete"] {
                let model = DocumentBuffer(raw), index = model.projection.blocks.firstIndex { !$0.cellRanges.isEmpty }!
                expectTrue(model.changeTable(index,cell:1,column:column,action:action))
                expectFalse(model.parsed.erroneous)
                expectTrue(model.source.contains("inset: 9pt, // options"))
                expectTrue(model.source.contains("/* keep */"))
                expectTrue(model.source.hasPrefix("// outside\n")); expectTrue(model.source.hasSuffix("\n\nAfter"))
                let block = model.projection.blocks[index]
                expectEqual(block.columns,column ? action == "delete" ? 1 : 3 : 2)
                expectEqual(block.tableCells.count,column ? action == "delete" ? 2 : 6 : action == "delete" ? 2 : 6)
                expectTrue(model.source.contains("[C]"))
                let afterSelection = model.selection
                model.undo(); expectEqual(model.source,raw)
                model.redo(); expectFalse(model.parsed.erroneous); expectEqual(model.selection,afterSelection)
            }
        }
        for complex in ["#table(columns: 2 + 2, [A], [B], [C], [D])", "#table(columns: 2, [A], [B], ..([C], [D]))", "#table(columns: 2, table.header[A][B], [C], [D])"] {
            let model = DocumentBuffer(complex)
            expectTrue(model.projection.blocks[0].cellRanges.isEmpty)
            expectEqual(model.projection.text,complex)
            expectFalse(model.changeTable(0,cell:0,column:true,action:"after"))
            expectEqual(model.source,complex)
        }
        let one = DocumentBuffer("#table(columns: 1, [Only])")
        expectFalse(one.changeTable(0,cell:0,column:true,action:"delete"))
        expectFalse(one.changeTable(0,cell:0,column:false,action:"delete"))
    }
}

// Keep existing assertions and their call sites while reporting failures through
// Swift Testing. These helpers have no dependency on the model implementation.
func expectEqual<T: Equatable>(_ a: T,_ b: T,location: SourceLocation = #_sourceLocation) { #expect(a == b, "Expected \(b), got \(a)", sourceLocation:location) }
func expectTrue(_ value: Bool,location: SourceLocation = #_sourceLocation) { #expect(value, sourceLocation:location) }
func expectFalse(_ value: Bool,location: SourceLocation = #_sourceLocation) { #expect(!value, sourceLocation:location) }
func expectLessThan<T: Comparable>(_ a: T,_ b: T,location: SourceLocation = #_sourceLocation) { #expect(a < b, sourceLocation:location) }
