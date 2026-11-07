/// Whether an album's tracks carry a Discogs release id (ADR 0129). The Discogs window lists
/// matched albums apart and shows the incomplete ones with its Incomplete tier.
enum DiscogsMatch: Equatable, Sendable {
    /// Every track has this release id.
    case matched(releaseID: String)
    /// Some tracks have no release id, or the tracks have different ones.
    case incomplete
    /// No track has a release id.
    case unmatched
}

extension LibraryIndex {
    /// Each album's match, by album ID. Tracks without an album aren't in an album to match.
    func discogsMatches() throws -> [Int64: DiscogsMatch] {
        let rows = try database.prepare(
            """
            SELECT album_id, count(*), count(discogs_release_id),
                count(DISTINCT discogs_release_id), min(discogs_release_id)
            FROM tracks WHERE album_id IS NOT NULL GROUP BY album_id
            """
        ).map { row in
            let tracks = try row.int(1)
            let withID = try row.int(2)
            let distinct = try row.int(3)
            let match: DiscogsMatch
            if withID == 0 {
                match = .unmatched
            } else if withID == tracks, distinct == 1 {
                match = .matched(releaseID: try row.text(4))
            } else {
                match = .incomplete
            }
            return (try row.int64(0), match)
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }
}
