import Foundation
import BlankCore

final class DocumentTests {
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
        XCTAssertEqual(model.literalLabels,["sec:cafe\u{301}","prose","fig:one","cell","nested","fig:one"])
        XCTAssertEqual(model.source,source)
        XCTAssertFalse(model.canUndo)
        model.editSource(NSRange(location:source.utf16.count,length:0),text:"\n<unsaved>",group:"")
        XCTAssertEqual(model.literalLabels.last,"unsaved")
        model.undo(); XCTAssertEqual(model.literalLabels.last,"fig:one")
        let standalone = DocumentBuffer("#ref(<sec:end.>);")
        XCTAssertEqual(standalone.projection.blocks[0].kind,"paragraph")
        XCTAssertEqual(standalone.projection.text,standalone.source)
        XCTAssertEqual(standalone.literalLabels,[])
        XCTAssertEqual(model.source,source)
    }
    func testUnicodeSourceOffsets() {
        let text = "a👩🏽‍💻e\u{301}日本"
        for byte in 0...text.utf8.count where byte == text.utf8.count || Array(text.utf8)[byte] & 0xC0 != 0x80 {
            XCTAssertEqual(text.byteOffset(utf16:text.utf16Offset(byte:byte)),byte)
        }
        XCTAssertEqual("😀".byteOffset(utf16:1),0)
    }
    func testProjectionAndLosslessEdit() {
        let original = "// a comment\n#set text(size: 11pt)\n#let custom = 42\n\n= Title\n\nA *bold* and _italic_ café 👋.\n\n#custom\n"
        let b = DocumentBuffer(original)
        let paragraph = b.projection.blocks.first { $0.text.hasPrefix("A ") }!
        XCTAssertEqual(paragraph.text,"A bold and italic café 👋.")
        XCTAssertTrue(paragraph.inlines.flatMap(\.runs).contains { $0.style.bold })
        b.editWrite(NSRange(location:paragraph.display.location+2,length:4),text:"strong")
        XCTAssertTrue(b.source.contains("// a comment\n#set text(size: 11pt)\n#let custom = 42"))
        XCTAssertTrue(b.source.hasSuffix("#custom\n"))
        XCTAssertTrue(b.projection.text.contains("A strong and italic café 👋."))
        b.undo(); XCTAssertEqual(b.source,original)
        b.redo(); XCTAssertTrue(b.projection.text.contains("strong"))
    }
    func testListContinueAndExit() {
        let b = DocumentBuffer("- first")
        b.selection = EditSelection(7,7)
        b.split(NSRange(location:5,length:0))
        XCTAssertTrue(b.source.contains("\n- "))
        XCTAssertEqual(b.projection.blocks.count,2)
        b.split(NSRange(location:b.projection.text.utf16.count,length:0))
        XCTAssertFalse(b.source.hasSuffix("- "))
    }
    func testDeletingCompleteMarks() {
        for marked in ["*café 👋*","_café 👋_","*_café 👋_*","#strong[#emph[café 👋]]","`café 👋`"] {
            let original = "// Keep\n= "+marked+"\n\n#let untouched = 42\n\nAfter"
            let model = DocumentBuffer(original), heading = model.projection.blocks.first { $0.kind == "heading" }!
            model.selection = EditSelection(model.projection.sourceOffset(at:heading.display.location),model.projection.sourceOffset(at:NSMaxRange(heading.display)))
            model.editWrite(heading.display,text:"",group:"")
            let cleared = "// Keep\n= \n\n#let untouched = 42\n\nAfter"
            XCTAssertEqual(model.source,cleared)
            XCTAssertEqual(model.projection.blocks.first { $0.kind == "heading" }!.text,"")
            let caret = model.projection.displayOffset(at:model.selection.focus)
            model.editWrite(NSRange(location:caret,length:0),text:"/",group:"")
            XCTAssertFalse(model.projection.blocks.first { $0.kind == "heading" }!.inlines.flatMap(\.runs).contains { $0.style.bold || $0.style.italic || $0.style.code })
            model.undo(); XCTAssertEqual(model.source,cleared)
            model.undo(); XCTAssertEqual(model.source,original)
            model.redo(); XCTAssertEqual(model.source,cleared)
        }
        let partial = DocumentBuffer("Before *bold* after")
        partial.editWrite(NSRange(location:8,length:2),text:"",group:"")
        XCTAssertEqual(partial.source,"Before *bd* after")
        let custom = DocumentBuffer("#strong(delta: 2)[abc]")
        custom.editWrite(custom.projection.blocks[0].display,text:"",group:"")
        XCTAssertEqual(custom.source,"#strong(delta: 2)[]")
    }
    func testParagraphJoinKeepsFormatting() {
        let b = DocumentBuffer("one *bold*\n\ntwo _italic_")
        let first = b.projection.blocks[0], second = b.projection.blocks[1]
        b.editWrite(NSRange(location:NSMaxRange(first.display),length:second.display.location-NSMaxRange(first.display)),text:"")
        XCTAssertEqual(b.projection.blocks.count,1)
        XCTAssertTrue(b.source.contains("*bold*")); XCTAssertTrue(b.source.contains("_italic_"))
        b.undo(); XCTAssertEqual(b.source,"one *bold*\n\ntwo _italic_")
    }
    func testParagraphAndLineBreaks() {
        let b = DocumentBuffer("First *bold* second")
        let at = "First bold".utf16.count
        b.selection = EditSelection(b.projection.sourceOffset(at:at),b.projection.sourceOffset(at:at))
        b.split(NSRange(location:at,length:0))
        XCTAssertEqual(b.projection.blocks.count,2)
        XCTAssertEqual(b.projection.blocks[0].text,"First bold")
        XCTAssertEqual(b.projection.blocks[1].text,"second")
        XCTAssertTrue(b.source.contains("*bold*\n\n"))
        b.undo(); XCTAssertEqual(b.source,"First *bold* second")
        b.lineBreak(NSRange(location:at,length:0))
        XCTAssertEqual(b.projection.blocks.count,1)
        XCTAssertEqual(b.projection.text,"First bold\u{2028}second")
        XCTAssertFalse(b.parsed.erroneous)
        XCTAssertEqual(b.projection.displayOffset(at:b.selection.focus),at+1)
        b.undo(); XCTAssertEqual(b.source,"First *bold* second")
        let list = DocumentBuffer("- First")
        list.lineBreak(NSRange(location:5,length:0))
        XCTAssertEqual(list.projection.blocks.count,1)
        XCTAssertEqual(list.projection.blocks[0].kind,"bullet")
        XCTAssertEqual(list.projection.text,"First\u{2028}")
        list.editWrite(NSRange(location:6,length:0),text:"next")
        XCTAssertEqual(list.projection.text,"First\u{2028}next")
        XCTAssertEqual(list.projection.blocks.count,1)
        XCTAssertFalse(list.parsed.erroneous)
        let empty = DocumentBuffer()
        empty.split(NSRange(location:0,length:0))
        XCTAssertEqual(empty.projection.blocks.count,2)
        empty.split(NSRange(location:1,length:0))
        XCTAssertEqual(empty.projection.blocks.count,3)
        empty.editWrite(NSRange(location:2,length:0),text:"Third")
        XCTAssertEqual(empty.projection.blocks.map(\.text),["","","Third"])
        let between = DocumentBuffer("First\n\nSecond")
        between.selection = EditSelection(5,5)
        between.split(NSRange(location:5,length:0))
        XCTAssertEqual(between.projection.blocks.map(\.text),["First","","Second"])
        XCTAssertEqual(between.projection.displayOffset(at:between.selection.focus),6)
        between.editWrite(NSRange(location:6,length:0),text:"Middle")
        XCTAssertEqual(between.projection.blocks.map(\.text),["First","Middle","Second"])
        let heading = DocumentBuffer("= Tutorial\n\nLearn by trying.")
        let headingEnd = NSMaxRange(heading.projection.blocks[0].display)
        let sourceEnd = heading.projection.sourceOffset(at:headingEnd)
        heading.selection = EditSelection(sourceEnd,sourceEnd)
        heading.split(NSRange(location:headingEnd,length:0))
        XCTAssertEqual(heading.projection.blocks.map(\.text),["Tutorial","","Learn by trying."])
        XCTAssertEqual(heading.projection.displayOffset(at:heading.selection.focus),headingEnd+1)
    }
    func testClipboardHeadingAndList() {
        let b = DocumentBuffer("== A *heading*\n\n- An _item_")
        let fragment = b.copy(NSRange(location:0,length:b.projection.text.utf16.count))
        let target = DocumentBuffer()
        target.paste(fragment,range:NSRange(location:0,length:0))
        XCTAssertEqual(target.source,b.source)
        XCTAssertEqual(target.projection.blocks[0].level,2)
        XCTAssertEqual(target.projection.blocks[1].kind,"bullet")
    }
    func testStructuredPasteAtCaret() {
        let heading = DocumentBuffer("= Heading"), fragment = heading.copy(NSRange(location:0,length:heading.projection.text.utf16.count))
        for (source,caret,expected) in [("HelloWorld",5,["Hello","Heading","World"]),("Café 👋*bold* tail",9,["Café 👋bo","Heading","ld tail"]),("- HelloWorld",5,["Hello","Heading","World"])] {
            let original = "// unchanged\n#set text(size: 11pt)\n\n"+source+"\n\n#custom"
            let target = DocumentBuffer(original), block = target.projection.blocks.first { $0.editable }!
            let range = NSRange(location:block.display.location+caret,length:0), at = target.projection.sourceOffset(at:range.location)
            target.selection = EditSelection(at,at)
            target.paste(fragment,range:range)
            XCTAssertEqual(target.projection.blocks.filter(\.editable).map(\.text),expected)
            XCTAssertFalse(target.parsed.erroneous)
            XCTAssertTrue(target.source.hasPrefix("// unchanged\n#set text(size: 11pt)\n\n")); XCTAssertTrue(target.source.hasSuffix("\n\n#custom"))
            XCTAssertEqual(target.projection.blocks.first { $0.text == "Heading" }?.kind,"heading")
            target.undo(); XCTAssertEqual(target.source,original); XCTAssertEqual(target.selection,EditSelection(at,at))
            target.redo(); XCTAssertEqual(target.projection.blocks.filter(\.editable).map(\.text),expected)
        }
    }
    func testTypstStringLiterals() {
        for text in ["assets/café image.png","../chapters/one.typ","https://typst.app/docs","a \"quote\" and \\ backslash"] {
            let literal = typstStringLiteral(text)
            XCTAssertFalse(literal.contains("\\/"))
            XCTAssertEqual(try! JSONDecoder().decode(String.self,from:Data(literal.utf8)),text)
            XCTAssertFalse(ParsedSource.parse("#let value = "+literal).erroneous)
        }
    }
    func testBibliographyPreservation() {
        let original = "% Keep café 日本\n@string{press = \"Press\"}\n@comment{Do not parse @book{fake,title={Fake}}}\n@book(other, title = {Unrelated}, year = 1999)\n@book{linked,\n  % Keep this comment\n  title = {Old {nested} title},\n  note = {Custom 👩🏽‍💻},\n  x-blank-zotero-key = {ABCD1234},\n  x-blank-zotero-library = {groups/123},\n}\n"
        let export = "@book{linked, title={New \"quoted\" 日本}, year={2026},}"
        let annotated = try! BibLaTeX.annotate(export,key:"ABCD1234",library:"groups/123")
        let updated = try! BibLaTeX.merge(original,key:"linked",exported:annotated)
        XCTAssertEqual(BibLaTeX.entries(original).map(\.key),["other","linked"])
        XCTAssertTrue(updated.hasPrefix(original.components(separatedBy:"@book{linked")[0]))
        XCTAssertTrue(updated.contains("% Keep this comment\n")); XCTAssertTrue(updated.contains("note = {Custom 👩🏽‍💻}"))
        XCTAssertEqual(BibLaTeX.linked(updated).first?.0.key,"linked")
        XCTAssertEqual(BibLaTeX.entries(updated).last?.value("title",in:updated),"New \"quoted\" 日本")
        let removed = try! BibLaTeX.merge(annotated,key:"linked",exported:BibLaTeX.annotate("@article{linked, title={New},}",key:"ABCD1234",library:"groups/123"))
        XCTAssertTrue(removed.hasPrefix("@article")); XCTAssertFalse(BibLaTeX.entries(removed).first!.fields.keys.contains("year"))
        let source = "// untouched\n#bibliography((\"works.bib\", \"/refs/二.yaml\"), style: \"styles/apa.csl\")\n"
        XCTAssertEqual(literalAssetPaths(source,ParsedSource.parse(source)),["works.bib","/refs/二.yaml","styles/apa.csl"])
        XCTAssertEqual(bibliographyCalls(source,ParsedSource.parse(source)).first?.inputs.count,2)
        let embedded = "#bibliography(bytes(\n```bib\n@book{key, title={A Book}}\n```.text\n), style: \"apa\")"
        XCTAssertEqual(bibliographyCalls(embedded,ParsedSource.parse(embedded)).first?.inputs.first?.embedded,"@book{key, title={A Book}}")
        let variable = "#let works = \"refs/works.bib\"\n#bibliography(works, style: \"apa\")"
        XCTAssertEqual(bibliographyCalls(variable,ParsedSource.parse(variable)).first?.inputs.first?.path,"refs/works.bib")
        let escape = "#include \"chapters/\\u{65e5}.typ\""
        XCTAssertEqual(DocumentBuffer(escape).includes.first?.path,"chapters/日.typ")
        let yaml = "# Comment\nmanual:\n  type: Book\n  title: Unrelated\n\nlinked:\n  type: Book\n  title: Old\n  # Keep custom notes\n  note: Custom\n  x-blank-zotero-key: \"ABCD1234\"\n  x-blank-zotero-library: \"personal\"\n"
        let revised = try! Hayagriva.merge(yaml,key:"linked",exported:"linked:\n  type: Book\n  title: New\n",itemKey:"ABCD1234",library:"personal")
        XCTAssertTrue(revised.hasPrefix(yaml.components(separatedBy:"linked:")[0])); XCTAssertTrue(revised.contains("  # Keep custom notes\n  note: Custom\n"))
        XCTAssertEqual(try! Hayagriva.linked(revised).first?.0,"linked")
        let indented = "linked: # preserve header\n    type: Book\n    title: Old\n    x-blank-zotero-key: ABCD1234\n    x-blank-zotero-library: users/0"
        let noNewline = try! Hayagriva.merge(indented,key:"linked",exported:"linked:\n  type: Book\n  title: New\n  date: 2026\n",itemKey:"ABCD1234",library:"users/0")
        XCTAssertTrue(noNewline.contains("linked: # preserve header\n    type: Book\n    title: New\n")); XCTAssertTrue(noNewline.contains("\n    date: 2026\n"))
        XCTAssertEqual(try! Hayagriva.linked(noNewline).first?.0,"linked")
        let model = DocumentBuffer(embedded); model.selection = EditSelection(0,0)
        model.commit(embedded+"\n日本",selection:EditSelection(embedded.utf8.count+7,embedded.utf8.count+7))
        model.undo(); XCTAssertEqual(model.source,embedded); XCTAssertEqual(model.selection,EditSelection(0,0))
    }
    func testHistoryGroupingAndSelections() {
        let b = DocumentBuffer()
        b.commit("a",selection:EditSelection(1,1),group:"typing",now:1)
        b.commit("ab",selection:EditSelection(2,2),group:"typing",now:1.2)
        b.commit("abc",selection:EditSelection(3,3),group:"typing",now:1.4)
        b.undo(); XCTAssertEqual(b.source,""); XCTAssertEqual(b.selection,EditSelection(0,0))
        b.redo(); XCTAssertEqual(b.source,"abc"); XCTAssertEqual(b.selection,EditSelection(3,3))
        XCTAssertLessThan(b.historyBytes,10)
    }
    func testCrossMarkupDeletionRemainsValid() {
        let b = DocumentBuffer("plain *bold* middle _italic_ end")
        b.editWrite(NSRange(location:3,length:20),text:"X")
        XCTAssertFalse(b.source.contains("**"))
        b.undo(); XCTAssertEqual(b.source,"plain *bold* middle _italic_ end")
    }
    func testCodeBlockEditing() {
        let shell = "#{\n  let café = \"日本 👋\"\n}"
        let original = "Before 👩🏽‍💻\n\n"+shell+"\n\nAfter // keep"
        func block(_ model: DocumentBuffer) -> ProjectedBlock { model.projection.blocks.first { $0.kind == "source" }! }
        for offset in [0,1,shell.utf16.count-1] {
            let model = DocumentBuffer(original), at = block(model).display.location+offset
            model.editWrite(NSRange(location:at,length:1),text:"")
            XCTAssertEqual(model.source,original); XCTAssertFalse(model.canUndo)
            model.editWrite(NSRange(location:at,length:1),text:"replacement")
            XCTAssertEqual(model.source,original)
            model.paste(RichFragment(source:"Text",plain:"Text",block:true),range:NSRange(location:at,length:1))
            XCTAssertEqual(model.source,original)
            model.split(NSRange(location:at,length:1)); XCTAssertEqual(model.source,original)
        }
        let model = DocumentBuffer(original), raw = block(model)
        model.editWrite(NSRange(location:raw.display.location+1,length:0),text:"x")
        XCTAssertEqual(model.source,original)
        let text = (model.projection.text as NSString).range(of:"café")
        model.editWrite(text,text:"résumé")
        XCTAssertEqual(model.source,original.replacingOccurrences(of:"café",with:"résumé"))
        model.undo(); XCTAssertEqual(model.source,original)
        model.selection = EditSelection(raw.source.end-2,raw.source.end-2)
        let at = model.projection.displayOffset(at:model.selection.focus)
        model.split(NSRange(location:at,length:0))
        XCTAssertTrue(model.source.contains("\"日本 👋\"\n  \n}")); XCTAssertFalse(model.parsed.erroneous)
        model.undo(); XCTAssertEqual(model.source,original)
        model.editWrite(block(model).display,text:"")
        XCTAssertFalse(model.source.contains(shell)); XCTAssertTrue(model.source.contains("After // keep"))
        model.undo(); XCTAssertEqual(model.source,original)
        model.redo(); XCTAssertFalse(model.source.contains(shell))
        model.undo()
        model.editSource(NSRange(location:model.source.utf16Offset(byte:raw.source.end-1),length:1),text:"")
        XCTAssertFalse(model.source.contains("\n}")); model.undo(); XCTAssertEqual(model.source,original)
        // An unfinished string must not make the known closing brace editable.
        let body = (model.projection.text as NSString).range(of:"let café = \"日本 👋\"")
        model.editWrite(body,text:"let café = \"")
        XCTAssertTrue(model.parsed.erroneous)
        let incomplete = model.source
        let closingByte = incomplete.range(of:"\n}\n")!.lowerBound
        let close = incomplete[..<closingByte].utf8.count+1
        let closeDisplay = model.projection.displayOffset(at:close)
        model.editWrite(NSRange(location:closeDisplay,length:1),text:"")
        XCTAssertEqual(model.source,incomplete)
        let copy = model.editingCopy(); copy.editWrite(NSRange(location:closeDisplay,length:1),text:"")
        XCTAssertEqual(copy.source,incomplete)
        model.undo(); XCTAssertEqual(model.source,original)
        // Offsets remain correct after moving the shell past Unicode prose.
        model.editSource(NSRange(location:0,length:0),text:"日本 👋 ")
        let shifted = block(model)
        model.editWrite(NSRange(location:shifted.display.location,length:1),text:"")
        XCTAssertTrue(model.source.hasPrefix("日本 👋 Before")); XCTAssertTrue(model.source.contains(shell))
    }
    func testConsecutiveCodeBlocksStayTogether() {
        let b = DocumentBuffer("#set text(size: 11pt)\n#let custom = 3\n#show heading: it => it\n\nBody")
        XCTAssertEqual(b.projection.blocks.filter { $0.kind == "source" }.count,1)
        XCTAssertTrue(b.projection.blocks[0].text.contains("#show"))
    }
    func testMoveSectionPreservesNestedSource() {
        let original = "= First\n\nA\n\n== Child\n\n#custom\n\n= Second\n\nB\n"
        let b = DocumentBuffer(original)
        let target = b.projection.blocks.firstIndex { $0.text == "Second" }!
        b.moveSection(target,before:0)
        XCTAssertTrue(b.source.hasPrefix("= Second")); XCTAssertTrue(b.source.contains("== Child\n\n#custom"))
        b.undo(); XCTAssertEqual(b.source,original)
        let last = b.projection.blocks.firstIndex { $0.text == "Second" }!
        XCTAssertTrue(b.moveSection(0,after:last))
        XCTAssertTrue(b.source.hasPrefix("= Second\n\nB\n"))
        XCTAssertTrue(b.source.hasSuffix("= First\n\nA\n\n== Child\n\n#custom\n\n"))
        let moved = b.source, selection = b.selection
        b.undo(); XCTAssertEqual(b.source,original)
        b.redo(); XCTAssertEqual(b.source,moved); XCTAssertEqual(b.selection,selection)
        let end = DocumentBuffer("= First\n\n日本 👋\n\n= Last\n\nTail")
        XCTAssertTrue(end.moveSection(0,after:end.projection.blocks.firstIndex { $0.text == "Last" }!))
        XCTAssertTrue(end.source.contains("Tail\n\n= First\n\n日本 👋"))
        XCTAssertFalse(end.parsed.erroneous)
        XCTAssertFalse(end.moveSection(0,after:0))
    }
    func testMoveSectionAcrossParents() {
        let original = "= Alpha\n\n// intro\n\n== Shared\n\n日本 👋 *bold*\n\n=== Nested\n\n#let custom = 42\n\n== Remaining\n\nKeep\n\n= Beta\n\nIntro\n\n== Existing\n\nBody\n\n= Empty\n"
        let b = DocumentBuffer(original)
        func heading(_ title: String,_ level: Int) -> Int { b.projection.blocks.firstIndex { $0.kind == "heading" && $0.text == title && $0.level == level }! }
        let raw = "== Shared\n\n日本 👋 *bold*\n\n=== Nested\n\n#let custom = 42\n\n"
        XCTAssertTrue(b.moveSection(heading("Shared",2),into:heading("Beta",1)))
        XCTAssertTrue(b.source.contains("== Existing\n\nBody\n\n"+raw+"= Empty"))
        XCTAssertTrue(b.source.hasPrefix("= Alpha\n\n// intro\n\n== Remaining"))
        XCTAssertFalse(b.parsed.erroneous)
        let moved = b.source, selection = b.selection
        b.undo(); XCTAssertEqual(b.source,original)
        b.redo(); XCTAssertEqual(b.source,moved); XCTAssertEqual(b.selection,selection)
        b.undo()
        XCTAssertTrue(b.moveSection(heading("Shared",2),into:heading("Empty",1)))
        XCTAssertTrue(b.source.hasSuffix("= Empty\n\n"+raw))
        b.undo(); XCTAssertEqual(b.source,original)
        // Same-level insertion changes parents naturally without changing heading levels.
        XCTAssertTrue(b.moveSection(heading("Shared",2),before:heading("Existing",2)))
        XCTAssertTrue(b.source.contains("= Beta\n\nIntro\n\n"+raw+"== Existing"))
        b.undo()
        XCTAssertTrue(b.moveSection(heading("Nested",3),into:heading("Existing",2)))
        XCTAssertTrue(b.source.contains("== Existing\n\nBody\n\n=== Nested\n\n#let custom = 42"))
        b.undo()
        XCTAssertFalse(b.moveSection(heading("Alpha",1),into:heading("Nested",3)))
        XCTAssertFalse(b.moveSection(heading("Shared",2),into:heading("Nested",3)))
        XCTAssertFalse(b.moveSection(heading("Shared",2),into:heading("Shared",2)))
        XCTAssertFalse(b.moveSection(heading("Remaining",2),into:heading("Alpha",1)))
        XCTAssertFalse(b.moveSection(heading("Shared",2),after:heading("Nested",3)))
        XCTAssertEqual(b.source,original)
        let crlf = DocumentBuffer("= A\r\n\r\n== Child\r\n\r\n日本\r\n\r\n= B\r\n")
        let child = crlf.projection.blocks.firstIndex { $0.text == "Child" }!
        let parent = crlf.projection.blocks.firstIndex { $0.text == "B" }!
        XCTAssertTrue(crlf.moveSection(child,into:parent))
        XCTAssertEqual(crlf.source,"= A\r\n\r\n= B\r\n\r\n== Child\r\n\r\n日本\r\n\r\n")
    }
    func testFormatTogglePreservesOtherMarks() {
        let b = DocumentBuffer("plain *bold and _italic_* tail")
        let range = NSRange(location:6,length:15)
        b.format(range,italic:false)
        XCTAssertEqual(b.projection.text,"plain bold and italic tail")
        XCTAssertFalse(b.projection.blocks[0].inlines.flatMap(\.runs).contains { $0.style.bold })
        XCTAssertTrue(b.projection.blocks[0].inlines.flatMap(\.runs).contains { $0.style.italic })
        b.format(range,italic:false)
        XCTAssertTrue(b.projection.blocks[0].inlines.flatMap(\.runs).contains { $0.style.bold })
    }
    func testIncrementalSpacesAndUnicode() {
        let b = DocumentBuffer()
        let text = "A quiet café 👩🏽‍💻"
        for character in text.unicodeScalars {
            let at = b.projection.displayOffset(at:b.selection.focus)
            b.editWrite(NSRange(location:at,length:0),text:String(character))
        }
        XCTAssertEqual(b.projection.text,text)
        b.undo(); XCTAssertEqual(b.source,"")
    }
    func testLocalProjectionMatchesFullParse() {
        let original = "// keep\n#set text(size: 11pt)\n\n= Heading\n\nA *bold* paragraph.\n\n- An _item_\n\n#custom(1)\n\nLast 👋 paragraph."
        let b = DocumentBuffer(original)
        for index in [2,3,5] {
            guard b.projection.blocks.indices.contains(index), b.projection.blocks[index].editable else { continue }
            let block = b.projection.blocks[index]
            b.editWrite(NSRange(location:block.display.location+min(2,block.display.length),length:0),text:"café")
            let full = DocumentBuffer(b.source)
            XCTAssertEqual(b.projection.text,full.projection.text)
            XCTAssertEqual(b.projection.blocks.map(\.source),full.projection.blocks.map(\.source))
            for offset in 0...b.projection.text.utf16.count { XCTAssertEqual(b.projection.sourceOffset(at:offset),full.projection.sourceOffset(at:offset)) }
        }
        XCTAssertTrue(b.source.hasPrefix("// keep\n#set text(size: 11pt)"))
        XCTAssertEqual(b.parsed.tree.end,b.source.utf8.count)
    }
    func testTypingInsideFormattingKeepsWrappers() {
        let b = DocumentBuffer("A *bold* and #link(\"https://typst.app\")[café].")
        b.editWrite(NSRange(location:4,length:0),text:"X")
        XCTAssertEqual(b.source,"A *boXld* and #link(\"https://typst.app\")[café].")
        XCTAssertFalse(b.parsed.erroneous)
        let link = (b.projection.text as NSString).range(of:"café")
        b.editWrite(NSRange(location:link.location+3,length:1),text:"è")
        XCTAssertTrue(b.source.contains("[cafè]")); XCTAssertFalse(b.parsed.erroneous)
        b.undo(); b.undo(); XCTAssertEqual(b.source,"A *bold* and #link(\"https://typst.app\")[café].")
    }
    func testEmptyStructuredBlockInsertion() {
        for original in ["/", "Before\n\n/", "Before\n\n/\n\nAfter", "Before\n\n/\n\n"] {
            for (kind,marker) in [("heading","= "),("bullet","- "),("number","+ ")] {
                let b = DocumentBuffer(original), slash = (b.projection.text as NSString).range(of:"/")
                let index = b.projection.blockIndex(at:slash.location)
                b.editWrite(slash,text:"",group:"")
                b.setKind(at:NSRange(location:b.projection.displayOffset(at:b.selection.focus),length:0),kind:kind,level:1)
                XCTAssertEqual(b.source,original.replacingOccurrences(of:"/",with:marker))
                XCTAssertEqual(b.projection.displayOffset(at:b.selection.focus),b.projection.blocks[index].display.location)
                XCTAssertEqual(b.projection.blocks[index].body.start,b.selection.focus)
                b.editWrite(NSRange(location:b.projection.displayOffset(at:b.selection.focus),length:0),text:"Café 👩🏽‍💻",group:"")
                XCTAssertEqual(b.projection.blocks[index].text,"Café 👩🏽‍💻")
                b.undo(); b.undo(); b.undo(); XCTAssertEqual(b.source,original)
            }
        }
        for original in ["- First\n- ", "+ First\n+ ", "- First\n- \n- Third"] {
            let b = DocumentBuffer(original), index = 1
            b.selection = EditSelection(b.projection.blocks[index].body.start,b.projection.blocks[index].body.start)
            b.setKind(index,kind:"paragraph")
            XCTAssertEqual(b.projection.blocks[index].kind,"paragraph")
            XCTAssertEqual(b.projection.blocks[index].text,"")
            XCTAssertEqual(b.projection.displayOffset(at:b.selection.focus),b.projection.blocks[index].display.location)
            b.editWrite(NSRange(location:b.projection.displayOffset(at:b.selection.focus),length:0),text:"Body 👋",group:"")
            XCTAssertEqual(b.projection.blocks[index].text,"Body 👋")
            b.undo(); b.undo(); XCTAssertEqual(b.source,original)
        }
        for (kind,level,prefix) in [("heading",2,"== "),("bullet",0,"- "),("number",0,"+ ")] {
            let b = DocumentBuffer(); b.setKind(0,kind:kind,level:level)
            for c in "A café" { b.editWrite(NSRange(location:b.projection.text.utf16.count,length:0),text:String(c)) }
            XCTAssertEqual(b.source,prefix+"A café"); XCTAssertEqual(b.projection.blocks[0].kind,kind)
            XCTAssertEqual(b.projection.text,"A café")
        }
    }
    func testRenderedReferencesPreserveSource() {
        let original = "// Keep café\n\nBefore #cite(<smith>, supplement: [p. 7]) after.\n\n#bibliography(\"works.bib\", style: \"apa\")"
        let b = DocumentBuffer(original)
        let cite = (original as NSString).range(of:"#cite(<smith>, supplement: [p. 7])")
        let bib = (original as NSString).range(of:"#bibliography(\"works.bib\", style: \"apa\")")
        let citeSpan = ByteSpan(original.byteOffset(utf16:cite.location),original.byteOffset(utf16:NSMaxRange(cite)))
        let bibSpan = ByteSpan(original.byteOffset(utf16:bib.location),original.byteOffset(utf16:NSMaxRange(bib)))
        b.setReferencePresentations([ReferencePresentation(source:citeSpan,text:"(Smith, 2020, p. 7)"),ReferencePresentation(source:bibSpan,text:"References\n\nSmith, J. (2020). Book.",kind:"bibliography")])
        XCTAssertEqual(b.source,original); XCTAssertFalse(b.canUndo)
        XCTAssertTrue(b.projection.text.contains("(Smith, 2020, p. 7)")); XCTAssertFalse(b.projection.text.contains("#cite")); XCTAssertFalse(b.projection.text.contains("#bibliography"))
        let rendered = (b.projection.text as NSString).range(of:"(Smith, 2020, p. 7)")
        XCTAssertEqual(b.projection.sourceOffset(at:rendered.location),citeSpan.start)
        XCTAssertEqual(b.projection.sourceOffset(at:NSMaxRange(rendered)),citeSpan.end)
        let copied = b.copy(NSRange(location:rendered.location+2,length:3))
        XCTAssertEqual(copied.source,original.bytes(citeSpan)); XCTAssertEqual(copied.plain,"(Smith, 2020, p. 7)")
        b.editWrite(NSRange(location:rendered.location,length:0),text:"日本 ",group:"")
        XCTAssertTrue(b.projection.text.contains("日本 (Smith, 2020, p. 7)"))
        let shifted = (b.projection.text as NSString).range(of:"(Smith, 2020, p. 7)")
        b.editWrite(NSRange(location:NSMaxRange(shifted)-1,length:1),text:"",group:"")
        XCTAssertFalse(b.source.contains("#cite")); XCTAssertTrue(b.source.hasPrefix("// Keep café")); XCTAssertTrue(b.source.contains("#bibliography"))
        b.undo(); b.undo(); XCTAssertEqual(b.source,original)
        let table = DocumentBuffer("#table(columns: 1, [Before #cite(<smith>) after])")
        let span = (table.source as NSString).range(of:"#cite(<smith>)")
        table.setReferencePresentations([ReferencePresentation(source:ByteSpan(span.location,NSMaxRange(span)),text:"(Smith, 2020)")])
        let displayed = (table.projection.text as NSString).range(of:"(Smith, 2020)")
        XCTAssertEqual(table.copy(displayed).source,"#cite(<smith>)")
        XCTAssertEqual(table.copy(displayed).plain,"(Smith, 2020)")
        table.editWrite(NSRange(location:displayed.location,length:0),text:"日本 ",group:"")
        XCTAssertTrue(table.source.contains("[Before 日本 #cite(<smith>) after]"))
        table.undo(); XCTAssertEqual(table.source,"#table(columns: 1, [Before #cite(<smith>) after])")
        for original in ["#emph[#cite(<smith>)] #cite(<doe>).", "*#cite(<smith>)* #cite(<doe>).", "#cite(<smith>) *#cite(<doe>)*.", "#emph[日本 before #cite(<smith>)] #cite(<doe>).", "#cite(<smith>) *#cite(<doe>) after*.", "#cite(<smith>) /* keep */ #cite(<doe>).", "#cite(<smith>) // café keep\n#cite(<doe>)."] {
            let grouped = DocumentBuffer(original)
            let first = original.range(of:"#cite")!.lowerBound, last = original.range(of:")",options:.backwards)!.upperBound
            grouped.setReferencePresentations([ReferencePresentation(source:ByteSpan(original[..<first].utf8.count,original[..<last].utf8.count),text:"(Doe, 2021; Smith, 2020)")])
            XCTAssertTrue(grouped.projection.text.contains("(Doe, 2021; Smith, 2020)")); XCTAssertFalse(grouped.projection.text.contains("Citation"))
            if original.contains("before") { XCTAssertTrue(grouped.projection.text.hasPrefix("日本 before ")) }
            if original.contains("after") { XCTAssertTrue(grouped.projection.text.hasSuffix(" after.")) }
            let range = grouped.projection.atomicRanges.first!
            let fragment = grouped.copy(range)
            XCTAssertEqual(fragment.source,String(original.dropLast()))
            let pasted = DocumentBuffer(); pasted.paste(fragment,range:NSRange(location:0,length:0)); XCTAssertFalse(pasted.parsed.erroneous)
            grouped.editWrite(range,text:""); XCTAssertFalse(grouped.parsed.erroneous); XCTAssertEqual(grouped.source,".")
            grouped.undo(); XCTAssertEqual(grouped.source,original)
        }
        let overlapSource = "#cite(<a>) *#cite(<b>) middle #cite(<c>)* #cite(<d>)."
        let overlap = DocumentBuffer(overlapSource)
        let bEnd = overlapSource.range(of:"#cite(<b>)")!.upperBound, cStart = overlapSource.range(of:"#cite(<c>)")!.lowerBound
        overlap.setReferencePresentations([ReferencePresentation(source:ByteSpan(0,overlapSource[..<bEnd].utf8.count),text:"(A; B)"),ReferencePresentation(source:ByteSpan(overlapSource[..<cStart].utf8.count,overlapSource.utf8.count-1),text:"(C; D)")])
        XCTAssertEqual(overlap.projection.text,"(A; B) middle (C; D).")
        XCTAssertEqual(overlap.copy(overlap.projection.atomicRanges.first!).source,String(overlapSource.dropLast()))
        XCTAssertEqual(overlap.renderedReferences.count,1)
        for original in ["*Before #cite(<smith>) after*.", "#emph[日本 Before #cite(<smith>) after].", "#table(columns: 1, [*Before #cite(<smith>) after*])"] {
            let single = DocumentBuffer(original), raw = original.range(of:"#cite(<smith>)")!
            single.setReferencePresentations([ReferencePresentation(source:ByteSpan(original[..<raw.lowerBound].utf8.count,original[..<raw.upperBound].utf8.count),text:"(Smith, 2020)")])
            let before = (single.projection.text as NSString).range(of:"Before")
            XCTAssertFalse(single.copy(before).source.contains("#cite"))
            single.editWrite(before,text:"Updated")
            XCTAssertTrue(single.source.contains("#cite(<smith>)")); XCTAssertTrue(single.source.contains("after")); XCTAssertFalse(single.parsed.erroneous)
            single.undo(); XCTAssertEqual(single.source,original)
        }
    }
    func testExplicitFormattingInsideWords() {
        let b = DocumentBuffer("word")
        b.format(NSRange(location:1,length:2),italic:false)
        XCTAssertEqual(b.projection.text,"word"); XCTAssertFalse(b.parsed.erroneous)
        var style = TextStyle(); style.bold = true
        let empty = DocumentBuffer(); empty.editWrite(NSRange(location:0,length:0),text:"A",styleOverride:style)
        XCTAssertEqual(empty.projection.text,"A"); XCTAssertTrue(empty.projection.blocks[0].editable)
        empty.editWrite(NSRange(location:1,length:0),text:"B",styleOverride:style)
        style.bold = false; empty.editWrite(NSRange(location:2,length:0),text:"C",styleOverride:style)
        XCTAssertEqual(empty.projection.text,"ABC"); XCTAssertFalse(empty.parsed.erroneous)
        XCTAssertFalse(empty.projection.blocks[0].inlines.flatMap(\.runs).last!.style.bold)
    }
    func testIncludesAndStatistics() {
        let b = DocumentBuffer("// #include \"ignored.typ\"\n#include \"chapters/one.typ\"\n\n= Title\n\nHello *café* 👋\n\n#let hidden = \"not prose\"\n\n#table(columns: 2, [One], [Two])")
        XCTAssertEqual(b.includes.map(\.path),["chapters/one.typ"])
        XCTAssertEqual(b.counts.words,5); XCTAssertEqual(b.counts.headings,1)
        XCTAssertEqual(b.counts.characters,"TitleHello café 👋OneTwo".unicodeScalars.count)
        b.editSource(NSRange(location:b.source.utf16.count,length:0),text:"\n\nMore words")
        XCTAssertEqual(b.counts.words,7); b.undo(); XCTAssertEqual(b.counts.words,5)
        let cell = DocumentBuffer("#table(columns: 1, [#link(\"https://typst.app\")[A]])")
        XCTAssertEqual(cell.projection.blocks[0].tableCells.count,1)
    }
    func testIncludeMovementPreservesSource() {
        let source = "#include \"a.typ\" // a\r\n// untouched\r\n#include \"β.typ\" // b\r\n\n#if true [#include \"dynamic.typ\"]"
        let b = DocumentBuffer(source)
        XCTAssertEqual(b.includes.map(\.path),["a.typ","β.typ"])
        XCTAssertTrue(b.moveInclude(1,before:0))
        XCTAssertEqual(b.source,"#include \"β.typ\" // b\r\n// untouched\r\n#include \"a.typ\" // a\r\n\n#if true [#include \"dynamic.typ\"]")
        b.undo(); XCTAssertEqual(b.source,source); b.redo(); XCTAssertEqual(b.includes.map(\.path),["β.typ","a.typ"])
        b.undo(); XCTAssertTrue(b.moveInclude(0,after:1))
        XCTAssertEqual(b.source,"#include \"β.typ\" // b\r\n// untouched\r\n#include \"a.typ\" // a\r\n\n#if true [#include \"dynamic.typ\"]")
        b.undo(); XCTAssertEqual(b.source,source)
        let inline = DocumentBuffer("Before #include \"a.typ\"\n#include \"b.typ\"")
        XCTAssertFalse(inline.moveInclude(1,before:0))
    }
    func testLiteralDependenciesIgnoreComments() {
        let source = "// #image(\"not-real.png\")\n`#read(\"example.csv\")`\n#import \"tools.typ\": *\n#image(\"a\\\"b.png\")\n#read(\"table.csv\")\n#bibliography(\"refs.bib\", style: \"custom.csl\")"
        let b = DocumentBuffer(source)
        XCTAssertEqual(b.imports.map(\.path),["tools.typ"])
        XCTAssertEqual(literalAssetPaths(source,b.parsed),["a\"b.png","table.csv","refs.bib","custom.csl"])
    }
    func testRandomUnicodePatchRoundtrip() {
        let pool = ["a","é","😀","中","e\u{301}","\n","*","\\"]
        for i in 0..<200 {
            let old = (0..<20).map { pool[($0+i)%pool.count] }.joined(), new = (0..<15).map { pool[($0*3+i)%pool.count] }.joined()
            let p = SourcePatch.difference(old,new)!
            XCTAssertEqual(old.replacingBytes(p.oldSpan,with:p.inserted),new)
            XCTAssertEqual(new.replacingBytes(p.newSpan,with:p.removed),old)
        }
    }
    func testLosslessTableEditing() {
        let original = "// before\n#let custom = 42\n\n#table(\n  columns: 2,\n  stroke: 0.5pt, // keep this option\n  [*Café* 👩🏽‍💻], [_Next_],\n  [], [#custom],\n)\n\nAfter _table_."
        let model = DocumentBuffer(original)
        func range(_ cell: Int) -> NSRange {
            let block = model.projection.blocks.first { !$0.cellRanges.isEmpty }!, local = block.cellRanges[cell]
            return NSRange(location:block.display.location+local.location,length:local.length)
        }
        let table = model.projection.blocks.first { !$0.cellRanges.isEmpty }!
        XCTAssertEqual(table.cellProjections.count,4)
        for (index,span) in table.tableCells.enumerated() {
            let local = table.cellProjections[index]
            for offset in 0...local.text.utf16.count {
                XCTAssertEqual(model.projection.sourceOffset(at:table.display.location+table.cellRanges[index].location+offset),span.start+local.sourceOffset(at:offset))
            }
            for run in local.blocks.flatMap(\.inlines).flatMap(\.runs) where run.literal {
                for character in 1..<max(1,run.text.utf16.count) {
                    let byte = span.start+run.source.start+run.text.byteOffset(utf16:character)
                    let at = model.projection.displayOffset(at:byte)
                    XCTAssertEqual(model.projection.sourceOffset(at:at),span.start+local.sourceOffset(at:at-table.display.location-table.cellRanges[index].location))
                }
            }
        }
        model.selection = EditSelection(table.tableCells[0].start+1,table.tableCells[0].start+1)
        model.editWrite(NSRange(location:range(0).location+2,length:0),text:"日本")
        XCTAssertTrue(model.source.contains("[*Ca日本fé* 👩🏽‍💻]"))
        XCTAssertTrue(model.source.contains("stroke: 0.5pt, // keep this option"))
        XCTAssertTrue(model.source.contains("[_Next_],\n  [], [#custom]"))
        model.undo(); XCTAssertEqual(model.source,original)
        model.redo(); XCTAssertFalse(model.parsed.erroneous)
        model.format(range(1),italic:false)
        XCTAssertTrue(model.source.contains("[*_Next_*]"))
        let fragment = model.copy(range(1))
        model.paste(fragment,range:range(2))
        XCTAssertTrue(model.source.contains("[*_Next_*], [#custom]"))
        let end = NSMaxRange(range(2)), sourceEnd = model.projection.sourceOffset(at:end)
        model.selection = EditSelection(sourceEnd,sourceEnd)
        model.split(NSRange(location:end,length:0))
        XCTAssertTrue(model.source.contains("[*_Next_*\n\n], [#custom]"))
        XCTAssertFalse(model.parsed.erroneous)
        model.undo(); XCTAssertTrue(model.source.contains("[*_Next_*], [#custom]"))
        let beforeSelection = model.source
        model.editWrite(NSRange(location:range(0).location+2,length:NSMaxRange(range(1))-range(0).location-2),text:"X")
        XCTAssertFalse(model.parsed.erroneous)
        XCTAssertTrue(model.projection.blocks.first { !$0.cellRanges.isEmpty }!.cellProjections[0].text.hasPrefix("CaX"))
        XCTAssertTrue(model.source.contains("stroke: 0.5pt, // keep this option"))
        XCTAssertEqual(model.projection.blocks.first { !$0.cellRanges.isEmpty }!.tableCells.count,4)
        model.undo(); XCTAssertEqual(model.source,beforeSelection)
        let boundary = DocumentBuffer("Before\n\n#table(columns: 2, [A], [B])\n\nAfter")
        let grid = boundary.projection.blocks[1]
        boundary.editWrite(NSRange(location:grid.display.location-1,length:1),text:"")
        XCTAssertEqual(boundary.source,"Before\n\n#table(columns: 2, [A], [B])\n\nAfter")
        boundary.editWrite(NSRange(location:NSMaxRange(grid.display),length:1),text:"")
        XCTAssertEqual(boundary.source,"Before\n\n#table(columns: 2, [A], [B])\n\nAfter")
        let wholeTable = model.projection.blocks.first { !$0.cellRanges.isEmpty }!
        let copy = model.copy(wholeTable.display)
        XCTAssertEqual(copy.source,model.source.bytes(wholeTable.source))
        let target = DocumentBuffer(); target.paste(copy,range:NSRange(location:0,length:0))
        XCTAssertEqual(target.source,copy.source)
        model.editWrite(wholeTable.display,text:"")
        XCTAssertFalse(model.source.contains("#table(")); XCTAssertTrue(model.source.hasSuffix("After _table_."))
        model.undo(); XCTAssertEqual(model.source,beforeSelection)
    }
}

extension DocumentTests {
    func testIncompleteBlockMarkersStayVisible() {
        for prefix in ["=","==","===","-","+"] {
            let model = DocumentBuffer()
            for character in prefix { model.editWrite(NSRange(location:model.projection.displayOffset(at:model.selection.focus),length:0),text:String(character)) }
            XCTAssertEqual(model.projection.text,prefix)
            XCTAssertEqual(model.projection.blocks[0].kind,"paragraph")
            model.editWrite(NSRange(location:prefix.utf16.count,length:0),text:" text")
            XCTAssertEqual(model.projection.text,prefix+" text")
            XCTAssertFalse(model.parsed.erroneous)
            model.undo(); XCTAssertEqual(model.source,"")
        }
    }
}
extension DocumentTests {
    func testSourceFoldingPreservesBytesAndOffsets() {
        let raw = "#set text(size: 11pt)\n#let café = \"日本😀\"\n\nAfter *bold*"
        let model = DocumentBuffer(raw)
        let code = model.projection.blocks.firstIndex { $0.kind == "source" && $0.text.contains("\n") }!
        model.setSourceCollapsed(code,true)
        let block = model.projection.blocks[code]
        XCTAssertTrue(block.collapsed); XCTAssertFalse(block.text.contains("\n"))
        XCTAssertEqual(model.source,raw); XCTAssertFalse(model.canUndo)
        XCTAssertEqual(model.copy(block.display).source,raw.bytes(block.source))
        XCTAssertEqual(model.projection.sourceOffset(at:block.display.location),block.source.start)
        XCTAssertEqual(model.projection.sourceOffset(at:NSMaxRange(block.display)),block.source.end)
        let after = model.projection.blocks.last!
        model.editWrite(NSRange(location:NSMaxRange(after.display),length:0),text:"!")
        XCTAssertTrue(model.projection.blocks[code].collapsed)
        model.undo(); XCTAssertEqual(model.source,raw)
        model.setSourceCollapsed(code,false)
        XCTAssertEqual(model.projection.text,DocumentBuffer(raw).projection.text)
        XCTAssertEqual(model.projection.blocks[code].text,raw.bytes(block.source))
    }
    func testTableDimensionsPreserveSource() {
        let raw = "// outside\n#table(columns: 2, inset: 9pt, // options\n [日本 *bold*], /* keep */ [B],\n [C], [D]\n)\n\nAfter"
        for column in [false,true] {
            for action in ["before","after","delete"] {
                let model = DocumentBuffer(raw), index = model.projection.blocks.firstIndex { !$0.cellRanges.isEmpty }!
                XCTAssertTrue(model.changeTable(index,cell:1,column:column,action:action))
                XCTAssertFalse(model.parsed.erroneous)
                XCTAssertTrue(model.source.contains("inset: 9pt, // options"))
                XCTAssertTrue(model.source.contains("/* keep */"))
                XCTAssertTrue(model.source.hasPrefix("// outside\n")); XCTAssertTrue(model.source.hasSuffix("\n\nAfter"))
                let block = model.projection.blocks[index]
                XCTAssertEqual(block.columns,column ? action == "delete" ? 1 : 3 : 2)
                XCTAssertEqual(block.tableCells.count,column ? action == "delete" ? 2 : 6 : action == "delete" ? 2 : 6)
                XCTAssertTrue(model.source.contains("[C]"))
                let afterSelection = model.selection
                model.undo(); XCTAssertEqual(model.source,raw)
                model.redo(); XCTAssertFalse(model.parsed.erroneous); XCTAssertEqual(model.selection,afterSelection)
            }
        }
        for complex in ["#table(columns: 2 + 2, [A], [B], [C], [D])", "#table(columns: 2, [A], [B], ..([C], [D]))", "#table(columns: 2, table.header[A][B], [C], [D])"] {
            let model = DocumentBuffer(complex)
            XCTAssertTrue(model.projection.blocks[0].cellRanges.isEmpty)
            XCTAssertEqual(model.projection.text,complex)
            XCTAssertFalse(model.changeTable(0,cell:0,column:true,action:"after"))
            XCTAssertEqual(model.source,complex)
        }
        let one = DocumentBuffer("#table(columns: 1, [Only])")
        XCTAssertFalse(one.changeTable(0,cell:0,column:true,action:"delete"))
        XCTAssertFalse(one.changeTable(0,cell:0,column:false,action:"delete"))
    }
}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { if a != b { fatalError("Expected \(b), got \(a)",file:file,line:line) } }
func XCTAssertTrue(_ value: Bool,file: StaticString = #file,line: UInt = #line) { if !value { fatalError("Expected true",file:file,line:line) } }
func XCTAssertFalse(_ value: Bool,file: StaticString = #file,line: UInt = #line) { XCTAssertTrue(!value,file:file,line:line) }
func XCTAssertLessThan<T: Comparable>(_ a: T,_ b: T,file: StaticString = #file,line: UInt = #line) { XCTAssertTrue(a < b,file:file,line:line) }
@main enum CoreChecks {
    static func main() {
        setbuf(stdout,nil)
        let t = DocumentTests()
        let tests: [(String,()->Void)] = [
            ("Unicode source mapping",t.testUnicodeSourceOffsets),
            ("Literal markup labels",t.testLiteralMarkupLabels),
            ("Source folding preserves bytes and offsets",t.testSourceFoldingPreservesBytesAndOffsets),
            ("Table dimension transactions preserve source",t.testTableDimensionsPreserveSource),
            ("Lossless styled edit",t.testProjectionAndLosslessEdit),
            ("Clearing inline marks without stale formatting",t.testDeletingCompleteMarks),
            ("List continuation and exit",t.testListContinueAndExit),
            ("Paragraph joining",t.testParagraphJoinKeepsFormatting),
            ("Paragraph and soft line breaks",t.testParagraphAndLineBreaks),
            ("Structured clipboard",t.testClipboardHeadingAndList),
            ("Structured paste at caret",t.testStructuredPasteAtCaret),
            ("Typst string literals",t.testTypstStringLiterals),
            ("Bibliography preservation",t.testBibliographyPreservation),
            ("Grouped history and selections",t.testHistoryGroupingAndSelections),
            ("Cross-mark deletion",t.testCrossMarkupDeletionRemainsValid),
            ("Consecutive code",t.testConsecutiveCodeBlocksStayTogether),
            ("Code block shells, editing and history",t.testCodeBlockEditing),
            ("Section movement",t.testMoveSectionPreservesNestedSource),
            ("Section parent movement",t.testMoveSectionAcrossParents),
            ("Formatting toggles",t.testFormatTogglePreservesOtherMarks),
            ("Incremental spaces and Unicode",t.testIncrementalSpacesAndUnicode),
            ("Local projection equals full parsing",t.testLocalProjectionMatchesFullParse),
            ("Typing inside formatting",t.testTypingInsideFormattingKeepsWrappers),
            ("Empty headings and lists",t.testEmptyStructuredBlockInsertion),
            ("Rendered references preserve canonical source",t.testRenderedReferencesPreserveSource),
            ("Formatting inside words",t.testExplicitFormattingInsideWords),
            ("Literal includes and prose statistics",t.testIncludesAndStatistics),
            ("Include movement and conditional boundaries",t.testIncludeMovementPreservesSource),
            ("Literal dependencies ignore commented examples",t.testLiteralDependenciesIgnoreComments),
            ("Unicode patch round trips",t.testRandomUnicodePatchRoundtrip),
            ("Lossless table cells, mapping and history",t.testLosslessTableEditing),
            ("Incomplete block markers remain visible",t.testIncompleteBlockMarkersStayVisible)
        ]
        for (name,test) in tests { test(); print("PASS: \(name)") }
        print("\(tests.count) core checks passed")
    }
}
