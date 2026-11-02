import KeyChord
import Settings

/// The menus' chords no command may take: `reserved` belong to standard items that always take
/// the key first (Quit, Hide, Cut…), by chord with the item's title; `fixed` are the primaries of
/// the commands an Edit item runs (Select All on ⌘A), which text fields need.
public struct ChordRules: Sendable {
    public var reserved: [KeyChord: String]
    public var fixed: [CommandID: KeyChord]

    init(reserved: [KeyChord: String] = [:], fixed: [CommandID: KeyChord] = [:]) {
        self.reserved = reserved
        self.fixed = fixed
    }
}

/// The chords in effect: each command's defaults with the user's overrides on top, under the
/// menus' rules. The one place they're combined, so the menus, the keys, the palette and the
/// Shortcuts pane agree.
public struct KeyBindings: Sendable {
    /// Why a chord the defaults or the user gave a command isn't one of its chords.
    public enum Loss: Hashable, Sendable {
        /// The user gave it to that command, which claims it first.
        case takenBy(CommandID)
        /// A standard menu item's, named here.
        case reserved(String)
        /// The fixed primary of that command.
        case fixedTo(CommandID)
        /// The user changed or removed a fixed primary; it stays.
        case fixedPrimary
        /// A palette key that types in the palette's field: taken before the field, that
        /// character could never be typed in the query.
        case typesInPalette
    }

    public struct Dropped: Equatable, Sendable, CustomStringConvertible {
        public var command: CommandID
        public var position: ShortcutPosition
        public var chord: KeyChord?
        public var loss: Loss

        public var description: String {
            let what = chord.map { "\($0.symbols) " } ?? ""
            return switch loss {
            case .takenBy(let other): "\(command) \(position): \(what)is \(other)'s"
            case .reserved(let title): "\(command) \(position): \(what)is the \(title) item's"
            case .fixedTo(let other): "\(command) \(position): \(what)is fixed to \(other)"
            case .fixedPrimary: "\(command) \(position): the primary is fixed"
            case .typesInPalette: "\(command) \(position): \(what)types in the palette's field"
            }
        }
    }

    /// What recording `chord` in a slot would do.
    public enum Assignment: Equatable, Sendable {
        /// The overrides to store, by command: one or two commands change. An empty override
        /// means the command's entry goes.
        case assigned([CommandID: ShortcutOverride])
        case taken(by: CommandID)
        case reserved(String)
        case fixed(to: CommandID)
        case fixedPrimary
        case typesInPalette
    }

    public let defaults: CommandRegistry
    public let overrides: ShortcutOverrides
    public let rules: ChordRules
    /// The commands with their chords in effect, the primary first; a removed primary leaves
    /// the alternate first, so the menus show it.
    public private(set) var registry = CommandRegistry()
    public private(set) var dropped: [Dropped] = []
    private var slots: [CommandID: [ShortcutPosition: KeyChord]] = [:]

    /// Throws when two defaults share a chord or a default is reserved, which are mistakes in
    /// the code. Stored overrides never make it throw: a clash costs the other command its
    /// chord, listed in `dropped`. Overrides for IDs no command has are ignored here; the
    /// config file reports them.
    public init(_ commands: [Command], overrides: ShortcutOverrides, rules: ChordRules) throws {
        defaults = try CommandRegistry(commands)
        self.overrides = overrides
        self.rules = rules
        for command in commands {
            for chord in command.chords {
                if let title = rules.reserved[chord] {
                    throw ReservedDefault(command: command.id, chord: chord, item: title)
                }
            }
        }
        // By whether the chord is the palette's.
        var claimed: [Bool: [KeyChord: CommandID]] = [:]
        func claim(_ chord: KeyChord, _ command: Command, _ position: ShortcutPosition) -> Bool {
            let id = command.id
            if let title = rules.reserved[chord] {
                dropped.append(
                    Dropped(command: id, position: position, chord: chord, loss: .reserved(title)))
                return false
            }
            if command.inPalette, chord.typesText {
                dropped.append(
                    Dropped(command: id, position: position, chord: chord, loss: .typesInPalette))
                return false
            }
            // The palette's field needs a fixed chord as much as any text field.
            let fixedOwner = rules.fixed.first { $0.value == chord }?.key
            if let owner = claimed[command.inPalette]?[chord]
                ?? (command.inPalette ? fixedOwner : nil)
            {
                if owner != id {
                    let loss: Loss = rules.fixed[owner] == chord ? .fixedTo(owner) : .takenBy(owner)
                    dropped.append(
                        Dropped(command: id, position: position, chord: chord, loss: loss))
                }
                return false
            }
            claimed[command.inPalette, default: [:]][chord] = id
            slots[id, default: [:]][position] = chord
            return true
        }
        // Fixed primaries first, then the user's chords, then the defaults.
        for command in commands {
            guard let fixed = rules.fixed[command.id] else { continue }
            _ = claim(fixed, command, .primary)
            if let slot = overrides[command.id.rawValue]?.primary, slot != .chord(fixed) {
                dropped.append(
                    Dropped(
                        command: command.id, position: .primary, chord: slot.chord,
                        loss: .fixedPrimary))
            }
        }
        for command in commands {
            for position in ShortcutPosition.allCases {
                if position == .primary, rules.fixed[command.id] != nil { continue }
                if case .chord(let chord) = overrides[command.id.rawValue]?[position] {
                    _ = claim(chord, command, position)
                }
            }
        }
        for command in commands {
            for position in ShortcutPosition.allCases {
                if position == .primary, rules.fixed[command.id] != nil { continue }
                guard overrides[command.id.rawValue]?[position] == nil,
                    let chord = command.chord(at: position)
                else { continue }
                _ = claim(chord, command, position)
            }
        }
        for command in commands {
            var command = command
            command.chords = ShortcutPosition.allCases.compactMap { slots[command.id]?[$0] }
            try registry.register(command)
        }
    }

    /// The chord in effect at `position`.
    public func chord(of id: CommandID, at position: ShortcutPosition) -> KeyChord? {
        slots[id]?[position]
    }

    /// The rule for recording `chord` at `position` of `id`. With `replacing`, a command that
    /// has the chord loses it. A chord the command has in its other slot moves.
    public func assign(
        _ chord: KeyChord, to id: CommandID, at position: ShortcutPosition, replacing: Bool
    ) -> Assignment {
        if let title = rules.reserved[chord] { return .reserved(title) }
        if let owner = rules.fixed.first(where: { $0.value == chord })?.key,
            owner != id || position != .primary
        {
            return .fixed(to: owner)
        }
        if position == .primary, let fixed = rules.fixed[id] {
            return fixed == chord ? .assigned([:]) : .fixedPrimary
        }
        let inPalette = defaults.command(id)?.inPalette ?? false
        if inPalette, chord.typesText { return .typesInPalette }
        var changes: [CommandID: ShortcutOverride] = [:]
        if let owner = registry.command(for: chord, inPalette: inPalette), owner != id {
            guard replacing else { return .taken(by: owner) }
            let lost = ShortcutPosition.allCases.first { slots[owner]?[$0] == chord } ?? .primary
            changes[owner] = setting(owner, lost, to: .removed, in: overrides[owner.rawValue])
        }
        var mine = overrides[id.rawValue] ?? ShortcutOverride()
        let other: ShortcutPosition = position == .primary ? .alternate : .primary
        if slots[id]?[other] == chord {
            mine = setting(id, other, to: .removed, in: mine)
        }
        changes[id] = setting(id, position, to: .chord(chord), in: mine)
        return .assigned(changes)
    }

    /// The overrides that take away the chord at `position`; `.fixedPrimary` for a fixed one.
    public func remove(from id: CommandID, at position: ShortcutPosition) -> Assignment {
        if position == .primary, rules.fixed[id] != nil { return .fixedPrimary }
        return .assigned([id: setting(id, position, to: .removed, in: overrides[id.rawValue])])
    }

    /// `override` with `position` set to `slot`, where a slot equal to the default is stored as
    /// no change, so "default" has one stored form.
    private func setting(
        _ id: CommandID, _ position: ShortcutPosition, to slot: ShortcutSlot,
        in override: ShortcutOverride?
    ) -> ShortcutOverride {
        var override = override ?? ShortcutOverride()
        let standard = defaults.command(id)?.chord(at: position)
        switch slot {
        case .removed: override[position] = standard == nil ? nil : .removed
        case .chord(let chord): override[position] = chord == standard ? nil : slot
        }
        return override
    }

    /// Why the config file can't give `slot` at `position` of the command `id`, or nil when it
    /// can. Two slots given one chord isn't a problem: the first command keeps it.
    public func problem(id: String, position: ShortcutPosition, slot: ShortcutSlot) -> String? {
        let command = CommandID(id)
        guard defaults.command(command) != nil else { return "no command has the ID \"\(id)\"" }
        if position == .primary, let fixed = rules.fixed[command], slot != .chord(fixed) {
            return "the primary is fixed to \(fixed.stored), for text fields"
        }
        guard case .chord(let chord) = slot else { return nil }
        if let title = rules.reserved[chord] {
            return "\(chord.stored) is the \(title) item's, which always takes it"
        }
        if let owner = rules.fixed.first(where: { $0.value == chord })?.key, owner != command {
            return "\(chord.stored) is fixed to \(owner), for text fields"
        }
        if defaults.command(command)?.inPalette == true, chord.typesText {
            return "\(chord.stored) types in the palette's field, so a palette key can't have it"
        }
        return nil
    }
}

extension ShortcutSlot {
    fileprivate var chord: KeyChord? {
        if case .chord(let chord) = self { return chord }
        return nil
    }
}

/// A default chord a standard menu item has, which the item would always take first.
struct ReservedDefault: Error, CustomStringConvertible {
    var command: CommandID
    var chord: KeyChord
    var item: String

    var description: String { "\(command)'s default \(chord.stored) is the \(item) item's" }
}
