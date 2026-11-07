/// A release as the catalog keeps it (ADR 0130): what the matcher compares and the mapping
/// writes, and nothing else of the dump's.
struct CatalogRelease: Equatable, Sendable {
    struct Label: Equatable, Sendable, Codable {
        /// Nil for a label name Discogs doesn't link.
        var id: Int?
        var name: String
        /// As printed, such as "SK 026"; "none" where the release has none.
        var catalogNumber: String?
    }

    struct Format: Equatable, Sendable, Codable {
        /// "Vinyl", "CD", "File".
        var name: String
        var quantity: Int?
        /// Free text, such as "Gatefold".
        var text: String?
        /// "12\"", "Album", "Remastered".
        var descriptions: [String]
    }

    var id: Int
    var masterID: Int?
    /// Whether this is its master's main release.
    var isMainRelease: Bool
    var title: String
    var artists: [CatalogArtistCredit]
    var labels: [Label]
    var formats: [Format]
    var country: String?
    /// As Discogs writes it: "1999", "1999-03-00", "1999-03-15".
    var released: String?
    var genres: [String]
    var styles: [String]
    /// As printed, from the identifiers of type Barcode.
    var barcodes: [String]
    /// The release's credits (Discogs's extra artists), each with the tracks it covers.
    var credits: [CatalogCredit]
    var tracks: [CatalogTrack]

    init(
        id: Int, masterID: Int? = nil, isMainRelease: Bool = false, title: String,
        artists: [CatalogArtistCredit] = [], labels: [Label] = [], formats: [Format] = [],
        country: String? = nil, released: String? = nil, genres: [String] = [],
        styles: [String] = [], barcodes: [String] = [], credits: [CatalogCredit] = [],
        tracks: [CatalogTrack] = []
    ) {
        self.id = id
        self.masterID = masterID
        self.isMainRelease = isMainRelease
        self.title = title
        self.artists = artists
        self.labels = labels
        self.formats = formats
        self.country = country
        self.released = released
        self.genres = genres
        self.styles = styles
        self.barcodes = barcodes
        self.credits = credits
        self.tracks = tracks
    }
}

extension CatalogRelease {
    /// What the catalog keeps of a release beyond its row's columns, as one JSON object.
    struct Lists: Codable {
        var artists: [CatalogArtistCredit]
        var labels: [Label]
        var formats: [Format]
        var genres: [String]
        var styles: [String]
        var barcodes: [String]
        var credits: [CatalogCredit]
        var tracks: [CatalogTrack]
    }

    var lists: Lists {
        Lists(
            artists: artists, labels: labels, formats: formats, genres: genres, styles: styles,
            barcodes: barcodes, credits: credits, tracks: tracks)
    }
}
