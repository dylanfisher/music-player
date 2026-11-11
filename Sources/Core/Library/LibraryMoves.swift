import DisplayText
import Metadata
import SQLite

extension LibraryIndex {
    /// Gives each gone path with stats to the stat-less track it matches, in one transaction,
    /// and returns the moves. Every such track is a candidate, not only those this scan added,
    /// since one folder's scan can find a file arrive before another's finds it leave. A pair
    /// matches when it's alone in sharing its codec (any lossless codec counting as one), sample
    /// rate and length in frames, or, where several share those, alone in sharing its path but
    /// for the extension, or its title; the rest wait in Lost Stats.
    func matchMoves() throws -> [TrackMove] {
        try database.transaction {
            let gone = try statement(movableSelect + " WHERE \(lostCondition)").map(row: movable)
            guard !gone.isEmpty else { return [] }
            let free = try statement(freeTracksSelect).map(row: movable)
            let roots = try syncRoots()
            return try movePairs(gone: gone, free: free).map { old, new in
                try move(old.id, to: new.id)
                try logMove(from: old.path, to: new.path, roots)
                return TrackMove(from: old.path, to: new.path)
            }
        }
    }

    /// Every lost path, by path, with the first `lostCandidatesListed` tracks it could have
    /// moved to. Grouped here rather than joined in SQL: a reorganize of files that share
    /// lengths would join every lost path with thousands of tracks.
    public func lostFiles() throws -> [LostFile] {
        let lost = try statement(movableSelect + " WHERE \(lostCondition) ORDER BY p.path, p.id")
            .map(row: movable)
        guard !lost.isEmpty else { return [] }
        let free = Dictionary(
            grouping: try statement(freeTracksSelect).map(row: movable), by: \.audio)
        return lost.map { path in
            let matching = free[path.audio] ?? []
            return LostFile(
                id: path.id, path: path.path,
                candidates: matching.prefix(lostCandidatesListed).map(\.id),
                matching: matching.count)
        }
    }

    /// Lost Stats: each lost path as a line, and the tracks it may have moved to.
    func lostStatsFindings() throws -> HealthFindings {
        let lost = try lostFiles()
        return HealthFindings(
            trackIDs: Set(lost.flatMap(\.candidates)).sorted(),
            others: lost.map { file in
                terminalSafe("\(file.path): matching tracks: \(file.matching)")
            }, otherIDs: lost.map(\.id))
    }

    /// Gives the stats of the lost path `lost` to the track `track`, which has none of its own,
    /// as the user picked in Lost Stats. False, changing nothing, when a scan or another pick
    /// since the list was read made the path no longer lost or gave the track stats.
    public func moveStats(from lost: Int64, to track: Int64) throws -> Bool {
        try database.transaction {
            let isLost =
                try statement("SELECT 1 FROM paths p WHERE p.id = ? AND \(lostCondition)")
                .map(lost) { _ in true }.first ?? false
            let isFree =
                try statement(
                    "SELECT 1 FROM tracks WHERE file_id = ? AND NOT \(hasStats("file_id"))"
                ).map(track) { _ in true }.first ?? false
            guard isLost, isFree else { return false }
            let paths = try [lost, track].map {
                try statement(pathSQL).map($0) { try $0.text(0) }[0]
            }
            try move(lost, to: track)
            try logMove(from: paths[0], to: paths[1], try syncRoots())
            return true
        }
    }

    /// Takes the lost paths `ids` out of Lost Stats, until their files are read again.
    public func dismissLost(_ ids: [Int64]) throws {
        try database.transaction {
            let dismiss = try statement(dismissLostSQL)
            for id in ids { try dismiss.run(id) }
        }
    }

    /// Deletes the path `id`, which has no stats, with what an import counted for it, which a
    /// count of no plays leaves. Call inside a transaction.
    func deletePath(_ id: Int64) throws {
        try statement("DELETE FROM \(importedPlaysTable) WHERE path_id = ?").run(id)
        try statement("DELETE FROM \(importedLastPlaysTable) WHERE path_id = ?").run(id)
        try statement(deleteRemovedSQL).run(id)
        // The ID can be handed out again, which mustn't inherit a cleared rating's clock.
        for field in [SyncField.rating, .loved] { try deleteStamp(field, id) }
        try statement("DELETE FROM paths WHERE id = ?").run(id)
    }

    /// Whether the path `id` has what a move keeps, as `hasStats` says.
    func pathHasStats(_ id: Int64) throws -> Bool {
        try !statement("SELECT 1 WHERE \(hasStats("?1"))").map(id, row: { _ in () }).isEmpty
    }

    /// Logs the move of `from` to `to`, both `paths` rows, when both are in share folders.
    func logMove(from: String, to: String, _ roots: SyncRoots) throws {
        guard let old = roots.syncPath(from), let new = roots.syncPath(to) else { return }
        try logSync(.move(from: old, to: new))
        try recordMove(from: old, to: new)
    }

    /// Gives the path `old` the file of the path `new`, which has no stats, and deletes `new`:
    /// the file keeps `old`'s ID, Date Added and stats. `old` keeps its own facts when `new`
    /// has none, as a path another machine's event added doesn't. Call inside a transaction.
    func move(_ old: Int64, to new: Int64) throws {
        // The file's row and its children change ID one at a time, so the checks wait for the
        // commit.
        try database.execute("PRAGMA defer_foreign_keys = ON")
        let (path, facts) = try statement(
            "SELECT path, codec, sample_rate_hz, length_frames, title FROM paths WHERE id = ?"
        ).map(new) { row in
            (
                try row.text(0),
                row.optionalText(1) == nil
                    ? nil
                    : [
                        try row.text(1), try row.int(2), try row.int(3), row.optionalText(4),
                    ] as [(any SQLiteValue)?]
            )
        }[0]
        try deletePath(new)
        try statement("UPDATE paths SET path = ?, lost_dismissed = 0 WHERE id = ?").run(path, old)
        if let facts {
            try statement(
                """
                UPDATE paths SET codec = ?, sample_rate_hz = ?, length_frames = ?, title = ?
                WHERE id = ?
                """
            ).run(binding: facts + [old])
        }
        for sql in [
            "UPDATE files SET id = ? WHERE id = ?",
            "UPDATE tracks SET file_id = ? WHERE file_id = ?",
            "UPDATE warnings SET file_id = ? WHERE file_id = ?",
            "UPDATE track_search SET rowid = ? WHERE rowid = ?",
        ] {
            try statement(sql).run(old, new)
        }
    }
}

/// Takes a lost path out of Lost Stats until its file is read again.
let dismissLostSQL = "UPDATE paths SET lost_dismissed = 1 WHERE id = ?"

/// How many of a lost path's matching tracks Resolve Lost Stats offers.
let lostCandidatesListed = 50

/// A path with stats that a file once had, which has left the index and wasn't dismissed or
/// removed from the library.
private let lostCondition = """
    p.codec IS NOT NULL AND p.lost_dismissed = 0
        AND NOT EXISTS (SELECT 1 FROM files WHERE id = p.id) AND \(hasStats("p.id"))
        AND NOT EXISTS (SELECT 1 FROM \(removedTable) WHERE path_id = p.id)
    """

/// Whether the path `id` has what a move keeps: plays, logged plays, a rating, an opinion or a
/// playlist entry.
func hasStats(_ id: String) -> String {
    """
    (EXISTS (SELECT 1 FROM plays WHERE path_id = \(id))
        OR EXISTS (SELECT 1 FROM history WHERE path_id = \(id))
        OR EXISTS (SELECT 1 FROM ratings WHERE path_id = \(id))
        OR EXISTS (SELECT 1 FROM \(lovedTable) WHERE path_id = \(id))
        OR EXISTS (SELECT 1 FROM \(dislikedTable) WHERE path_id = \(id))
        OR EXISTS (SELECT 1 FROM playlist_entries WHERE path_id = \(id)))
    """
}

private let movableSelect =
    "SELECT p.id, p.path, p.codec, p.sample_rate_hz, p.length_frames, p.title FROM paths p"

/// Tracks with no stats, which a lost path's stats can move to, in ID order.
private let freeTracksSelect =
    movableSelect + " JOIN tracks t ON t.file_id = p.id"
    + " WHERE p.codec IS NOT NULL AND NOT \(hasStats("p.id")) ORDER BY p.id"

private func movable(_ row: Row) throws -> MovablePath {
    MovablePath(
        id: try row.int64(0), path: try row.text(1),
        audio: AudioFacts(
            codec: try row.text(2), sampleRateHz: try row.int(3), frames: try row.int(4)),
        title: row.optionalText(5))
}

/// What a gone file and a new one must share to match.
struct AudioFacts: Hashable {
    /// The codec, or `lossless` for FLAC, ALAC and PCM, so a lossless file converted to another
    /// lossless codec, which keeps every frame, is the same audio.
    var codec: String
    var sampleRateHz: Int
    var frames: Int

    init(codec: String, sampleRateHz: Int, frames: Int) {
        self.codec = losslessCodecs.contains(codec) ? "lossless" : codec
        self.sampleRateHz = sampleRateHz
        self.frames = frames
    }
}

/// Lossless codecs, as `tracks.codec` stores them.
let losslessCodecs = Set(
    [TrackAudio.Codec.flac, .alac, .pcm].map(\.rawValue))

/// A gone path or a stat-less track as move matching sees it.
struct MovablePath {
    var id: Int64
    var path: String
    var audio: AudioFacts
    var title: String?
}

/// The gone and free paths that match one to one: sharing their audio facts, and of those,
/// alone in sharing their path but for the extension (a file converted in place), then, of
/// those left, alone in sharing a title. Audio facts alone never match: lengths repeat across a
/// large library, and a lost track's stats on another song are worse than stats waiting in
/// Lost Stats (ADR 0154). In the gone paths' ID order.
func movePairs(gone: [MovablePath], free: [MovablePath]) -> [(MovablePath, MovablePath)] {
    let goneByAudio = Dictionary(grouping: gone, by: \.audio)
    var pairs: [(MovablePath, MovablePath)] = []
    for (audio, news) in Dictionary(grouping: free, by: \.audio) {
        guard let olds = goneByAudio[audio] else { continue }
        let byStem = uniquePairs(olds, news, by: { withoutExtension($0.path) })
        pairs += byStem
        let paired = Set(byStem.flatMap { [$0.0.id, $0.1.id] })
        let titled = { (path: MovablePath) in !paired.contains(path.id) && path.title != nil }
        pairs += uniquePairs(olds.filter(titled), news.filter(titled), by: \.title)
    }
    return pairs.sorted { $0.0.id < $1.0.id }
}

/// The gone and new paths alone on each side in sharing `key`.
private func uniquePairs<Key: Hashable>(
    _ olds: [MovablePath], _ news: [MovablePath], by key: (MovablePath) -> Key
) -> [(MovablePath, MovablePath)] {
    let oldsByKey = Dictionary(grouping: olds, by: key)
    return Dictionary(grouping: news, by: key).compactMap { key, keyed in
        guard keyed.count == 1, let same = oldsByKey[key], same.count == 1 else { return nil }
        return (same[0], keyed[0])
    }
}

/// The path without its file's extension: `/M/a.m4a` and `/M/a.flac` are both `/M/a`.
private func withoutExtension(_ path: String) -> Substring {
    let name = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
    guard let dot = path[name...].lastIndex(of: "."), dot > name else { return path[...] }
    return path[..<dot]
}
