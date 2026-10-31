import FuzzyMatch

/// One row the palette can list.
public struct PaletteItem: Sendable {
    /// In the order equal scores rank them.
    public enum Kind: Int, Sendable, Comparable {
        case command, setting, playlist, genre, artist, album, track

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public let kind: Kind
    /// Names the item for frecency and for the app to act on: "artist:Abba", "command:…".
    public let key: String
    public let title: String
    public let detail: String?
    /// A command's chord in effect, as a menu draws it.
    public let chord: String?
    /// An off command is listed greyed, and Return beeps on it.
    public let isEnabled: Bool
    let candidate: FuzzyCandidate

    public init(
        kind: Kind, key: String, title: String, detail: String? = nil, chord: String? = nil,
        isEnabled: Bool = true
    ) {
        self.kind = kind
        self.key = key
        self.title = title
        self.detail = detail
        self.chord = chord
        self.isEnabled = isEnabled
        candidate = FuzzyCandidate(title)
    }
}
