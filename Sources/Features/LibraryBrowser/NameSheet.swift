import AppKit

/// Asks over `window` for a name, its field filled with `initial`: New Playlist, Rename Playlist
/// and a Listening Stats list saved as a playlist. Answers the name, trimmed, on `button`; an
/// empty one beeps and answers nothing, as Cancel does.
@MainActor
public func askForName(
    _ title: String, button: String, initial: String, over window: NSWindow,
    _ done: @escaping (String) -> Void
) {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = initial
    alert.accessoryView = field
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
        guard response == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            NSSound.beep()
            return
        }
        done(name)
    }
}
