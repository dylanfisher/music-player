import DisplayText
import SQLite

extension LibraryIndex {
    /// The highest path ID, which a scan notes first to tell the paths it adds.
    func lastPathID() throws -> Int64 {
        try statement("SELECT ifnull(max(id), 0) FROM paths").map { try $0.int64(0) }[0]
    }

    /// Gives each gone path with stats to the path added after `id` that it matches, in one
    /// transaction, and returns the moves. A pair matches on codec, sample rate and length in
    /// frames, and where several share those, on title; any still ambiguous waits in Lost Stats.
    func matchMoves(addedAfter id: Int64) throws -> [TrackMove] {
        try database.transaction {
            let added = try statement(
                movableSelect + " JOIN tracks t ON t.file_id = p.id"
                    + " WHERE p.id > ? AND p.codec IS NOT NULL AND NOT \(hasStats("p.id"))"
            ).map(id, row: movable)
            guard !added.isEmpty else { return [] }
            let gone = try statement(movableSelect + " WHERE \(lostCondition)").map(row: movable)
            return try movePairs(gone: gone, added: added).map { old, new in
                try move(old.id, to: new.id)
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
            grouping: try statement(
                movableSelect + " JOIN tracks t ON t.file_id = p.id"
                    + " WHERE p.codec IS NOT NULL AND NOT \(hasStats("p.id")) ORDER BY p.id"
            ).map(row: movable), by: \.audio)
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
            })
    }

    /// Gives the stats of the lost path `lost` to the track `track`, which has none of its own,
    /// as the user picked in Lost Stats.
    public func moveStats(from lost: Int64, to track: Int64) throws {
        try database.transaction {
            let isLost =
                try statement("SELECT 1 FROM paths p WHERE p.id = ? AND \(lostCondition)")
                .map(lost) { _ in true }.first ?? false
            let isFree =
                try statement(
                    "SELECT 1 FROM tracks WHERE file_id = ? AND NOT \(hasStats("file_id"))"
                ).map(track) { _ in true }.first ?? false
            guard isLost, isFree else { throw LibraryError.statsNotMovable(from: lost, to: track) }
            try move(lost, to: track)
        }
    }

    /// Takes the lost paths `ids` out of Lost Stats, until their files are read again.
    public func dismissLost(_ ids: [Int64]) throws {
        try database.transaction {
            let dismiss = try statement("UPDATE paths SET lost_dismissed = 1 WHERE id = ?")
            for id in ids { try dismiss.run(id) }
        }
    }

    /// Deletes the path `id`, which has no stats, with what an import counted for it, which a
    /// count of no plays leaves. Call inside a transaction.
    func deletePath(_ id: Int64) throws {
        try statement("DELETE FROM \(importedPlaysTable) WHERE path_id = ?").run(id)
        try statement("DELETE FROM paths WHERE id = ?").run(id)
    }

    /// Gives the path `old` the file of the path `new`, which has no stats, and deletes `new`:
    /// the file keeps `old`'s ID, Date Added and stats. Call inside a transaction.
    private func move(_ old: Int64, to new: Int64) throws {
        // The file's row and its children change ID one at a time, so the checks wait for the
        // commit.
        try database.execute("PRAGMA defer_foreign_keys = ON")
        let row = try statement(
            "SELECT path, codec, sample_rate_hz, length_frames, title FROM paths WHERE id = ?"
        ).map(new) { row in
            [
                try row.text(0), try row.text(1), try row.int(2), try row.int(3),
                row.optionalText(4),
            ] as [(any SQLiteValue)?]
        }[0]
        try deletePath(new)
        try statement(
            """
            UPDATE paths SET path = ?, codec = ?, sample_rate_hz = ?, length_frames = ?,
                title = ?, lost_dismissed = 0
            WHERE id = ?
            """
        ).run(binding: row + [old])
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

/// How many of a lost path's matching tracks Resolve Lost Stats offers.
let lostCandidatesListed = 50

/// A path with stats that a file once had, which has left the index and wasn't dismissed.
private let lostCondition = """
    p.codec IS NOT NULL AND p.lost_dismissed = 0
        AND NOT EXISTS (SELECT 1 FROM files WHERE id = p.id) AND \(hasStats("p.id"))
    """

/// Whether the path `id` has what a move keeps: plays, logged plays, a rating, a love or a
/// playlist entry.
func hasStats(_ id: String) -> String {
    """
    (EXISTS (SELECT 1 FROM plays WHERE path_id = \(id))
        OR EXISTS (SELECT 1 FROM history WHERE path_id = \(id))
        OR EXISTS (SELECT 1 FROM ratings WHERE path_id = \(id))
        OR EXISTS (SELECT 1 FROM \(lovedTable) WHERE path_id = \(id))
        OR EXISTS (SELECT 1 FROM playlist_entries WHERE path_id = \(id)))
    """
}

private let movableSelect =
    "SELECT p.id, p.path, p.codec, p.sample_rate_hz, p.length_frames, p.title FROM paths p"

private func movable(_ row: Row) throws -> MovablePath {
    MovablePath(
        id: try row.int64(0), path: try row.text(1),
        audio: AudioFacts(
            codec: try row.text(2), sampleRateHz: try row.int(3), frames: try row.int(4)),
        title: row.optionalText(5))
}

/// What a gone file and a new one must share to match.
struct AudioFacts: Hashable {
    var codec: String
    var sampleRateHz: Int
    var frames: Int
}

/// A gone or added path as move matching sees it.
struct MovablePath {
    var id: Int64
    var path: String
    var audio: AudioFacts
    var title: String?
}

/// The gone and added paths that match one to one: alone in sharing their audio facts, or,
/// where several share them, alone in sharing their title too. In the gone paths' ID order.
func movePairs(gone: [MovablePath], added: [MovablePath]) -> [(MovablePath, MovablePath)] {
    let goneByAudio = Dictionary(grouping: gone, by: \.audio)
    var pairs: [(MovablePath, MovablePath)] = []
    for (audio, news) in Dictionary(grouping: added, by: \.audio) {
        guard let olds = goneByAudio[audio] else { continue }
        if olds.count == 1, news.count == 1 {
            pairs.append((olds[0], news[0]))
            continue
        }
        let oldsByTitle = Dictionary(grouping: olds, by: \.title)
        for (title, titled) in Dictionary(grouping: news, by: \.title) {
            if titled.count == 1, let same = oldsByTitle[title], same.count == 1 {
                pairs.append((same[0], titled[0]))
            }
        }
    }
    return pairs.sorted { $0.0.id < $1.0.id }
}
