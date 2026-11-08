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

    /// A row's kind by its shape, as the dumps and the API both have to be read: one with
    /// sub-tracks is an index track, one with no position and no duration a heading.
    static func kind(position: String?, durationSeconds: Int?, hasSubTracks: Bool) -> Kind {
        hasSubTracks ? .index : position == nil && durationSeconds == nil ? .heading : .track
    }

    /// Seconds in a Discogs duration, "4:45" or "1:02:03"; nil for an empty or unreadable
    /// one, including one too long for an `Int`, which the real dump has.
    static func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard let value = Int(part.trimmingCharacters(in: .whitespaces)), value >= 0 else {
                return nil
            }
            let (minutes, overflowed) = total.multipliedReportingOverflow(by: 60)
            let (sum, sumOverflowed) = minutes.addingReportingOverflow(value)
            guard !overflowed, !sumOverflowed else { return nil }
            total = sum
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
