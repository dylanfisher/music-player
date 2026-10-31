import AppKit
import Commands
import KeyChord

/// Sends a list's key presses where 0012 says: Space while a query is typed joins it, a chord a
/// command has runs it, an unbound chord with ⌘, ⌃ or ⌥ beeps rather than reaching the table's
/// own key bindings, and a printable key types to select. False leaves the key to AppKit.
@MainActor
func routeKey(
    _ event: NSEvent, typeSelect: inout TypeSelect?,
    keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome, select: (String) -> Void
) -> Bool {
    let chords = KeyChord.candidates(for: event)
    guard let chord = chords.first else { return false }
    if chord == KeyChord(.space), typeSelect?.isTyping == true {
        select(typeSelect!.add(" "))
        return true
    }
    switch keyCommand(chords) {
    case .ran:
        typeSelect?.reset()
        return true
    case .refused:
        NSSound.beep()
        return true
    case .unbound:
        break
    }
    if !chord.modifiers.isDisjoint(with: [.command, .control, .option]) {
        NSSound.beep()
        return true
    }
    if typeSelect != nil, case .character = chord.key, let text = event.characters,
        !text.isEmpty
    {
        select(typeSelect!.add(text))
        return true
    }
    return false
}
