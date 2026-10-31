import Foundation
import SQLite

/// Playlists and the stats: the user's data, which no scan recreates. Every row names its track
/// by path (ADR 0008), never by file ID, so an index rebuild leaves it attached.
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

    /// A manual playlist's paths in order, including any whose file has left the index.
    public func playlistPaths(_ id: Int64) throws -> [String] {
        try manual(id)
        return try statement(
            "SELECT path FROM playlist_entries WHERE playlist_id = ? ORDER BY position"
        ).map(id) { try $0.text(0) }
    }

    /// Appends `paths` to a manual playlist, leaving out those it already has, and returns how
    /// many were added.
    public func addToPlaylist(_ id: Int64, paths: [String]) throws -> Int {
        try database.transaction {
            try manual(id)
            var position =
                try statement(
                    "SELECT ifnull(max(position), -1) FROM playlist_entries WHERE playlist_id = ?"
                ).map(id) { try $0.int(0) }[0]
            let insert = try statement(
                "INSERT OR IGNORE INTO playlist_entries (playlist_id, path, position)"
                    + " VALUES (?, ?, ?)")
            var added = 0
            for path in paths {
                position += 1
                try insert.run(id, path, position)
                added += database.changes
            }
            return added
        }
    }

    /// Moves `paths` of a manual playlist, in their current order, to just before `target`, or
    /// to the end when `target` is nil. A target among the moved paths keeps them where they
    /// are, before the next path that isn't moving.
    public func movePlaylistEntries(_ id: Int64, paths: [String], before target: String?) throws {
        try database.transaction {
            let order = try playlistPaths(id)
            let moving = Set(paths)
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
                "UPDATE playlist_entries SET position = ? WHERE playlist_id = ? AND path = ?")
            for (position, path) in kept.enumerated() { try update.run(position, id, path) }
        }
    }

    /// How many of a manual playlist's entries have no track in the index, such as files moved
    /// or no longer watched. The table can't show them.
    public func missingEntryCount(_ id: Int64) throws -> Int {
        try statement(
            """
            SELECT count(*) FROM playlist_entries e WHERE e.playlist_id = ? AND NOT EXISTS
                (SELECT 1 FROM files f JOIN tracks t ON t.file_id = f.id WHERE f.path = e.path)
            """
        ).map(id) { try $0.int(0) }[0]
    }

    /// Takes `paths` out of a manual playlist. The files and tracks stay.
    public func removeFromPlaylist(_ id: Int64, paths: [String]) throws {
        try database.transaction {
            try manual(id)
            let delete = try statement(
                "DELETE FROM playlist_entries WHERE playlist_id = ? AND path = ?")
            for path in paths { try delete.run(id, path) }
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

    /// Counts a play of the track at `path`, at `seconds` since 1970, and logs it in the
    /// history.
    public func recordPlay(_ path: String, at seconds: Double) throws {
        try database.transaction {
            try statement(
                """
                INSERT INTO plays (path, play_count, skip_count, last_played_seconds)
                VALUES (?, 1, 0, ?)
                ON CONFLICT (path) DO UPDATE SET play_count = play_count + 1,
                    last_played_seconds = excluded.last_played_seconds
                """
            ).run(path, seconds)
            try statement("INSERT INTO history (path, played_seconds) VALUES (?, ?)").run(
                path, seconds)
        }
    }

    public func recordSkip(_ path: String) throws {
        try statement(
            """
            INSERT INTO plays (path, play_count, skip_count) VALUES (?, 0, 1)
            ON CONFLICT (path) DO UPDATE SET skip_count = skip_count + 1
            """
        ).run(path)
    }

    /// Rates the tracks at `paths` in stars; 0 clears the rating.
    public func setRating(_ stars: Int, paths: [String]) throws {
        precondition(
            (0...SmartField.maxRating).contains(stars), "a rating of \(stars) stars")
        try database.transaction {
            let write =
                stars == 0
                ? try statement("DELETE FROM ratings WHERE path = ?")
                : try statement("INSERT OR REPLACE INTO ratings (path, rating) VALUES (?, ?)")
            for path in paths {
                if stars == 0 { try write.run(path) } else { try write.run(path, stars) }
            }
        }
    }
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
