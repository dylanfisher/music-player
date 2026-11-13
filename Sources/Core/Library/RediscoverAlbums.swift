extension LibraryIndex {
    /// Lists Rediscover's `albums`, best first, for the `.rediscover` source on this
    /// connection, and answers the ids of those the index has no album of that title under:
    /// keys from a profile another Mac sent, or from before a rebuild numbered the albums
    /// again (ADR 0206). Only the others are listed.
    public func showRediscover(_ albums: [(id: Int64, title: String)]) throws -> [Int64] {
        let titles = Dictionary(
            try statement(
                "SELECT id, title FROM albums WHERE id IN (\(sqlList(albums.map(\.id))))"
            ).map { (try $0.int64(0), try $0.text(1)) }, uniquingKeysWith: { first, _ in first })
        let known = albums.filter { titles[$0.id] == $0.title }.map(\.id)
        rediscoverAlbums = known
        return albums.map(\.id).filter { !known.contains($0) }
    }

    /// Each of Rediscover's albums with its place, as `album_id` and `position`, for the track
    /// table's Order. The ids are the index's own integers, so they go in the SQL as text.
    var rediscoverOrderSQL: String {
        guard !rediscoverAlbums.isEmpty else { return "SELECT NULL AS album_id, NULL AS position" }
        return rediscoverAlbums.enumerated().map { place, id in
            place == 0 ? "SELECT \(id) AS album_id, 0 AS position" : "SELECT \(id), \(place)"
        }.joined(separator: " UNION ALL ")
    }
}

/// `ids` as the list of an SQL `IN`, which may be empty.
func sqlList(_ ids: [Int64]) -> String {
    ids.map(String.init).joined(separator: ", ")
}
