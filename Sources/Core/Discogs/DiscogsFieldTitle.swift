import Library
import Settings

extension DiscogsField {
    /// As the Field Mapping and View Changes sheets name it, after YATE's Release screen: the
    /// track table's column's title where the two are the same tag. Get Info's Discogs tab
    /// names a release's facts by it too.
    public var title: String {
        switch self {
        case .releaseID: "Release ID"
        case .masterID: "Master ID"
        case .releaseURL: "Release URL"
        case .masterURL: "Master URL"
        case .album: TrackColumn.album.title
        case .albumArtist: TrackColumn.albumArtist.title
        case .albumArtistURL: "Album Artist URLs"
        case .label: "Labels"
        case .labelURL: "Label URLs"
        case .catalogNumber: TrackColumn.catalogNumber.title
        case .labelCatalogNumbers: "Labels' Catalog Numbers"
        case .barcode: TrackColumn.barcode.title
        case .country: "Release Country"
        case .date: "Released"
        case .genres: "Genres"
        case .styles: "Styles"
        case .media: "Release Formats"
        case .compilation: TrackColumn.compilation.title
        case .discCount: TrackColumn.discTotal.title
        case .title: TrackColumn.title.title
        case .artist: TrackColumn.artist.title
        case .artistList: "Artist List"
        case .artistNameVariations: "Name Variations"
        case .artistURL: "Artist URLs"
        case .trackNumber: TrackColumn.trackNumber.title
        case .trackCount: TrackColumn.trackTotal.title
        case .discNumber: TrackColumn.discNumber.title
        case .position: "Track Position"
        case .ordinalPosition: "Ordinal Position"
        case .discSubtitle: TrackColumn.discSubtitle.title
        case .composer: TrackColumn.composer.title
        case .conductor: TrackColumn.conductor.title
        case .lyricist: TrackColumn.lyricist.title
        case .remixer: "Remixers"
        case .producer: "Producers"
        case .involvedPeople: "Involved People"
        }
    }
}
