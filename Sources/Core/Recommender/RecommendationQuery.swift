/// Which of the service's lists to read, how, and through which filters: everything a request
/// to `/v1/recommendations` says but the page.
package struct RecommendationQuery: Equatable, Hashable, Sendable {
    /// The list: the whole library's, or one seed's.
    package enum Seed: Equatable, Hashable, Sendable {
        case library
        /// The seed album, by the Discogs release it is tagged with.
        case album(releaseID: Int, title: String)
        /// The seed albums of one album artist, by the name the profile sends.
        case artist(String)
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

    package var seed: Seed
    package var show: Show
    package var filters: Filters

    package init(seed: Seed = .library, show: Show = .albums, filters: Filters = Filters()) {
        self.seed = seed
        self.show = show
        self.filters = filters
    }
}

/// The body of `/v1/recommendations`. The service refuses an unknown field and a filter with
/// `show: artists`, so an unset one is left out rather than sent as `null`.
struct RecommendationRequest: Encodable {
    var query: RecommendationQuery
    var offset: Int
    var limit: Int

    /// The values of `list`.
    private enum List: String, Encodable {
        case library, album, artist
    }

    private enum CodingKeys: String, CodingKey {
        case list
        case releaseID = "release_id"
        case artist, show, offset, limit, missing, styles
        case yearFrom = "year_from"
        case yearTo = "year_to"
        case labelIDs = "label_ids"
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
        }
        try container.encode(query.show.rawValue, forKey: .show)
        try container.encode(offset, forKey: .offset)
        try container.encode(limit, forKey: .limit)
        guard query.show == .albums else { return }
        let filters = query.filters
        if filters.missing { try container.encode(true, forKey: .missing) }
        if !filters.styles.isEmpty { try container.encode(filters.styles, forKey: .styles) }
        try container.encodeIfPresent(filters.yearFrom, forKey: .yearFrom)
        try container.encodeIfPresent(filters.yearTo, forKey: .yearTo)
        if !filters.labels.isEmpty {
            try container.encode(filters.labels.map(\.id), forKey: .labelIDs)
        }
    }
}
