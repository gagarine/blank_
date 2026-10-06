import AppKit
import SwiftUI
import BlankCore

enum BibliographyStorage: String, CaseIterable, Identifiable {
    case embedded, bib, yaml
    var id: String { rawValue }
    var label: String {
        switch self { case .embedded: return "Embedded BibLaTeX in .typ"; case .bib: return "External BibLaTeX (.bib)"; case .yaml: return "External Hayagriva (.yaml)" }
    }
    var format: String { self == .yaml ? "yaml" : "bib" }
}
struct BibliographyConversionInput: Identifiable {
    let file: String
    let call: BibliographyCall
    let input: BibliographyInput
    let line: Int
    let index: Int
    var id: String { file+":"+String(call.span.start)+":"+String(index) }
    var label: String { file+":"+String(line)+" · "+(input.path ?? "Embedded bibliography")+(call.inputs.count > 1 ? " (input \(index+1))" : "") }
}
@MainActor extension DocumentSession {
    var bibliographyConversionInputs: [BibliographyConversionInput] {
        bibliographyLocations.flatMap { location in
            let line = buffers[location.file]!.source.bytes(ByteSpan(0,location.call.span.start)).filter { $0 == "\n" }.count+1
            return location.call.inputs.enumerated().map { BibliographyConversionInput(file:location.file,call:location.call,input:$0.element,line:line,index:$0.offset) }
        }
    }
    static func conversionEmbeddedExpression(_ text: String) -> String {
        var fence = "```"; while text.contains(fence) { fence += "`" }
        let raw = "bytes(\n"+fence+"bib\n"+text+"\n"+fence+".text\n)"
        let model = DocumentBuffer("#bibliography("+raw+")")
        // Typst normalizes raw-block line endings. Use a string only when the
        // readable raw form cannot reproduce the original bytes exactly.
        if bibliographyCalls(model.source,model.parsed).first?.inputs.first?.embedded == text { return raw }
        return "bytes("+typstStringLiteral(text)+")"
    }
    func showBibliographyConversion() {
        editor?.finishComposition(); synchronizeSelection(); sheet = .bibliographyConversion
    }
    func convertBibliography(inputID: String,to storage: BibliographyStorage,path requestedPath: String,completion: @escaping (Error?) -> Void) {
        guard requestEditing() else { completion(CocoaError(.userCancelled)); return }
        editor?.finishComposition(); synchronizeSelection()
        guard let location = bibliographyConversionInputs.first(where:{ $0.id == inputID }), let model = buffers[location.file] else { completion(ZoteroIntegration.failure("Choose a bibliography to convert.")); return }
        let input = location.input
        // Replacing a bound value could change unrelated custom expressions.
        guard ["bib","yaml","yml"].contains(input.format), input.expression.start >= location.call.span.start, input.expression.end <= location.call.span.end else { completion(ZoteroIntegration.failure("Conversion requires a direct bibliography file path or bytes input. Edit computed or variable inputs in Source.")); return }
        do {
            let from = input.format == "bib" ? "bib" : "yaml"
            var externalPath: String?
            let text: String
            if let literal = input.path {
                guard let path = projectAssetPath(literal,file:location.file) else { throw ZoteroIntegration.failure("The bibliography is outside the project.") }
                externalPath = path
                if buffers[path] == nil, let root {
                    let source = try String(contentsOf:Self.dependencyTarget(path,root:root),encoding:.utf8)
                    buffers[path] = DocumentBuffer(source); bases[path] = source
                }
                guard let source = buffers[path]?.source else { throw ZoteroIntegration.failure("Cannot read the bibliography.") }; text = source
            } else if let embedded = input.embedded { text = embedded }
            else { throw ZoteroIntegration.failure("Cannot read the embedded bibliography.") }
            var targetPath: String?
            func checkTarget(_ path: String) throws {
                guard buffers[path] == nil, assets[path] == nil else { throw ZoteroIntegration.failure("That project file already exists. Choose a new filename.") }
                if let root, FileManager.default.fileExists(atPath:try Self.dependencyTarget(path,root:root).path) { throw ZoteroIntegration.failure("That file already exists. Choose a new filename.") }
            }
            if storage != .embedded {
                let literal = requestedPath.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !literal.isEmpty, let path = projectAssetPath(literal,file:location.file), (path as NSString).pathExtension.lowercased() == storage.format else { throw ZoteroIntegration.failure("Choose a project path ending in .\(storage.format).") }
                guard path != externalPath else { throw ZoteroIntegration.failure("The bibliography already uses that file.") }
                try checkTarget(path); targetPath = path
            } else if input.embedded != nil, from == "bib" { throw ZoteroIntegration.failure("This bibliography is already embedded BibLaTeX.") }
            let current = revision, original = model.source, originalSelection = model.selection
            compiler.convertBibliography(text,from:from,to:storage.format) { [weak self] result in
                guard let self else { completion(CocoaError(.userCancelled)); return }
                do {
                    let converted = try result.get()
                    guard self.revision == current, self.buffers[location.file]?.source == original,
                          externalPath == nil || self.buffers[externalPath!]?.source == text else { throw ZoteroIntegration.failure("The document changed during conversion. Try again.") }
                    guard self.requestEditing() else { throw CocoaError(.userCancelled) }
                    if let targetPath { try checkTarget(targetPath) }
                    let replacement = targetPath.map { typstStringLiteral(self.relativeAssetPath($0,file:location.file)) } ?? Self.conversionEmbeddedExpression(converted)
                    let changedSource = original.replacingBytes(input.expression,with:replacement)
                    let patch = SourcePatch.difference(original,changedSource)!
                    var texts = [location.file:changedSource]
                    if let targetPath { texts[targetPath] = converted }
                    self.commitReferences(texts,selections:[location.file:originalSelection.mapped(through:patch)],undoPath:location.file)
                    completion(nil)
                } catch { completion(error) }
            }
        } catch { completion(error) }
    }
}
struct BibliographyConversionSheet: View {
    @ObservedObject var session: DocumentSession
    @NativeState var inputID = ""
    @NativeState var storage: BibliographyStorage = .embedded
    @NativeState var filename = ""
    @NativeState var failure = ""
    @NativeState var working = false
    var inputs: [BibliographyConversionInput] { session.bibliographyConversionInputs }
    var body: some View {
        SheetFrame(title:"Convert Bibliography",dismiss:{ if !working { session.sheet = nil } }) {
            if inputs.isEmpty { Text("This document has no bibliography to convert.") }
            else {
                Picker("Bibliography",selection:$inputID) {
                    Text("Choose a bibliography…").tag("")
                    ForEach(inputs) { Text($0.label).tag($0.id) }
                }.disabled(working)
                Picker("Store as",selection:$storage) { ForEach(BibliographyStorage.allCases) { Text($0.label).tag($0) } }.disabled(working)
                if storage != .embedded { TextField("File path relative to this .typ file",text:$filename).textFieldStyle(.roundedBorder).disabled(working) }
                Text("Citation keys, Zotero links and style stay the same. Existing files are kept. Format changes retain the original source in a recovery comment.").font(.system(size:12)).foregroundStyle(.secondary)
            }
            if !failure.isEmpty { Text(failure).font(.system(size:12)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { session.sheet = nil }.keyboardShortcut(.cancelAction).disabled(working)
                Button(working ? "Converting…" : "Convert") {
                    working = true; failure = ""
                    session.convertBibliography(inputID:inputID,to:storage,path:filename) { error in
                        working = false
                        if let error { failure = error.localizedDescription } else { session.sheet = nil }
                    }
                }.keyboardShortcut(.defaultAction).disabled(working || inputID.isEmpty)
            }
        }.onAppear {
            if inputs.count == 1 { inputID = inputs[0].id }
            storage = inputs.first?.input.embedded != nil ? .bib : .embedded
            updateFilename()
        }.onChange(of:storage) { _,_ in updateFilename() }
        .onChange(of:inputID) { _,_ in updateFilename() }
    }
    private func updateFilename() {
        let file = inputs.first(where:{ $0.id == inputID })?.file ?? session.entry
        filename = ((file as NSString).lastPathComponent as NSString).deletingPathExtension+"-references."+storage.format
    }
}
