/// An artist as a release, master or track credits it.
struct CatalogArtistCredit: Equatable, Sendable {
    /// Nil for a name Discogs doesn't link to an artist.
    var id: Int?
    /// The artist's name on Discogs, with any `(2)` suffix.
    var name: String
    /// The name as this release prints it, when it differs (an artist name variation).
    var nameVariation: String?
    /// What joins this artist to the next, such as "&" or "Feat.".
    var join: String?

    init(id: Int?, name: String, nameVariation: String? = nil, join: String? = nil) {
        self.id = id
        self.name = name
        self.nameVariation = nameVariation
        self.join = join
    }
}

extension CatalogArtistCredit: Codable {
    /// One letter each, since the catalog stores a few hundred million of them.
    private enum CodingKeys: String, CodingKey {
        case id = "i"
        case name = "n"
        case nameVariation = "v"
        case join = "j"
    }
}
