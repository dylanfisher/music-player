/// What the palette's field asks for: the text to match, and the one kind to list when it
/// starts with a kind's name and a colon, as `album: dream` does (ADR 0161).
struct PaletteQuery: Equatable {
    var text: String
    var kind: PaletteItem.Kind?

    init(_ typed: String) {
        if let colon = typed.firstIndex(of: ":"),
            let kind = PaletteItem.Kind(queryName: typed[..<colon])
        {
            self.kind = kind
            text = String(typed[typed.index(after: colon)...].drop { $0 == " " })
        } else {
            kind = nil
            text = typed
        }
    }
}

extension PaletteItem.Kind {
    /// The kind's name, as a query types it before a colon, and with one the start of a
    /// command's, a setting's and a track's key (`command:…`). It's the case's name; a test
    /// holds the spellings, so renaming a case can't change what users type or the keys
    /// frecency saved.
    public var name: String { "\(self)" }
    public var keyPrefix: String { name + ":" }
    /// The other word a query may name tracks by.
    static let songName = "song"

    /// The words a query names this kind by, before its colon.
    var queryNames: [String] { self == .track ? [Self.songName, name] : [name] }

    /// The kind `name` names, whatever its case; nil for any other word.
    init?(queryName name: Substring) {
        let name = name.lowercased()
        guard let kind = Self.allCases.first(where: { $0.queryNames.contains(name) }) else {
            return nil
        }
        self = kind
    }
}
