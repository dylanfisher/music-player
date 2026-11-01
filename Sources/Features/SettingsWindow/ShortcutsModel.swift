import Commands
import KeyChord
import Settings

/// The Shortcuts pane's logic, apart from AppKit: the commands in sections as the menus list
/// them, the search, and what recording a chord does. Every rule is `KeyBindings`'; this model
/// only turns its answers into overrides to save or a notice to show.
@MainActor
public final class ShortcutsModel {
    public struct Section: Equatable {
        public var title: String
        public var commands: [CommandID]
    }

    /// What a row says under its recorders.
    public enum Notice: Equatable {
        /// Another command has the chord: Replace takes it, Cancel drops the recording.
        case taken(chord: KeyChord, position: ShortcutPosition, by: CommandID)
        case refused(String)
    }

    public private(set) var bindings: KeyBindings
    public let sections: [Section]
    private(set) var notices: [CommandID: Notice] = [:]
    /// Writes changed overrides, by command; an empty override removes the command's entry.
    private let save: ([CommandID: ShortcutOverride]) -> Void

    public init(
        bindings: KeyBindings, appName: String,
        save: @escaping ([CommandID: ShortcutOverride]) -> Void
    ) {
        self.bindings = bindings
        self.save = save
        sections = AppMenus.commandsByMenu(appName: appName).map {
            Section(title: $0.title, commands: $0.commands)
        }
    }

    /// New bindings after a save or a config file edit.
    public func update(_ bindings: KeyBindings) {
        self.bindings = bindings
    }

    public func title(_ id: CommandID) -> String {
        bindings.defaults.command(id)?.title ?? id.rawValue
    }

    public func chord(_ id: CommandID, _ position: ShortcutPosition) -> KeyChord? {
        bindings.chord(of: id, at: position)
    }

    /// The sections with only the commands whose title contains `text`, or whose chords' symbols
    /// do ("⇧⌘P"); empty sections go.
    func filtered(_ text: String) -> [Section] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let commands = section.commands.filter { id in
                title(id).localizedCaseInsensitiveContains(query)
                    || ShortcutPosition.allCases.contains {
                        chord(id, $0)?.symbols.localizedCaseInsensitiveContains(query) == true
                    }
            }
            return commands.isEmpty ? nil : Section(title: section.title, commands: commands)
        }
    }

    /// What the user lost, and why, from clashes in stored data.
    func losses(_ id: CommandID) -> [String] {
        bindings.dropped.filter { $0.command == id }.map { dropped in
            let what = dropped.chord.map { "\($0.symbols) " } ?? ""
            return switch dropped.loss {
            case .takenBy(let other): "\(what)went to \(title(other))."
            case .reserved(let item): "\(what)is the \(item) item's."
            case .fixedTo(let other): "\(what)is fixed to \(title(other))."
            case .fixedPrimary: "The primary shortcut is the Edit menu's."
            }
        }
    }

    func hasOverride(_ id: CommandID) -> Bool {
        !(bindings.overrides[id.rawValue]?.isEmpty ?? true)
    }

    var hasOverrides: Bool { bindings.overrides.values.contains { !$0.isEmpty } }

    public func record(_ chord: KeyChord, for id: CommandID, at position: ShortcutPosition) {
        apply(bindings.assign(chord, to: id, at: position, replacing: false), id, chord, position)
    }

    /// Takes the chord the notice names from the command that has it.
    func replace(for id: CommandID) {
        guard case .taken(let chord, let position, _) = notices[id] else { return }
        apply(bindings.assign(chord, to: id, at: position, replacing: true), id, chord, position)
    }

    public func cancel(for id: CommandID) { notices[id] = nil }

    func remove(from id: CommandID, at position: ShortcutPosition) {
        apply(bindings.remove(from: id, at: position), id, nil, position)
    }

    func reset(_ id: CommandID) {
        notices[id] = nil
        save([id: ShortcutOverride()])
    }

    func resetAll() {
        notices = [:]
        save(
            Dictionary(
                uniqueKeysWithValues: bindings.overrides.keys.map {
                    (CommandID($0), ShortcutOverride())
                }))
    }

    private func apply(
        _ assignment: KeyBindings.Assignment, _ id: CommandID, _ chord: KeyChord?,
        _ position: ShortcutPosition
    ) {
        switch assignment {
        case .assigned(let changes):
            notices[id] = nil
            if !changes.isEmpty { save(changes) }
        case .taken(let other):
            notices[id] = chord.map { .taken(chord: $0, position: position, by: other) }
        case .reserved(let item):
            notices[id] = .refused(
                "\(chord?.symbols ?? "That") is the \(item) item's, which always takes it.")
        case .fixed(let other):
            notices[id] = .refused(
                "\(chord?.symbols ?? "That") is \(title(other))'s in the Edit menu, for text fields."
            )
        case .fixedPrimary:
            notices[id] = .refused("The primary shortcut is the Edit menu's, for text fields.")
        }
    }

    /// A notice as the row shows it: "⇧⌘P is used by Go to Item."
    public func text(of notice: Notice) -> String {
        switch notice {
        case .taken(let chord, _, let other): "\(chord.symbols) is used by \(title(other))."
        case .refused(let why): why
        }
    }
}
