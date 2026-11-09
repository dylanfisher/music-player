import Library

/// The library album a download queued as a new album would replace (ADR 0169).
package enum ReplacedAlbum: Equatable, Sendable {
    /// No album of the library is the release's.
    case none
    /// The one album that is, found by its tracks' release id, else by `byName`, its album
    /// artist and title.
    case album(DiscogsAlbum, byName: Bool)
    /// `count` albums are, so none is chosen.
    case several(count: Int, byName: Bool)
}

/// The album of `albums` a download of the release `release`, `artist` - `title` as the service
/// names it, replaces: the one whose every track carries the release id, else the one whose
/// album artist and title fold as the release's do, by the key the matcher compares by but
/// keeping edition words: a deluxe edition is not the album it extends, and a match sends the
/// old files to the Trash.
package func libraryAlbum(
    replacedBy release: Int, artist: String, title: String, among albums: [DiscogsAlbum]
) -> ReplacedAlbum {
    let id = String(release)
    let tagged = albums.filter { album in
        !album.tracks.isEmpty && album.tracks.allSatisfy { $0.releaseID == id }
    }
    if let found = chosen(tagged, byName: false) { return found }
    let artistKey = CatalogKey.matchKey(artist)
    let titleKey = CatalogKey.matchKey(title)
    guard !artistKey.isEmpty, !titleKey.isEmpty else { return .none }
    let named = albums.filter { album in
        CatalogKey.matchKey(album.title) == titleKey
            && album.artist.map { CatalogKey.matchKey($0) } == artistKey
    }
    return chosen(named, byName: true) ?? .none
}

private func chosen(_ albums: [DiscogsAlbum], byName: Bool) -> ReplacedAlbum? {
    switch albums.count {
    case 0: nil
    case 1: .album(albums[0], byName: byName)
    default: .several(count: albums.count, byName: byName)
    }
}
