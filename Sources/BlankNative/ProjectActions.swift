import AppKit
import BlankCore

@MainActor extension DocumentSession {
    func projectAssetPath(_ literal: String, file: String? = nil) -> String? {
        let base = URL(fileURLWithPath:"/project").appendingPathComponent(((file ?? active) as NSString).deletingLastPathComponent)
        let target = base.appendingPathComponent(literal).standardizedFileURL
        guard !literal.hasPrefix("/"), target.path.hasPrefix("/project/") else { return nil }
        return String(target.path.dropFirst("/project/".count))
    }
    func relativeAssetPath(_ path: String) -> String {
        let from = (active as NSString).deletingLastPathComponent.split(separator:"/").map(String.init), to = path.split(separator:"/").map(String.init)
        var common = 0; while common < min(from.count,to.count) && from[common] == to[common] { common += 1 }
        return (Array(repeating:"..",count:from.count-common)+to.dropFirst(common)).joined(separator:"/")
    }
    func saveCopy(to url: URL) throws {
        let destination = url.deletingLastPathComponent(), newEntry = url.lastPathComponent
        guard newEntry == entry || buffers[newEntry] == nil else { throw CocoaError(.fileWriteFileExists) }
        var dependencies = assets
        if let root {
            for path in referencedAssets() where dependencies[path] == nil {
                dependencies[path] = try Data(contentsOf:Self.dependencyTarget(path,root:root))
            }
        }
        for (path,model) in buffers where path != entry { dependencies[path] = Data(model.source.utf8) }
        if includes.count > 1 || root.map({ FileManager.default.fileExists(atPath:$0.appendingPathComponent("writer.json").path) }) == true {
            var config = root.flatMap { try? Data(contentsOf:$0.appendingPathComponent("writer.json")) }.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] } ?? [:]
            config["entry"] = newEntry; dependencies["writer.json"] = try JSONSerialization.data(withJSONObject:config,options:[.prettyPrinted,.sortedKeys])
        }
        // All collisions are checked before creating any destination files.
        for (path,data) in dependencies {
            let target = try Self.dependencyTarget(path,root:destination)
            guard target != url else { throw CocoaError(.fileWriteFileExists) }
            if FileManager.default.fileExists(atPath:target.path), try Data(contentsOf:target) != data { throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"\(path) already exists with different content. Choose an empty folder."]) }
        }
        for (path,data) in dependencies { try Self.writeDependency(data,path:path,root:destination) }
        try Data(buffers[entry]!.source.utf8).write(to:url,options:.atomic)
        let old = entry; buffers[newEntry] = buffers.removeValue(forKey:old)
        if active == old { active = newEntry }; entry = newEntry; root = destination; bases = buffers.mapValues(\.source); dirty = false
        installWatchers(); onTitle?(); persistRecovery(); NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
    func renameEntry(_ requested: String) throws {
        let name = requested.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains(where:{ "/\\\0".contains($0) }) else { throw NSError(domain:"blank_",code:1,userInfo:[NSLocalizedDescriptionKey:"Choose a filename without folders."]) }
        let leaf = name.lowercased().hasSuffix(".typ") ? name : name+".typ"
        let next = (entry as NSString).deletingLastPathComponent.isEmpty ? leaf : (entry as NSString).deletingLastPathComponent+"/"+leaf
        guard next != entry else { return }
        guard buffers[next] == nil else { throw CocoaError(.fileWriteFileExists) }
        if let root {
            try saveToDisk()
            let from = try Self.dependencyTarget(entry,root:root), to = try Self.dependencyTarget(next,root:root)
            try FileManager.default.linkItem(at:from,to:to)
            let configURL = root.appendingPathComponent("writer.json"), config = try? Data(contentsOf:configURL)
            do {
                if let config, var object = try JSONSerialization.jsonObject(with:config) as? [String:Any], object["entry"] as? String == entry {
                    object["entry"] = next
                    try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:configURL,options:.atomic)
                }
                try FileManager.default.removeItem(at:from)
            } catch {
                try? FileManager.default.removeItem(at:to)
                if let config { try? config.write(to:configURL,options:.atomic) }
                throw error
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(to)
        }
        let old = entry; buffers[next] = buffers.removeValue(forKey:old); bases[next] = bases.removeValue(forKey:old)
        if active == old { active = next }; entry = next; revision += 1; installWatchers(); persistRecovery(); onTitle?()
    }

    // Exact article/thesis starting content from cmd/blank_/app.go on the Go reference.
    static func template(_ kind: String) -> DocumentSession {
        let preamble = "#set page(paper: \"a4\", margin: 2.5cm)\n#set text(font: \"Libertinus Serif\", size: 11pt)\n#set heading(numbering: \"1.1\")\n\n"
        var files = ["writer-zotero.bib":"", "writer-references.json":"{}\n"]
        if kind == "thesis" {
            files["main.typ"] = preamble+"#align(center)[\n  #text(size: 26pt, weight: \"bold\")[A thesis in progress]\n\n  Your name\n]\n#pagebreak()\n#outline()\n#pagebreak()\n\n#include \"chapters/01-introduction.typ\"\n#include \"chapters/02-methods.typ\"\n\n#bibliography(\"writer-zotero.bib\", style: \"apa\")\n"
            files["chapters/01-introduction.typ"] = "= Introduction <introduction>\n\nEvery worthwhile investigation begins with a question. What is yours?\n\n== The question\n\nStart writing here.\n"
            files["chapters/02-methods.typ"] = "= Methods <methods>\n\nDescribe how you will approach your question.\n"
        } else {
            files["main.typ"] = preamble+"#align(center)[#text(size: 24pt, weight: \"bold\")[Untitled paper]]\n\n= Introduction <introduction>\n\nStart with the idea you want to explore.\n\n= Discussion\n\nYour next thought belongs here.\n\n#bibliography(\"writer-zotero.bib\", style: \"apa\")\n"
        }
        let session = DocumentSession(); session.buffers = files.mapValues { DocumentBuffer($0) }; session.active = "main.typ"; session.entry = "main.typ"; session.dirty = true
        return session
    }
}
