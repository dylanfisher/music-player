/// A key plus the modifiers held with it. Each chord has one spelling, so two commands given the
/// same key always collide where the registry can see it.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public enum Key: Hashable, Sendable, ExpressibleByExtendedGraphemeClusterLiteral {
        /// The character the key types without Shift: `"g"`, `"1"`, `"."`. `KeyChord.init`
        /// rejects any other spelling.
        case character(Character)
        case up, down, left, right
        /// Fn-↑ and Fn-↓ on a laptop keyboard.
        case pageUp, pageDown
        /// Fn-← and Fn-→ on a laptop keyboard.
        case home, end
        case tab, `return`, delete, space, escape
        /// F1 to F35.
        case function(Int)

        public init(extendedGraphemeClusterLiteral value: Character) {
            self = .character(value)
        }
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let command = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public static let functionKeys = 1...35

    public let key: Key
    public let modifiers: Modifiers

    /// Traps on a character with another spelling: an uppercase letter is its lowercase plus
    /// `.shift`, and whitespace and control characters are the named keys (`.space`, `.tab`,
    /// `.return`, `.escape`, `.delete`).
    public init(_ key: Key, _ modifiers: Modifiers = []) {
        if case .character(let character) = key {
            precondition(
                Self.accepts(character), "\(character.debugDescription) has another spelling")
        }
        if case .function(let number) = key {
            precondition(Self.functionKeys.contains(number), "there is no F\(number) key")
        }
        self.key = key
        self.modifiers = modifiers
    }

    /// Whether `init` takes `character` as a `.character` key.
    public static func accepts(_ character: Character) -> Bool {
        !character.isUppercase && !character.isWhitespace
            && !character.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// Whether a menu item may have the chord as its key equivalent: it has Command, Control or
    /// Option, or is an F-key. Any other chord (Space, Return, an arrow, a letter) would be taken
    /// from the text fields that type it, so it reaches its command from the focused view.
    public var canBeKeyEquivalent: Bool {
        if case .function = key { return true }
        return !modifiers.isDisjoint(with: [.command, .control, .option])
    }

    public var description: String { stored }

    // MARK: Stored spelling

    private static let storedModifiers: [(Modifiers, String)] = [
        (.control, "ctrl"), (.option, "opt"), (.command, "cmd"), (.shift, "shift"),
    ]

    private static let namedKeys: [Key] = [
        .up, .down, .left, .right, .pageUp, .pageDown, .home, .end, .tab, .return, .delete,
        .space, .escape,
    ]

    /// The modifiers held, in the order ctrl, opt, cmd, shift, then the key, joined by "+":
    /// "cmd+shift+k", "cmd++", "f5", "pageup".
    public var stored: String {
        let held = Self.storedModifiers.filter { modifiers.contains($0.0) }.map(\.1)
        return (held + [Self.storedName(of: key)]).joined(separator: "+")
    }

    /// The chord `stored` spells; nil for any other spelling, such as "shift+cmd+k" or "cmd+K",
    /// so each chord reads back from one string.
    public init?(stored: String) {
        let name: Substring
        let held: Substring
        if stored.hasSuffix("++") {
            name = "+"
            held = stored.dropLast(2)
        } else if stored != "+", let plus = stored.lastIndex(of: "+") {
            name = stored[stored.index(after: plus)...]
            held = stored[..<plus]
        } else {
            name = Substring(stored)
            held = ""
        }
        var modifiers: Modifiers = []
        if !held.isEmpty {
            for part in held.split(separator: "+", omittingEmptySubsequences: false) {
                guard let modifier = Self.storedModifiers.first(where: { $0.1 == part }) else {
                    return nil
                }
                modifiers.insert(modifier.0)
            }
        }
        guard let key = Self.key(storedName: name) else { return nil }
        let chord = KeyChord(key, modifiers)
        guard chord.stored == stored else { return nil }
        self = chord
    }

    private static func storedName(of key: Key) -> String {
        switch key {
        case .character(let character): String(character)
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .pageUp: "pageup"
        case .pageDown: "pagedown"
        case .home: "home"
        case .end: "end"
        case .tab: "tab"
        case .return: "return"
        case .delete: "delete"
        case .space: "space"
        case .escape: "escape"
        case .function(let number): "f\(number)"
        }
    }

    private static func key(storedName name: Substring) -> Key? {
        if let named = namedKeys.first(where: { storedName(of: $0) == name }) { return named }
        if name.count > 1, name.first == "f", let number = Int(name.dropFirst()),
            functionKeys.contains(number)
        {
            return .function(number)
        }
        guard name.count == 1, let character = name.first, accepts(character) else { return nil }
        return .character(character)
    }

    // MARK: Display

    /// The chord as a menu draws it, such as "⇧⌘K": ⌃ ⌥ ⇧ ⌘, then the key.
    public var symbols: String {
        let held: [(Modifiers, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        let key: String =
            switch key {
            case .character(let character): character.uppercased()
            case .up: "↑"
            case .down: "↓"
            case .left: "←"
            case .right: "→"
            case .pageUp: "⇞"
            case .pageDown: "⇟"
            case .home: "↖"
            case .end: "↘"
            case .tab: "⇥"
            case .return: "↩"
            case .delete: "⌫"
            case .space: "Space"
            case .escape: "⎋"
            case .function(let number): "F\(number)"
            }
        return held.filter { modifiers.contains($0.0) }.map(\.1).joined() + key
    }
}
