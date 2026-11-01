import KeyChord
import Settings

/// One thing the user can do: its ID, its title as menus and the palette show it, and up to two
/// default chords, the primary and then the alternate.
public struct Command: Sendable, Equatable {
    public let id: CommandID
    public let title: String
    /// The primary first. A command with only an alternate isn't possible: its one chord is the
    /// primary.
    public let chords: [KeyChord]

    init(_ id: CommandID, _ title: String, _ chords: [KeyChord] = []) {
        precondition(chords.count <= 2, "\(id) has more than a primary and an alternate")
        precondition(Set(chords).count == chords.count, "\(id) lists one chord twice")
        self.id = id
        self.title = title
        self.chords = chords
    }

    /// The default chord at `position`.
    public func chord(at position: ShortcutPosition) -> KeyChord? {
        switch position {
        case .primary: chords.first
        case .alternate: chords.count > 1 ? chords[1] : nil
        }
    }
}
