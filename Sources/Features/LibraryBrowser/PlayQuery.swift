/// What `music-player play <text>` names: the search field's text, or, when it starts with a
/// pane's key prefix as the palette keys its entries (`album:`), one genre, artist or album by
/// name.
public enum PlayQuery: Equatable, Sendable {
    case search(String)
    case entry(BrowserModel.Pane, String)

    public init(_ text: String) {
        for pane in BrowserModel.Pane.allCases
        where text.lowercased().hasPrefix(pane.keyPrefix) {
            self = .entry(pane, String(text.dropFirst(pane.keyPrefix.count)))
            return
        }
        self = .search(text)
    }
}

extension BrowserModel.Pane {
    /// How the palette's keys and `PlayQuery` start an entry of this pane: the palette kind's
    /// `keyPrefix`, which this feature can't import, as a test in MusicPlayerTests holds.
    public var keyPrefix: String {
        switch self {
        case .genre: "genre:"
        case .artist: "artist:"
        case .album: "album:"
        }
    }
}

/// Why a `PlayQuery` plays nothing.
enum PlayQueryError: Error, Equatable, CustomStringConvertible {
    case nothingMatches(PlayQuery)
    case noEntry(BrowserModel.Pane, String)
    /// Entries of one name, by these artists.
    case several(BrowserModel.Pane, String, artists: [String?])

    /// Artists named in `several` before the rest are counted.
    static let artistsListed = 5

    var description: String {
        switch self {
        case .nothingMatches(.search(let text)): "nothing in the library matches \(text)"
        case .nothingMatches(.entry(let pane, let name)), .noEntry(let pane, let name):
            "no \(pane.title.lowercased()) in the library is named \(name)"
        case .several(let pane, let name, let artists):
            "\(artists.count) \(pane.title.lowercased())s are named \(name), by "
                + artistList(artists) + "; play a search of the name and the artist instead"
        }
    }

    private func artistList(_ artists: [String?]) -> String {
        let names = artists.map { $0 ?? "no artist" }
        let listed = names.prefix(Self.artistsListed).joined(separator: ", ")
        let more = names.count - Self.artistsListed
        return more > 0 ? "\(listed) and \(more) more" : listed
    }
}
