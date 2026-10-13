import Foundation
import Darwin
import BlankCore

struct CompileResult {
    var data: Data?
    var diagnostics: [String]
    var map: [[String: Any]]
    var revision: Int
    var references: [[String:Any]] = []
    var dependencies: [String] = []
    var bibliographies: [[String:Any]] = []
}
// Requests and I/O are serialized on queue; cancellation protects process state.
final class TypstCompiler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "blank.typst.compiler", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private let cancellationLock = NSLock()
    private var cancelled = false
    // Universe operations use a dedicated helper, so cancellation never stops
    // an editor's compilation or another catalogue window's work.
    func cancel() {
        cancellationLock.lock(); cancelled = true
        let running = process; cancellationLock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }
    func universe(_ method: String, params: [String:Any], completion: @escaping (Result<[String:Any],Error>) -> Void) {
        queue.async {
            let result = Result { try self.call(method,params:params) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    deinit { process?.terminate() }
    func clearPackageCache(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result { _ = try self.call("clearPackageCache",params:[:]) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func compile(root: URL, entry: String, files: [String: String], revision: Int, completion: @escaping (Result<CompileResult, Error>) -> Void) {
        queue.async {
            do {
                let reply = try self.call("compile", params: ["root": root.path, "entry": entry, "files": files, "revision": revision])
                let diagnostics = (reply["diagnostics"] as? [[String:Any]] ?? []).map { ($0["message"] as? String ?? "Compilation failed") }
                let result = CompileResult(data: (reply["pdf"] as? String).flatMap { Data(base64Encoded: $0) }, diagnostics: diagnostics, map: reply["sourceMap"] as? [[String:Any]] ?? [], revision: revision, references: reply["citations"] as? [[String:Any]] ?? [], dependencies: reply["dependencies"] as? [String] ?? [], bibliographies: reply["bibliographies"] as? [[String:Any]] ?? [])
                DispatchQueue.main.async { completion(.success(result)) }
            } catch { self.cancellationLock.lock(); self.process?.terminate(); self.process = nil; self.cancellationLock.unlock(); DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func hayagriva(_ bib: String,completion: @escaping (Result<String,Error>) -> Void) {
        queue.async {
            let result = Result { try self.call("bibToHayagriva",params:["bib":bib])["yaml"] as? String ?? "" }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func convertBibliography(_ text: String,from: String,to: String,completion: @escaping (Result<String,Error>) -> Void) {
        queue.async {
            let result = Result { () throws -> String in
                guard let text = try self.call("convertBibliography",params:["text":text,"from":from,"to":to])["text"] as? String else { throw NSError(domain:"Typst",code:1,userInfo:[NSLocalizedDescriptionKey:"The compiler returned no converted bibliography."]) }
                return text
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    private func call(_ method: String, params: [String:Any]) throws -> [String:Any] {
        cancellationLock.lock()
        if cancelled { cancellationLock.unlock(); throw CancellationError() }
        if process == nil {
            let compiler = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("typst-compiler")
            let candidate = FileManager.default.isExecutableFile(atPath: compiler.path) ? compiler : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/release/typst-compiler")
            let p = Process(); p.executableURL = candidate
            let i = Pipe(), o = Pipe()
            // A cancellation can close the helper's input while a queued write
            // is starting. Return EPIPE for this pipe instead of killing the app.
            guard fcntl(i.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1) == 0 else {
                let error = NSError(domain:NSPOSIXErrorDomain,code:Int(errno)); cancellationLock.unlock(); throw error
            }
            p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.standardError
            do { try p.run() } catch { cancellationLock.unlock(); throw error }; process = p; input = i.fileHandleForWriting; output = o.fileHandleForReading; buffer.removeAll()
        }
        cancellationLock.unlock()
        sequence += 1
        let request: [String:Any] = ["jsonrpc":"2.0", "protocolVersion":1, "id":sequence, "method":method, "params":params]
        var data = try JSONSerialization.data(withJSONObject:request); data.append(10)
        let running = process!
        let deadline = DispatchWorkItem { if running.isRunning { running.terminate() } }
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+90,execute:deadline)
        defer { deadline.cancel() }
        try input!.write(contentsOf:data)
        // Blocking I/O is restricted to this compiler queue, never the UI thread.
        while true {
            if let newline = buffer.firstIndex(of:10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let json = try JSONSerialization.jsonObject(with:line) as? [String:Any] else { continue }
                if let error = json["error"] as? [String:Any] { throw NSError(domain:"Typst",code:1,userInfo:[NSLocalizedDescriptionKey:error["message"] as? String ?? "Compiler error"]) }
                return json["result"] as? [String:Any] ?? [:]
            }
            let data = output!.availableData
            if data.isEmpty { throw NSError(domain:"Typst",code:2,userInfo:[NSLocalizedDescriptionKey:"Typst compiler stopped."]) }
            buffer.append(data)
            if buffer.count > 128*1024*1024 { throw NSError(domain:"Typst",code:3,userInfo:[NSLocalizedDescriptionKey:"Typst output exceeded 128 MiB. The previous preview is retained."]) }
        }
    }
}
