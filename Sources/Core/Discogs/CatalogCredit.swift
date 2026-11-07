/// A credit for a role on a release or a track, such as "Producer" or "Mastered By".
struct CatalogCredit: Equatable, Sendable {
    /// Nil for a name Discogs doesn't link to an artist.
    var id: Int?
    var name: String
    /// The name as this release prints it, when it differs.
    var nameVariation: String?
    /// As Discogs writes it: "Written-By [All Tracks By]", "Producer, Recorded By".
    var role: String
    /// The tracks a release-level credit covers, as Discogs writes them: "A1 to B2, C1".
    var tracks: String?

    init(
        id: Int?, name: String, nameVariation: String? = nil, role: String, tracks: String? = nil
    ) {
        self.id = id
        self.name = name
        self.nameVariation = nameVariation
        self.role = role
        self.tracks = tracks
    }
}

extension CatalogCredit: Codable {
    /// One letter each, as `CatalogArtistCredit`'s.
    private enum CodingKeys: String, CodingKey {
        case id = "i"
        case name = "n"
        case nameVariation = "v"
        case role = "r"
        case tracks = "t"
    }
}
