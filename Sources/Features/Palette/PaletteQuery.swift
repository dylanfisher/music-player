import Settings

/// What the palette's field asks for (ADR 0161).
typealias PaletteQuery = TypedQuery<PaletteItem.Kind>

extension PaletteItem.Kind: QueryKind {
    /// The kind's name, as a query types it before a colon, and with one the start of a
    /// command's, a setting's and a track's key (`command:…`). It's the case's name; a test
    /// holds the spellings, so renaming a case can't change what users type or the keys
    /// frecency saved.
    public var name: String { "\(self)" }
    public var keyPrefix: String { name + ":" }

    /// The library kind this one lists; none for the ⌘K kinds.
    var searchKind: SearchKind? {
        switch self {
        case .album: .album
        case .artist: .artist
        case .track: .track
        case .playlist: .playlist
        case .genre: .genre
        case .command, .setting, .output: nil
        }
    }

    /// The short word a query may name the kind by instead; none for the ⌘K kinds.
    var shortName: String? { searchKind?.shortName }

    public var queryNames: [String] { [name] + (shortName.map { [$0] } ?? []) }
}
