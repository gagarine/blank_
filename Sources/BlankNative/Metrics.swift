import Foundation
import AppKit
import BlankCore
import Darwin

@MainActor enum ResourceMetrics {
    static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000
    }
    static func residentMiB() -> Double {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
        return result == KERN_SUCCESS ? Double(info.resident_size)/1_048_576 : -1
    }
    static func run() {
        setbuf(stdout,nil)
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let controller = DocumentWindow(session:DocumentSession())
        controller.showWindow(nil); app.activate(ignoringOtherApps:true)
        RunLoop.main.run(until:Date().addingTimeInterval(0.5))
        let begin = cpuSeconds(), time = Date()
        RunLoop.main.run(until:Date().addingTimeInterval(5))
        print(String(format:"Empty editor idle: %.3f CPU seconds / %.3f wall seconds = %.2f%% one core; RSS %.1f MiB",cpuSeconds()-begin,Date().timeIntervalSince(time),(cpuSeconds()-begin)/Date().timeIntervalSince(time)*100,residentMiB()))
        for paragraphs in [100,1000] {
            let text = (0..<paragraphs).map { "Paragraph \($0). This café has a *bold* idea and an _italic_ observation. Unicode 👋 belongs here." }.joined(separator:"\n\n")
            let start = Date(), model = DocumentBuffer(text)
            let parse = Date().timeIntervalSince(start)
            var durations: [Double] = []
            for _ in 0..<10 {
                let block = model.projection.blocks[paragraphs/2]
                let at = Date(); model.editWrite(NSRange(location:block.display.location+4,length:0),text:"x")
                durations.append(Date().timeIntervalSince(at)*1000)
            }
            durations.sort()
            print(String(format:"%d paragraphs (%d source bytes): load %.1f ms; local edit median %.1f ms, max %.1f ms; history %d bytes; RSS %.1f MiB",paragraphs,text.utf8.count,parse*1000,durations[durations.count/2],durations.last!,model.historyBytes,residentMiB()))
        }
        let session = controller.session
        let text = (0..<1000).map { "Paragraph \($0). A *bold* café and an _italic_ thought." }.joined(separator:"\n\n")
        session.buffers[session.active] = DocumentBuffer(text); session.revision += 1; session.editor?.lastRevision = -1; session.editor?.refresh()
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        if let editor = session.editor {
            let target = session.buffer.projection.blocks[500]
            editor.setSelectedRange(NSRange(location:target.display.location+5,length:0)); editor.captureSelection()
            var durations: [Double] = []
            for _ in 0..<10 { let start = Date(); editor.insertText("x",replacementRange:editor.selectedRange()); durations.append(Date().timeIntervalSince(start)*1000) }
            durations.sort()
            print(String(format:"1000-paragraph native editor key transaction: median %.1f ms, max %.1f ms; RSS %.1f MiB",durations[5],durations.last!,residentMiB()))
        }
        let tableSource = "#table(columns: 2,\n"+(0..<200).map { "[Cell \($0) with a *bold* café 👋]," }.joined(separator:"\n")+"\n)\n\nAfter the table."
        session.buffers[session.active] = DocumentBuffer(tableSource); session.revision += 1; session.editor?.lastRevision = -1; session.editor?.refresh()
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        if let editor = session.editor {
            editor.focusTableCell(0,100)
            editor.setSelectedRange(NSRange(location:editor.selectedRange().location+5,length:0)); editor.captureSelection()
            var durations: [Double] = []
            for _ in 0..<10 { let start = Date(); editor.insertText("x",replacementRange:editor.selectedRange()); durations.append(Date().timeIntervalSince(start)*1000) }
            durations.sort()
            print(String(format:"100-row native table key transaction: median %.1f ms, max %.1f ms; RSS %.1f MiB",durations[5],durations.last!,residentMiB()))
        }
        session.saveWork?.cancel(); session.dirty = false
        controller.window?.close()
    }
}
