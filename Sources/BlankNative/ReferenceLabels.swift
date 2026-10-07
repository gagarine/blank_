import AppKit
import SwiftUI
import BlankCore

@MainActor extension DocumentSession {
    var referenceLabels: [String] {
        // Swift String equality normalizes Unicode. Typst names retain their
        // source bytes, so canonically equivalent spellings are distinct items.
        var seen = Set<Data>()
        return projectFiles.union([active]).flatMap { buffers[$0]?.literalLabels ?? [] }
            .filter { seen.insert(Data($0.utf8)).inserted }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}

// Preserve valid literal names, including Unicode combining marks which the
// older convenience sanitizer can remove. Retain its handling of other input.
func crossReferenceTarget(_ text: String) -> String {
    let literal = "<"+text+">", parsed = ParsedSource.parse(literal)
    if !parsed.erroneous, parsed.tree.children.count == 1,
       let node = parsed.tree.children.first, node.kind == "Label", node.span.count == literal.utf8.count {
        return text
    }
    return safeLabel(text)
}

struct ReferenceLabelField: NSViewRepresentable {
    @Binding var text: String
    var labels: [String]
    var submit: () -> Void
    var cancel: () -> Void
    func makeNSView(context: Context) -> ReferenceLabelComboBox {
        let field = ReferenceLabelComboBox()
        field.placeholderString = "Label name"
        field.setAccessibilityLabel("Cross-reference label")
        field.toolTip = "Choose an existing label or enter a new target"
        field.isEditable = true; field.completes = false
        field.numberOfVisibleItems = 8
        field.font = .systemFont(ofSize:13)
        field.delegate = field
        return field
    }
    func updateNSView(_ field: ReferenceLabelComboBox,context: Context) {
        field.changed = { text = $0 }; field.submit = submit; field.cancel = cancel
        if field.objectValues as? [String] != labels { field.removeAllItems(); field.addItems(withObjectValues:labels) }
        if field.stringValue != text { field.stringValue = text }
        field.focusWhenAttached()
    }
}

final class ReferenceLabelComboBox: NSComboBox, NSComboBoxDelegate {
    var changed: (String) -> Void = { _ in }
    var submit: () -> Void = {}
    var cancel: () -> Void = {}
    private var didFocus = false
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusWhenAttached() }
    func focusWhenAttached() {
        guard !didFocus, let window else { return }
        DispatchQueue.main.async { [weak self,weak window] in
            guard let self, !self.didFocus, let window, self.window === window,
                  window.makeFirstResponder(self) else { return }
            self.didFocus = true
        }
    }
    func controlTextDidChange(_ notification: Notification) { changed(stringValue) }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let value = objectValueOfSelectedItem as? String { stringValue = value; changed(value) }
    }
    func control(_ control: NSControl,textView: NSTextView,doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): submit()
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        default: return false
        }
        return true
    }
}
