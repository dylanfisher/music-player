import Settings

extension LibraryIndex {
    /// Lists Rediscover's `albums`, best first, for the `.rediscover` source on this
    /// connection, and answers the ids of those the index has no album of that title under:
    /// keys from a profile another Mac sent, or from before a rebuild numbered the albums
    /// again (ADR 0206). Only the others are listed.
    public func showRediscover(_ albums: [(id: Int64, title: String)]) throws -> [Int64] {
        try show(albums, as: \.rediscoverAlbums)
    }

    /// Lists those of Threads' `albums` in `listing`, in order, for the `.threads` source on
    /// this connection, and answers which of all of them the index lacks, as `showRediscover`
    /// does (ADR 0208). The filters (ADR 0209) list fewer than the reply holds.
    public func showThreads(_ albums: [(id: Int64, title: String)], listing: Set<Int64>) throws
        -> [Int64]
    {
        try show(albums, as: \.threadsAlbums, listing: listing)
    }

    private func show(
        _ albums: [(id: Int64, title: String)],
        as listed: ReferenceWritableKeyPath<LibraryIndex, [Int64]>, listing: Set<Int64>? = nil
    ) throws -> [Int64] {
        let titles = Dictionary(
            try statement(
                "SELECT id, title FROM albums WHERE id IN (\(sqlList(albums.map(\.id))))"
            ).map { (try $0.int64(0), try $0.text(1)) }, uniquingKeysWith: { first, _ in first })
        let known = albums.filter { titles[$0.id] == $0.title }.map(\.id)
        self[keyPath: listed] = listing.map { listing in known.filter(listing.contains) } ?? known
        return albums.map(\.id).filter { !known.contains($0) }
    }

    /// The albums `source` lists, in order, when it lists albums the window was told of:
    /// Rediscover's and Threads'.
    func listedAlbums(_ source: BrowserSource?) -> [Int64]? {
        switch source {
        case .rediscover: rediscoverAlbums
        case .threads: threadsAlbums
        case .playlist, .history, .timeline, .health, .plays, .stats, nil: nil
        }
    }

    /// Each of `albums` with its place, as `album_id` and `position`, for the track table's
    /// Order. The ids are the index's own integers, so they go in the SQL as text, as one
    /// `VALUES` list: a `UNION ALL` of more than 500 selects is more than SQLite takes.
    func albumOrderSQL(_ albums: [Int64]) -> String {
        guard !albums.isEmpty else { return "SELECT NULL AS album_id, NULL AS position" }
        let rows = albums.enumerated().map { place, id in "(\(id), \(place))" }
        return "SELECT column1 AS album_id, column2 AS position FROM (VALUES "
            + rows.joined(separator: ", ") + ")"
    }
}

/// `ids` as the list of an SQL `IN`, which may be empty.
func sqlList(_ ids: [Int64]) -> String {
    ids.map(String.init).joined(separator: ", ")
}
