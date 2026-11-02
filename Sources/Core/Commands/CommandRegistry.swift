import KeyChord

/// Commands by ID and by chord. A key has one meaning in the app and one in the palette:
/// registering a second command on an ID, or on a chord already taken where it applies, throws
/// and adds nothing.
public struct CommandRegistry: Sendable {
    public private(set) var commands: [Command] = []
    private var byID: [CommandID: Int] = [:]
    private var byChord: [KeyChord: CommandID] = [:]
    private var byPaletteChord: [KeyChord: CommandID] = [:]

    init() {}

    init(_ commands: [Command]) throws {
        for command in commands { try register(command) }
    }

    mutating func register(_ command: Command) throws {
        if byID[command.id] != nil { throw CommandConflict(id: command.id, other: command.id) }
        for chord in command.chords {
            if let other = self.command(for: chord, inPalette: command.inPalette) {
                throw CommandConflict(id: command.id, other: other, chord: chord)
            }
        }
        byID[command.id] = commands.count
        commands.append(command)
        for chord in command.chords {
            if command.inPalette {
                byPaletteChord[chord] = command.id
            } else {
                byChord[chord] = command.id
            }
        }
    }

    public func command(_ id: CommandID) -> Command? { byID[id].map { commands[$0] } }

    /// The command `chord` runs in the app, or with `inPalette` in the palette.
    public func command(for chord: KeyChord, inPalette: Bool = false) -> CommandID? {
        (inPalette ? byPaletteChord : byChord)[chord]
    }
}

/// Two commands registered on one ID, or on one chord.
struct CommandConflict: Error, Equatable, CustomStringConvertible {
    var id: CommandID
    var other: CommandID
    var chord: KeyChord?

    var description: String {
        if let chord { return "\(id) and \(other) both have \(chord.stored)" }
        return "\(id) is registered twice"
    }
}
