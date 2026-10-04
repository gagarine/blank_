import Foundation
import BlankCore

final class DocumentTests {
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
        for (kind,level,prefix) in [("heading",2,"== "),("bullet",0,"- "),("number",0,"+ ")] {
            let b = DocumentBuffer(); b.setKind(0,kind:kind,level:level)
            for c in "A café" { b.editWrite(NSRange(location:b.projection.text.utf16.count,length:0),text:String(c)) }
            XCTAssertEqual(b.source,prefix+"A café"); XCTAssertEqual(b.projection.blocks[0].kind,kind)
            XCTAssertEqual(b.projection.text,"A café")
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
            ("Lossless styled edit",t.testProjectionAndLosslessEdit),
            ("List continuation and exit",t.testListContinueAndExit),
            ("Paragraph joining",t.testParagraphJoinKeepsFormatting),
            ("Paragraph and soft line breaks",t.testParagraphAndLineBreaks),
            ("Structured clipboard",t.testClipboardHeadingAndList),
            ("Grouped history and selections",t.testHistoryGroupingAndSelections),
            ("Cross-mark deletion",t.testCrossMarkupDeletionRemainsValid),
            ("Consecutive code",t.testConsecutiveCodeBlocksStayTogether),
            ("Section movement",t.testMoveSectionPreservesNestedSource),
            ("Formatting toggles",t.testFormatTogglePreservesOtherMarks),
            ("Incremental spaces and Unicode",t.testIncrementalSpacesAndUnicode),
            ("Local projection equals full parsing",t.testLocalProjectionMatchesFullParse),
            ("Typing inside formatting",t.testTypingInsideFormattingKeepsWrappers),
            ("Empty headings and lists",t.testEmptyStructuredBlockInsertion),
            ("Formatting inside words",t.testExplicitFormattingInsideWords),
            ("Literal includes and prose statistics",t.testIncludesAndStatistics),
            ("Include movement and conditional boundaries",t.testIncludeMovementPreservesSource),
            ("Literal dependencies ignore commented examples",t.testLiteralDependenciesIgnoreComments),
            ("Unicode patch round trips",t.testRandomUnicodePatchRoundtrip)
        ]
        for (name,test) in tests { test(); print("PASS: \(name)") }
        print("\(tests.count) core checks passed")
    }
}
