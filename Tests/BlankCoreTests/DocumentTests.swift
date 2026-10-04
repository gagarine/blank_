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
        let t = DocumentTests()
        let tests: [(String,()->Void)] = [
            ("Unicode source mapping",t.testUnicodeSourceOffsets),
            ("Lossless styled edit",t.testProjectionAndLosslessEdit),
            ("List continuation and exit",t.testListContinueAndExit),
            ("Paragraph joining",t.testParagraphJoinKeepsFormatting),
            ("Structured clipboard",t.testClipboardHeadingAndList),
            ("Grouped history and selections",t.testHistoryGroupingAndSelections),
            ("Cross-mark deletion",t.testCrossMarkupDeletionRemainsValid),
            ("Consecutive code",t.testConsecutiveCodeBlocksStayTogether),
            ("Section movement",t.testMoveSectionPreservesNestedSource),
            ("Unicode patch round trips",t.testRandomUnicodePatchRoundtrip)
        ]
        for (name,test) in tests { test(); print("PASS: \(name)") }
        print("\(tests.count) core checks passed")
    }
}
