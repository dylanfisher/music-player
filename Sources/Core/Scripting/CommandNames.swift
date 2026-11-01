import Commands

/// What the command line and links call each registry command: the last part of its ID,
/// `next` for `playback.next`, when no other command's ID ends the same way and it isn't a
/// word the tool keeps for itself; otherwise the whole ID. The whole ID always works, and
/// case doesn't matter.
public struct CommandNames: Sendable {
    public let commands: [Command]
    private let byName: [String: Int]
    private let names: [CommandID: String]

    /// Words the tool answers itself.
    enum Builtin: String, CaseIterable {
        case help, status
    }

    public init(_ commands: [Command]) {
        self.commands = commands
        let short = commands.map {
            $0.id.rawValue.split(separator: ".").last.map(String.init) ?? ""
        }
        var counts: [String: Int] = [:]
        for name in short { counts[name.lowercased(), default: 0] += 1 }
        var byName: [String: Int] = [:]
        var names: [CommandID: String] = [:]
        for (index, command) in commands.enumerated() {
            let name = short[index]
            let unique =
                counts[name.lowercased()] == 1 && Builtin(rawValue: name.lowercased()) == nil
            names[command.id] = unique ? name : command.id.rawValue
            if unique { byName[name.lowercased()] = index }
            byName[command.id.rawValue.lowercased()] = index
        }
        self.byName = byName
        self.names = names
    }

    /// The name help shows for `id`.
    public func name(of id: CommandID) -> String { names[id] ?? id.rawValue }

    public func command(named name: String) -> Command? {
        byName[name.lowercased()].map { commands[$0] }
    }
}
