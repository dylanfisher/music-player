import StrictKeys

/// A page of one of the service's lists, of albums the library doesn't have or of their
/// artists (`docs/api.md` there, section Recommendations). Every field is always there, an
/// absent value `null`; a value of a kind or status this player doesn't know fails the reply,
/// naming the field, so it is shown rather than skipped.
package struct RecommendationPage: Equatable, Sendable, Decodable {
    /// What the list was scored from.
    package struct Facts: Equatable, Sendable, Decodable {
        /// The dumps' set, `YYYYMMDD`.
        package var catalogSet: String
        package var computedAt: Int
        /// The profile's albums it was scored from.
        package var seeds: Int
        /// The albums it holds before the filters and the caps.
        package var candidates: Int

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case catalogSet = "catalog_set"
            case computedAt = "computed_at"
            case seeds, candidates
        }
    }

    /// An artist, label or style by id and name, the name nil when the catalog has none.
    package struct Named: Equatable, Hashable, Sendable, Decodable {
        package var id: Int
        package var name: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, name
        }
    }

    /// A connection of the album to the library. The fields its `kind` doesn't use are nil or
    /// empty.
    package struct Reason: Equatable, Sendable, Decodable {
        package enum Kind: String, Equatable, Sendable, Decodable {
            case artist, credit, label, related, styles
        }

        enum Relation: String, Equatable, Sendable, Decodable {
            case alias, member, group
        }

        package var kind: Kind
        /// For showing, not for parsing.
        package var words: String
        package var weight: Double
        package var artist: Named?
        package var role: String?
        var seedRoles: [String]
        package var label: Named?
        var via: Named?
        var relation: Relation?
        package var of: Named?
        package var albums: Int?
        package var styles: [Named]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case kind, words, weight, artist, role
            case seedRoles = "seed_roles"
            case label, via, relation, of, albums, styles
        }
    }

    package struct Album: Equatable, Sendable, Decodable {
        /// `master` and its master id, or `release` and its id for a release without a master:
        /// what a mark takes.
        package var kind: AlbumKind
        package var id: Int
        /// The release that stands for the album, whose community values these are; nil when
        /// the catalog has no row for the master.
        package var releaseID: Int?
        /// Its place in the whole list by score, before the filters and the caps.
        package var rank: Int
        package var score: Double
        package var artists: [Named]
        package var title: String
        package var year: Int?
        package var label: Named?
        package var styles: [Named]
        package var community: CommunityValues?
        /// Up to 3, strongest first.
        package var reasons: [Reason]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case kind, id
            case releaseID = "release_id"
            case rank, score, artists, title, year, label, styles, community, reasons
        }
    }

    package struct Artist: Equatable, Sendable, Decodable {
        package var rank: Int
        package var id: Int
        package var name: String?
        package var score: Double
        /// The albums its score counts, 1 to 3.
        package var albums: Int
        package var best: Album

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case rank, id, name, score, albums, best
        }
    }

    package var list: Facts
    /// With `show: albums`; nil with artists.
    package var albums: [Album]?
    /// With `show: artists`; nil with albums.
    package var artists: [Artist]?
    /// Whether the list goes on past this page.
    package var more: Bool

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
