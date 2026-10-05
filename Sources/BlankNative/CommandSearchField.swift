import AppKit
import SwiftUI

// Keep native text input throughout the handoff from the document to Cmd-K.
// Replaying keys into the field editor preserves its input-method handling;
// no characters are interpreted or translated by the document editor.
struct CommandSearchField: NSViewRepresentable {
    @ObservedObject var session: DocumentSession
    var submit: () -> Void
    var move: (Int) -> Void
    var changed: () -> Void
    func makeNSView(context: Context) -> CommandSearchTextField {
        let field = CommandSearchTextField()
        field.placeholderString = "Search commands…"
        field.setAccessibilityLabel("Search commands")
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize:13)
        field.delegate = field
        return field
    }
    func updateNSView(_ field: CommandSearchTextField,context: Context) {
        field.session = session; field.submit = submit; field.move = move; field.changed = changed
        if field.stringValue != session.commandQuery { field.stringValue = session.commandQuery }
        field.focusWhenAttached()
    }
}
final class CommandSearchTextField: NSTextField, NSTextFieldDelegate {
    weak var session: DocumentSession?
    var submit: () -> Void = {}
    var move: (Int) -> Void = { _ in }
    var changed: () -> Void = {}
    private var didFocus = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); focusWhenAttached()
    }
    func focusWhenAttached() {
        guard !didFocus, let window, let session else { return }
        // Finish attaching the SwiftUI sheet before selecting its field editor.
        DispatchQueue.main.async { [weak self,weak window,weak session] in
            guard let self, !self.didFocus, let window, let session, session.sheet == .commands,
                  window.makeFirstResponder(self), let editor = self.currentEditor() as? NSTextView else { return }
            self.didFocus = true
            let events = session.pendingCommandKeys; session.pendingCommandKeys.removeAll()
            for event in events where session.sheet == .commands { editor.keyDown(with:event) }
        }
    }
    func controlTextDidChange(_ notification: Notification) { session?.commandQuery = stringValue; changed() }
    func control(_ control: NSControl,textView: NSTextView,doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): submit()
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.cancelOperation(_:)): session?.sheet = nil
        default: return false
        }
        return true
    }
}
