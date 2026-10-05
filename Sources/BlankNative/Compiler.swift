import Foundation
import BlankCore

struct CompileResult {
    var data: Data?
    var diagnostics: [String]
    var map: [[String: Any]]
    var revision: Int
}
final class TypstCompiler {
    private let queue = DispatchQueue(label: "blank.typst.compiler", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    deinit { process?.terminate() }
    func compile(root: URL, entry: String, files: [String: String], revision: Int, completion: @escaping (Result<CompileResult, Error>) -> Void) {
        queue.async {
            do {
                let reply = try self.call("compile", params: ["root": root.path, "entry": entry, "files": files, "revision": revision])
                let diagnostics = (reply["diagnostics"] as? [[String:Any]] ?? []).map { ($0["message"] as? String ?? "Compilation failed") }
                let result = CompileResult(data: (reply["pdf"] as? String).flatMap { Data(base64Encoded: $0) }, diagnostics: diagnostics, map: reply["sourceMap"] as? [[String:Any]] ?? [], revision: revision)
                DispatchQueue.main.async { completion(.success(result)) }
            } catch { self.process?.terminate(); self.process = nil; DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    private func call(_ method: String, params: [String:Any]) throws -> [String:Any] {
        if process == nil {
            let compiler = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("typst-compiler")
            let candidate = FileManager.default.isExecutableFile(atPath: compiler.path) ? compiler : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/release/typst-compiler")
            let p = Process(); p.executableURL = candidate
            let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.standardError
            try p.run(); process = p; input = i.fileHandleForWriting; output = o.fileHandleForReading; buffer.removeAll()
        }
        sequence += 1
        let request: [String:Any] = ["jsonrpc":"2.0", "protocolVersion":1, "id":sequence, "method":method, "params":params]
        var data = try JSONSerialization.data(withJSONObject:request); data.append(10)
        try input!.write(contentsOf:data)
        let running = process!
        let deadline = DispatchWorkItem { if running.isRunning { running.terminate() } }
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+90,execute:deadline)
        defer { deadline.cancel() }
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
