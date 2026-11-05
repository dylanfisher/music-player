import Foundation
import SQLite
import Settings

// Listening Stats' reads (ADR 0102). Nothing indexes `played_at`, so a period is a scan of the
// table; SQLite would otherwise walk `history_path` and look up every row, ten times slower.

extension LibraryIndex {
    /// The plays of `span`, nil for All Time, per path and per bucket of `bucketSeconds`, with
    /// what the index knows of each path. Artists are the Artists column's, as
    /// `groupByAlbumArtist` groups them.
    func periodScan(_ span: PlaySpan?, groupByAlbumArtist: Bool, bucketSeconds: Int64) throws
        -> PeriodScan
    {
        // The whole table's plays per path read the covering `history_path` in order.
        let plays =
            span == nil
            ? "SELECT path_id, count(*) AS n FROM history GROUP BY path_id"
            : "SELECT path_id, count(*) AS n FROM history NOT INDEXED"
                + " WHERE played_at >= ?1 AND played_at < ?2 GROUP BY path_id"
        let artist = groupByAlbumArtist ? "group_artist_id" : "artist_id"
        let bounds: [(any SQLiteValue)?] = span.map { [$0.start, $0.end] } ?? []
        let paths = try statement(
            """
            SELECT c.path_id, c.n, t.file_id IS NOT NULL, t.\(artist), t.album_id, t.genre_id,
                ifnull(t.length_frames, p.length_frames), ifnull(t.sample_rate_hz, p.sample_rate_hz),
                ifnull(t.codec, p.codec)
            FROM (\(plays)) c JOIN paths p ON p.id = c.path_id
            LEFT JOIN tracks t ON t.file_id = c.path_id
            """
        ).map(binding: bounds) { row in
            let frames = row.optionalInt(6)
            let rate = row.optionalInt(7)
            return PeriodScan.Path(
                id: try row.int64(0), plays: try row.int(1), inLibrary: try row.int(2) == 1,
                artistID: row.optionalInt(3).map(Int64.init),
                albumID: row.optionalInt(4).map(Int64.init),
                genreID: row.optionalInt(5).map(Int64.init),
                seconds: frames.flatMap { frames in
                    rate.flatMap { $0 > 0 ? Double(frames) / Double($0) : nil }
                },
                codec: row.optionalText(8), sampleRateHz: rate)
        }
        let within = span == nil ? "" : " WHERE played_at >= ?1 AND played_at < ?2"
        let bucketValues: [(any SQLiteValue)?] = [span?.start, span?.end, bucketSeconds]
        let buckets = try statement(
            "SELECT played_at / ?3 * ?3, count(*) FROM history NOT INDEXED\(within)"
                + " GROUP BY 1 ORDER BY 1"
        ).map(binding: bucketValues) {
            PeriodScan.Bucket(start: try $0.int64(0), plays: try $0.int(1))
        }
        let libraryTracks = try statement("SELECT count(*) FROM tracks").map { try $0.int(0) }[0]
        var undated = 0
        if span == nil {
            let counted = try statement("SELECT ifnull(sum(play_count), 0) FROM plays").map {
                try $0.int(0)
            }[0]
            undated = max(0, counted - paths.reduce(0) { $0 + $1.plays })
        }
        return PeriodScan(
            span: span, paths: paths, buckets: buckets, bucketSeconds: bucketSeconds,
            libraryTracks: libraryTracks, undatedPlays: undated)
    }

    /// When each album and artist still in the library was first played, and the first play of
    /// all, from every history row: one scan of the whole table.
    func firstPlays(groupByAlbumArtist: Bool) throws -> FirstPlays {
        let artist = groupByAlbumArtist ? "group_artist_id" : "artist_id"
        var first = FirstPlays()
        try statement(
            """
            SELECT t.album_id, t.\(artist), f.played
            FROM (SELECT path_id, min(played_at) AS played FROM history NOT INDEXED
                GROUP BY path_id) f
            LEFT JOIN tracks t ON t.file_id = f.path_id
            """
        ).query { row in
            let played = try row.int64(2)
            first.earliest = min(first.earliest ?? .max, played)
            if let album = row.optionalInt(0).map(Int64.init) {
                first.albums[album] = min(first.albums[album] ?? .max, played)
            }
            if let artist = row.optionalInt(1).map(Int64.init) {
                first.artists[artist] = min(first.artists[artist] ?? .max, played)
            }
        }
        return first
    }

    /// The names of `ids`, by the list that shows them: an artist's or genre's name, an album's
    /// title and artist, a track's title (or a missing one's file name) and artist.
    func statsNames(_ ids: [StatsReport.List: Set<Int64>]) throws
        -> [StatsReport.List: [Int64: StatsName]]
    {
        var names: [StatsReport.List: [Int64: StatsName]] = [:]
        for (list, ids) in ids {
            let sql: (String) -> String =
                switch list {
                case .artists: { "SELECT id, name, NULL, NULL FROM artists WHERE id IN (\($0))" }
                case .genres: { "SELECT id, name, NULL, NULL FROM genres WHERE id IN (\($0))" }
                case .albums: {
                    """
                    SELECT al.id, al.title, ar.name, NULL FROM albums al
                    LEFT JOIN artists ar ON ar.id = al.artist_id WHERE al.id IN (\($0))
                    """
                }
                case .tracks: {
                    """
                    SELECT p.id, t.title, ar.name, p.path FROM paths p
                    LEFT JOIN tracks t ON t.file_id = p.id
                    LEFT JOIN artists ar ON ar.id = t.artist_id WHERE p.id IN (\($0))
                    """
                }
                }
            let rows = try inChunks(Array(ids).sorted(), sql) { row in
                (
                    try row.int64(0),
                    StatsName(
                        name: row.optionalText(1) ?? row.optionalText(3).map(displayName) ?? "",
                        detail: row.optionalText(2))
                )
            }
            names[list] = Dictionary(rows, uniquingKeysWith: { first, _ in first })
        }
        return names
    }

    /// SQLite's count of changes other connections committed, which tells a cached read it's
    /// out of date.
    func dataVersion() throws -> Int {
        try statement("PRAGMA data_version").map { try $0.int(0) }[0]
    }
}

/// How long a bucket of plays is in `zone` around `span`: an hour, unless one of the zone's
/// offsets there isn't whole hours, as India's isn't, when it's a quarter hour.
func bucketSeconds(in zone: TimeZone, around span: PlaySpan?, now: Date) -> Int64 {
    let halfYear = 183.0 * 86_400
    let times =
        (span.map { [TimeInterval($0.start), TimeInterval($0.end - 1)] } ?? [])
        + [now.timeIntervalSince1970]
    let dates = times.flatMap { [$0, $0 + halfYear].map(Date.init(timeIntervalSince1970:)) }
    return dates.allSatisfy { zone.secondsFromGMT(for: $0) % 3600 == 0 } ? 3600 : 900
}
