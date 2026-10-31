import KeyChord

/// Commands by ID and by chord. A key has one meaning: registering a second command on an ID or
/// a chord already taken throws and adds nothing.
public struct CommandRegistry: Sendable {
    public private(set) var commands: [Command] = []
    private var byID: [CommandID: Int] = [:]
    private var byChord: [KeyChord: CommandID] = [:]

    public init() {}

    public init(_ commands: [Command]) throws {
        for command in commands { try register(command) }
    }

    public mutating func register(_ command: Command) throws {
        if byID[command.id] != nil { throw CommandConflict(id: command.id, other: command.id) }
        for chord in command.chords {
            if let other = byChord[chord] {
                throw CommandConflict(id: command.id, other: other, chord: chord)
            }
        }
        byID[command.id] = commands.count
        commands.append(command)
        for chord in command.chords { byChord[chord] = command.id }
    }

    public func command(_ id: CommandID) -> Command? { byID[id].map { commands[$0] } }

    /// The command `chord` runs.
    public func command(for chord: KeyChord) -> CommandID? { byChord[chord] }
}

/// Two commands registered on one ID, or on one chord.
public struct CommandConflict: Error, Equatable, CustomStringConvertible {
    public var id: CommandID
    public var other: CommandID
    public var chord: KeyChord?

    public var description: String {
        if let chord { return "\(id) and \(other) both have \(chord.stored)" }
        return "\(id) is registered twice"
    }
}
