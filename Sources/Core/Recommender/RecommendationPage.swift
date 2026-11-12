import StrictKeys

/// A page of one of the service's lists, of albums the library doesn't have or of their
/// artists (`docs/api.md` there, section Recommendations). Every field is always there, an
/// absent value `null`; a value of a kind or status this player doesn't know fails the reply,
/// naming the field, so it is shown rather than skipped.
struct RecommendationPage: Equatable, Sendable, Decodable {
    /// What the list was scored from.
    struct Facts: Equatable, Sendable, Decodable {
        /// The dumps' set, `YYYYMMDD`.
        var catalogSet: String
        var computedAt: Int
        /// The profile's albums it was scored from.
        var seeds: Int
        /// The albums it holds before the filters and the caps.
        var candidates: Int

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case catalogSet = "catalog_set"
            case computedAt = "computed_at"
            case seeds, candidates
        }
    }

    /// An artist, label or style by id and name, the name nil when the catalog has none.
    struct Named: Equatable, Hashable, Sendable, Decodable {
        var id: Int
        var name: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, name
        }
    }

    /// A connection of the album to the library. The fields its `kind` doesn't use are nil or
    /// empty.
    struct Reason: Equatable, Sendable, Decodable {
        enum Kind: String, Equatable, Sendable, Decodable {
            case artist, credit, label, related, styles
        }

        enum Relation: String, Equatable, Sendable, Decodable {
            case alias, member, group
        }

        var kind: Kind
        /// For showing, not for parsing.
        var words: String
        var weight: Double
        var artist: Named?
        var role: String?
        var seedRoles: [String]
        var label: Named?
        var via: Named?
        var relation: Relation?
        var of: Named?
        var albums: Int?
        var styles: [Named]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case kind, words, weight, artist, role
            case seedRoles = "seed_roles"
            case label, via, relation, of, albums, styles
        }
    }

    struct Album: Equatable, Sendable, Decodable {
        /// `master` and its master id, or `release` and its id for a release without a master:
        /// what a mark takes.
        var kind: AlbumKind
        var id: Int
        /// The release that stands for the album, whose community values these are; nil when
        /// the catalog has no row for the master.
        var releaseID: Int?
        /// Its place in the whole list by score, before the filters and the caps.
        var rank: Int
        var score: Double
        var artists: [Named]
        var title: String
        var year: Int?
        var label: Named?
        var styles: [Named]
        var community: CommunityValues?
        /// Up to 3, strongest first.
        var reasons: [Reason]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case kind, id
            case releaseID = "release_id"
            case rank, score, artists, title, year, label, styles, community, reasons
        }
    }

    struct Artist: Equatable, Sendable, Decodable {
        var rank: Int
        var id: Int
        var name: String?
        var score: Double
        /// The albums its score counts, 1 to 3.
        var albums: Int
        var best: Album

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case rank, id, name, score, albums, best
        }
    }

    var list: Facts
    /// With `show: albums`; nil with artists.
    var albums: [Album]?
    /// With `show: artists`; nil with albums.
    var artists: [Artist]?
    /// Whether the list goes on past this page.
    var more: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, list, albums, artists, more
    }
}

extension RecommendationPage {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        list = try container.decode(Facts.self, forKey: .list)
        albums = try container.decode([Album]?.self, forKey: .albums)
        artists = try container.decode([Artist]?.self, forKey: .artists)
        more = try container.decode(Bool.self, forKey: .more)
    }
}

extension RecommendationPage.Facts {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        catalogSet = try container.decode(String.self, forKey: .catalogSet)
        computedAt = try container.decode(Int.self, forKey: .computedAt)
        seeds = try container.decode(Int.self, forKey: .seeds)
        candidates = try container.decode(Int.self, forKey: .candidates)
    }
}

extension RecommendationPage.Named {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String?.self, forKey: .name)
    }
}

extension RecommendationPage.Reason {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        words = try container.decode(String.self, forKey: .words)
        weight = try container.decode(Double.self, forKey: .weight)
        artist = try container.decode(RecommendationPage.Named?.self, forKey: .artist)
        role = try container.decode(String?.self, forKey: .role)
        seedRoles = try container.decode([String].self, forKey: .seedRoles)
        label = try container.decode(RecommendationPage.Named?.self, forKey: .label)
        via = try container.decode(RecommendationPage.Named?.self, forKey: .via)
        relation = try container.decode(Relation?.self, forKey: .relation)
        of = try container.decode(RecommendationPage.Named?.self, forKey: .of)
        albums = try container.decode(Int?.self, forKey: .albums)
        styles = try container.decode([RecommendationPage.Named].self, forKey: .styles)
    }
}

extension RecommendationPage.Album {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        kind = try container.decode(AlbumKind.self, forKey: .kind)
        id = try container.decode(Int.self, forKey: .id)
        releaseID = try container.decode(Int?.self, forKey: .releaseID)
        rank = try container.decode(Int.self, forKey: .rank)
        score = try container.decode(Double.self, forKey: .score)
        artists = try container.decode([RecommendationPage.Named].self, forKey: .artists)
        title = try container.decode(String.self, forKey: .title)
        year = try container.decode(Int?.self, forKey: .year)
        label = try container.decode(RecommendationPage.Named?.self, forKey: .label)
        styles = try container.decode([RecommendationPage.Named].self, forKey: .styles)
        community = try container.decode(CommunityValues?.self, forKey: .community)
        reasons = try container.decode([RecommendationPage.Reason].self, forKey: .reasons)
    }
}

extension RecommendationPage.Artist {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        rank = try container.decode(Int.self, forKey: .rank)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String?.self, forKey: .name)
        score = try container.decode(Double.self, forKey: .score)
        albums = try container.decode(Int.self, forKey: .albums)
        best = try container.decode(RecommendationPage.Album.self, forKey: .best)
    }
}
