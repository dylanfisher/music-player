import Settings

/// What two scans of `history` read for a period, before `StatsReport` adds it up (ADR 0102).
struct PeriodScan: Equatable, Sendable {
    /// One path played in the period, with what the index knows of it.
    struct Path: Equatable, Sendable {
        var id: Int64
        var plays: Int
        /// False when the path's file is no longer in the index, or was removed.
        var inLibrary: Bool
        /// The Artists column's artist, as the browser groups it (`artistColumn`).
        var artistID: Int64?
        var albumID: Int64?
        var genreID: Int64?
        /// The track's length, or the last one read of a path no longer in the library; nil
        /// when it was never read.
        var seconds: Double?
        var codec: String?
        var sampleRateHz: Int?
    }

    /// The plays in `bucketSeconds` from `start`, in seconds since 1970.
    struct Bucket: Equatable, Sendable {
        var start: Int64
        var plays: Int
    }

    var span: PlaySpan?
    var paths: [Path]
    /// In time order.
    var buckets: [Bucket]
    var bucketSeconds: Int64
    var libraryTracks: Int
    /// Plays counted in `plays` with no history row, such as an import's (ADR 0033); only
    /// read for All Time, the one period they can be in.
    var undatedPlays: Int
}

/// When each album and artist was first played, from every play with a date: what "first played
/// in the period" is measured against. By the Artists column's artist, as `PeriodScan`'s.
struct FirstPlays: Equatable, Sendable {
    var albums: [Int64: Int64] = [:]
    var artists: [Int64: Int64] = [:]
    /// The first play with a date of any path, in the library or not.
    var earliest: Int64?
}
