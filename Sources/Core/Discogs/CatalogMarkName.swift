import Recommender
import Settings

extension Catalog {
    /// "Artist – Title" of the master or release a mark is on, as the Recommendations window's
    /// Marked sheet names it; nil when this catalog doesn't have it.
    package func markName(_ kind: AlbumKind, _ id: Int) throws -> String? {
        let artists: [CatalogArtistCredit]
        let title: String
        switch kind {
        case .release:
            guard let release = try release(id: id) else { return nil }
            (artists, title) = (release.artists, release.title)
        case .master:
            guard let master = try master(id: id) else { return nil }
            (artists, title) = (master.artists, master.title)
        }
        let artist =
            MappedValue.artists(artists).text(
                DiscogsFieldFormat(suffixes: .drop), tagFormat: .vorbis) ?? ""
        return artist.isEmpty ? title : "\(artist) – \(title)"
    }
}
