/// Which of the service's lists to read, how, and through which filters: everything a request
/// to `/v1/recommendations` says but the page.
package struct RecommendationQuery: Equatable, Hashable, Sendable {
    /// Discogs's Various Artists, whose discography the service refuses: its albums would be
    /// every compilation in the catalog.
    package static let variousArtistsID = 194

    /// The list: the whole library's, one seed's, or one Discogs artist's discography.
    package enum Seed: Equatable, Hashable, Sendable {
        case library
        /// The seed album, by the Discogs release it is tagged with.
        case album(releaseID: Int, title: String)
        /// The seed albums of one album artist, by the name the profile sends.
        case artist(String)
        /// Every album the Discogs artist is a main artist on, not scored (ADR 0217). `name`
        /// is for the pop-up only; the service is asked by id.
        case discography(artistID: Int, name: String)

        var isDiscography: Bool {
            if case .discography = self { true } else { false }
        }

        /// The order the service gives when none is sent.
        package var defaultSort: Sort { isDiscography ? .year : .score }
    }

    package enum Show: String, Equatable, Hashable, Sendable {
        case albums, artists
    }

    /// The albums' filters, together keeping what each keeps. None is sent with `artists`.
    package struct Filters: Equatable, Hashable, Sendable {
        /// Only albums by an artist of the list's albums.
        package var missing = false
        /// Discogs style names; any of them keeps an album.
        package var styles: [String] = []
        package var yearFrom: Int? = nil
        package var yearTo: Int? = nil
        package var labels: [RecommendationPage.Named] = []

        package init() {}
    }

    /// The albums' order: for a scored list by score, or by a community value, highest
    /// first, among the first 300 albums by score; for a discography by year, title or a
    /// community value over every album. Not sent with `artists`, nor when it is the seed's
    /// default.
    package enum Sort: String, CaseIterable, Equatable, Hashable, Sendable {
        case score, year, title, rating, have, want
        case wantHave = "want_have"

        /// The orders the service takes for `seed`'s list: `year` and `title` only for a
        /// discography, `score` for every other.
        package static func offered(for seed: Seed) -> [Sort] {
            allCases.filter {
                switch $0 {
                case .score: !seed.isDiscography
                case .year, .title: seed.isDiscography
                case .rating, .have, .want, .wantHave: true
                }
            }
        }
    }

    package var seed: Seed
    package var show: Show
    package var filters: Filters
    package var sort: Sort

    package init(
        seed: Seed = .library, show: Show = .albums, filters: Filters = Filters(),
        sort: Sort = .score
    ) {
        self.seed = seed
        self.show = show
        self.filters = filters
        self.sort = sort
    }

    /// The query as the service takes it for its seed: a discography shows albums only, and
    /// an order the seed's list doesn't offer becomes its default.
    package var fitted: RecommendationQuery {
        var fitted = self
        if seed.isDiscography { fitted.show = .albums }
        if !Sort.offered(for: seed).contains(sort) { fitted.sort = seed.defaultSort }
        return fitted
    }
}

/// The body of `/v1/recommendations`. The service refuses an unknown field, a filter or `sort`
/// with `show: artists`, and `missing` with a discography, so an unset one is left out rather
/// than sent as `null`.
struct RecommendationRequest: Encodable {
    var query: RecommendationQuery
    var offset: Int
    var limit: Int

    /// The values of `list`.
    private enum List: String, Encodable {
        case library, album, artist, discography
    }

    private enum CodingKeys: String, CodingKey {
        case list
        case releaseID = "release_id"
        case artist
        case artistID = "artist_id"
        case show, offset, limit, missing, styles
        case yearFrom = "year_from"
        case yearTo = "year_to"
        case labelIDs = "label_ids"
        case sort
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch query.seed {
        case .library: try container.encode(List.library, forKey: .list)
        case .album(let releaseID, _):
            try container.encode(List.album, forKey: .list)
            try container.encode(releaseID, forKey: .releaseID)
        case .artist(let name):
            try container.encode(List.artist, forKey: .list)
            try container.encode(name, forKey: .artist)
        case .discography(let artistID, _):
            try container.encode(List.discography, forKey: .list)
            try container.encode(artistID, forKey: .artistID)
        }
        try container.encode(query.show.rawValue, forKey: .show)
        try container.encode(offset, forKey: .offset)
        try container.encode(limit, forKey: .limit)
        guard query.show == .albums else { return }
        let filters = query.filters
        // A discography lists every album, so its Missing filters the rows read (ADR 0217).
        if filters.missing, !query.seed.isDiscography {
            try container.encode(true, forKey: .missing)
        }
        if !filters.styles.isEmpty { try container.encode(filters.styles, forKey: .styles) }
        try container.encodeIfPresent(filters.yearFrom, forKey: .yearFrom)
        try container.encodeIfPresent(filters.yearTo, forKey: .yearTo)
        if !filters.labels.isEmpty {
            try container.encode(filters.labels.map(\.id), forKey: .labelIDs)
        }
        if query.sort != query.seed.defaultSort {
            try container.encode(query.sort.rawValue, forKey: .sort)
        }
    }
}
