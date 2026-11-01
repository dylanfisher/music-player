import Foundation
import SQLite

/// Playlists and the stats: the user's data, which no scan recreates. Every row names its track
/// by its path's permanent ID (ADR 0022), which an index rebuild keeps.
extension LibraryIndex {
    // MARK: Playlists

    /// Every playlist, by name.
    public func playlists() throws -> [Playlist] {
        try statement("SELECT id, name, rules FROM playlists ORDER BY name COLLATE NOCASE, id")
            .map(row: playlistRow)
    }

    /// The playlist with `id`; throws when there is none.
    public func playlist(_ id: Int64) throws -> Playlist {
        guard
            let playlist = try statement("SELECT id, name, rules FROM playlists WHERE id = ?")
                .map(id, row: playlistRow).first
        else { throw LibraryError.unknownPlaylist(id) }
        return playlist
    }

    /// Adds an empty manual playlist, or a smart one for `rules`, and returns its ID.
    public func createPlaylist(named name: String, rules: SmartRules? = nil) throws -> Int64 {
        try statement("INSERT INTO playlists (name, rules) VALUES (?, ?)").run(
            name, try rules.map(checkedJSON))
        return database.lastInsertRowID
    }

    public func renamePlaylist(_ id: Int64, to name: String) throws {
        try statement("UPDATE playlists SET name = ? WHERE id = ?").run(name, id)
        guard database.changes == 1 else { throw LibraryError.unknownPlaylist(id) }
    }

    /// Replaces a smart playlist's rules, readable or not. Throws for a manual playlist, which
    /// has no rules to replace.
    public func setRules(_ rules: SmartRules, of id: Int64) throws {
        try statement("UPDATE playlists SET rules = ? WHERE id = ? AND rules IS NOT NULL").run(
            try checkedJSON(rules), id)
        guard database.changes == 1 else { throw LibraryError.unknownPlaylist(id) }
    }

    /// Deletes a playlist and its entries. The tracks stay in the library.
    public func deletePlaylist(_ id: Int64) throws {
        try statement("DELETE FROM playlists WHERE id = ?").run(id)
        guard database.changes == 1 else { throw LibraryError.unknownPlaylist(id) }
    }

    /// A manual playlist's track IDs in order, including any whose file has left the index.
    func playlistTrackIDs(_ id: Int64) throws -> [Int64] {
        try manual(id)
        return try statement(
            "SELECT path_id FROM playlist_entries WHERE playlist_id = ? ORDER BY position"
        ).map(id) { try $0.int64(0) }
    }

    /// Appends the tracks `ids` to a manual playlist, leaving out those it already has, and
    /// returns how many were added.
    public func addToPlaylist(_ id: Int64, trackIDs ids: [Int64]) throws -> Int {
        try database.transaction {
            try manual(id)
            var position =
                try statement(
                    "SELECT ifnull(max(position), -1) FROM playlist_entries WHERE playlist_id = ?"
                ).map(id) { try $0.int(0) }[0]
            let insert = try statement(
                "INSERT OR IGNORE INTO playlist_entries (playlist_id, path_id, position)"
                    + " VALUES (?, ?, ?)")
            var added = 0
            for track in ids {
                position += 1
                try insert.run(id, track, position)
                added += database.changes
            }
            return added
        }
    }

    /// Moves the tracks `ids` of a manual playlist, in their current order, to just before
    /// `target`, or to the end when `target` is nil. A target among the moved tracks keeps them
    /// where they are, before the next track that isn't moving.
    public func movePlaylistEntries(_ id: Int64, trackIDs ids: [Int64], before target: Int64?)
        throws
    {
        try database.transaction {
            let order = try playlistTrackIDs(id)
            let moving = Set(ids)
            let moved = order.filter { moving.contains($0) }
            var kept = order.filter { !moving.contains($0) }
            // A target among the moved rows means the first row after it that stays.
            let anchor = target.flatMap { target in
                order.firstIndex(of: target).flatMap { start in
                    order[start...].first { !moving.contains($0) }
                }
            }
            let at = anchor.flatMap { kept.firstIndex(of: $0) } ?? kept.count
            kept.insert(contentsOf: moved, at: at)
            let update = try statement(
                "UPDATE playlist_entries SET position = ? WHERE playlist_id = ? AND path_id = ?")
            for (position, track) in kept.enumerated() { try update.run(position, id, track) }
        }
    }

    /// How many of a manual playlist's entries have no track in the index, such as files moved
    /// or no longer watched. The table can't show them.
    public func missingEntryCount(_ id: Int64) throws -> Int {
        try statement(
            """
            SELECT count(*) FROM playlist_entries e WHERE e.playlist_id = ? AND NOT EXISTS
                (SELECT 1 FROM tracks t WHERE t.file_id = e.path_id)
            """
        ).map(id) { try $0.int(0) }[0]
    }

    /// Takes the tracks `ids` out of a manual playlist. The files and tracks stay.
    public func removeFromPlaylist(_ id: Int64, trackIDs ids: [Int64]) throws {
        try database.transaction {
            try manual(id)
            let delete = try statement(
                "DELETE FROM playlist_entries WHERE playlist_id = ? AND path_id = ?")
            for track in ids { try delete.run(id, track) }
        }
    }

    /// Throws unless `id` is a manual playlist.
    private func manual(_ id: Int64) throws {
        let playlist = try playlist(id)
        guard playlist.isManual else { throw LibraryError.smartPlaylist(playlist.name) }
    }

    private func checkedJSON(_ rules: SmartRules) throws -> String {
        if let problem = rules.rules.lazy.compactMap(\.problem).first ?? rules.limit?.problem {
            throw LibraryError.invalidRule(problem)
        }
        return try rules.json()
    }

    // MARK: Stats

    /// Counts a play of the file at `path`, at `seconds` since 1970, and logs it in the history.
    /// A path the index never held gets an ID here, so a file played from elsewhere is counted.
    public func recordPlay(_ path: String, at seconds: Double) throws {
        try database.transaction {
            let id = try pathID(path, seenAt: seconds)
            try statement(
                """
                INSERT INTO plays (path_id, play_count, skip_count, last_played_seconds)
                VALUES (?, 1, 0, ?)
                ON CONFLICT (path_id) DO UPDATE SET play_count = play_count + 1,
                    last_played_seconds = excluded.last_played_seconds
                """
            ).run(id, seconds)
            try statement("INSERT INTO history (path_id, played_at) VALUES (?, ?)").run(
                id, Int(seconds.rounded(.down)))
        }
    }

    public func recordSkip(_ path: String) throws {
        try database.transaction {
            let id = try pathID(path, seenAt: Date().timeIntervalSince1970)
            try statement(
                """
                INSERT INTO plays (path_id, play_count, skip_count) VALUES (?, 0, 1)
                ON CONFLICT (path_id) DO UPDATE SET skip_count = skip_count + 1
                """
            ).run(id)
        }
    }

    /// Rates the tracks `ids` in stars; 0 clears the rating.
    public func setRating(_ stars: Int, trackIDs ids: [Int64]) throws {
        precondition(
            (0...SmartField.maxRating).contains(stars), "a rating of \(stars) stars")
        try database.transaction {
            let write =
                stars == 0
                ? try statement("DELETE FROM ratings WHERE path_id = ?")
                : try statement("INSERT OR REPLACE INTO ratings (path_id, rating) VALUES (?, ?)")
            for id in ids {
                if stars == 0 { try write.run(id) } else { try write.run(id, stars) }
            }
        }
    }

    // MARK: The play timeline

    /// Up to `limit` plays logged before the play `id`, or the latest for nil, newest first.
    /// Paged by key, so a page costs the same at any depth and new plays don't shift it.
    public func timeline(before id: Int64?, limit: Int) throws -> [PlayEntry] {
        try statement(timelineSelect + " WHERE id < ? ORDER BY id DESC LIMIT ?").map(
            id ?? Int64.max, limit, row: playEntry)
    }

    /// Up to `limit` of the plays logged after the play `id`, the newest first.
    public func timeline(after id: Int64, limit: Int) throws -> [PlayEntry] {
        try statement(timelineSelect + " WHERE id > ? ORDER BY id DESC LIMIT ?").map(
            id, limit, row: playEntry)
    }

    /// The file and, where the index still has it, the track of each of the paths `ids`.
    public func playedTracks(ids: [Int64]) throws -> [Int64: PlayedTrack] {
        let unique = Array(Set(ids))
        let tracks = Dictionary(uniqueKeysWithValues: try rows(ids: unique).map { ($0.id, $0) })
        let paths = try inChunks(
            unique, { "SELECT id, path FROM paths WHERE id IN (\($0))" },
            { (try $0.int64(0), try $0.text(1)) })
        return Dictionary(
            paths.map { ($0.0, PlayedTrack(path: $0.1, track: tracks[$0.0])) },
            uniquingKeysWith: { first, _ in first })
    }

    /// How many plays the history holds: its last ID, since rows are never deleted.
    public func loggedPlayCount() throws -> Int {
        try statement("SELECT ifnull(max(id), 0) FROM history").map { try $0.int(0) }[0]
    }
}

private let timelineSelect = "SELECT id, path_id, played_at FROM history"

private func playEntry(_ row: Row) throws -> PlayEntry {
    PlayEntry(id: try row.int64(0), trackID: try row.int64(1), playedSeconds: try row.int(2))
}

private func playlistRow(_ row: Row) throws -> Playlist {
    let name = try row.text(1)
    let kind: Playlist.Kind
    if let json = row.optionalText(2) {
        do {
            kind = .smart(try SmartRules(json: json))
        } catch {
            kind = .unreadable("\(error)")
        }
    } else {
        kind = .manual
    }
    return Playlist(id: try row.int64(0), name: name, kind: kind)
}
