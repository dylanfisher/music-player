/// A row of a release's tracklist: a track, a heading, or an index track whose sub-tracks are
/// the parts of one piece.
struct CatalogTrack: Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case track
        /// A title over the tracks that follow, such as a side's or a disc's name: no position
        /// and no duration.
        case heading
        /// A title over its sub-tracks, such as a suite's movements.
        case index
    }

    var kind: Kind
    /// As Discogs writes it: "A1", "3", "CD2-4", "11.a". Nil for a heading and most index
    /// tracks.
    var position: String?
    var title: String
    var durationSeconds: Int?
    var artists: [CatalogArtistCredit]
    var credits: [CatalogCredit]
    /// An index track's parts; empty for any other kind.
    var subTracks: [CatalogTrack]

    init(
        kind: Kind, position: String?, title: String, durationSeconds: Int? = nil,
        artists: [CatalogArtistCredit] = [], credits: [CatalogCredit] = [],
        subTracks: [CatalogTrack] = []
    ) {
        self.kind = kind
        self.position = position
        self.title = title
        self.durationSeconds = durationSeconds
        self.artists = artists
        self.credits = credits
        self.subTracks = subTracks
    }

    /// Seconds in a Discogs duration, "4:45" or "1:02:03"; nil for an empty or unreadable
    /// one.
    static func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard let value = Int(part.trimmingCharacters(in: .whitespaces)), value >= 0 else {
                return nil
            }
            total = total * 60 + value
        }
        return total
    }
}

extension CatalogTrack: Codable {
    /// One letter each, and a track's kind, empty lists and missing values left out, since
    /// the catalog stores a few hundred million tracks.
    private enum CodingKeys: String, CodingKey {
        case kind = "k"
        case position = "p"
        case title = "t"
        case durationSeconds = "d"
        case artists = "a"
        case credits = "c"
        case subTracks = "s"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .track
        position = try container.decodeIfPresent(String.self, forKey: .position)
        title = try container.decode(String.self, forKey: .title)
        durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
        artists = try container.decodeIfPresent([CatalogArtistCredit].self, forKey: .artists) ?? []
        credits = try container.decodeIfPresent([CatalogCredit].self, forKey: .credits) ?? []
        subTracks = try container.decodeIfPresent([CatalogTrack].self, forKey: .subTracks) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if kind != .track { try container.encode(kind, forKey: .kind) }
        try container.encodeIfPresent(position, forKey: .position)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        if !artists.isEmpty { try container.encode(artists, forKey: .artists) }
        if !credits.isEmpty { try container.encode(credits, forKey: .credits) }
        if !subTracks.isEmpty { try container.encode(subTracks, forKey: .subTracks) }
    }
}
