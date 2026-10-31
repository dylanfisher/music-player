import KeyChord

/// One of a command's two chords. The menus show the primary.
public enum ShortcutPosition: String, CaseIterable, Sendable {
    case primary, alternate
}

/// What the user put in one position instead of its default.
public enum ShortcutSlot: Equatable, Sendable {
    /// No chord, though the command has a default there.
    case removed
    case chord(KeyChord)
}

/// The user's changes to one command's chords. A position left nil keeps its default.
public struct ShortcutOverride: Equatable, Sendable {
    public var primary: ShortcutSlot?
    public var alternate: ShortcutSlot?

    public init(primary: ShortcutSlot? = nil, alternate: ShortcutSlot? = nil) {
        self.primary = primary
        self.alternate = alternate
    }

    public subscript(position: ShortcutPosition) -> ShortcutSlot? {
        get {
            switch position {
            case .primary: primary
            case .alternate: alternate
            }
        }
        set {
            switch position {
            case .primary: primary = newValue
            case .alternate: alternate = newValue
            }
        }
    }

    /// Changes nothing: both positions keep their defaults.
    public var isEmpty: Bool { primary == nil && alternate == nil }
}

/// The user's shortcut changes, by command ID.
public typealias ShortcutOverrides = [String: ShortcutOverride]
