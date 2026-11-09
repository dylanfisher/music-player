/// What the palette's field asks for: the text to match, and the one kind to list when it
/// starts with a kind's name and a colon, as `album: dream` does (ADR 0160).
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
    /// The words a query names this kind by, before its colon; a track is a song too.
    var queryNames: [String] {
        switch self {
        case .command: ["command"]
        case .setting: ["setting"]
        case .output: ["output"]
        case .playlist: ["playlist"]
        case .genre: ["genre"]
        case .artist: ["artist"]
        case .album: ["album"]
        case .track: ["song", "track"]
        }
    }

    /// The kind `name` names, whatever its case; nil for any other word.
    init?(queryName name: Substring) {
        let name = name.lowercased()
        guard let kind = Self.allCases.first(where: { $0.queryNames.contains(name) }) else {
            return nil
        }
        self = kind
    }
}
