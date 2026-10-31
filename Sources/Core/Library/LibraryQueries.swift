import Foundation
import Metadata
import SQLite
import Settings

/// The queries the library window runs. Each is a single indexed statement, prepared once per
/// shape of filter.
extension LibraryIndex {
    /// The IDs of the tracks `filter` lets through, in display order: by `column`, then by artist
    /// and album order.
    public func trackIDs(
        _ filter: TrackFilter = TrackFilter(), sortedBy column: TrackColumn,
        ascending: Bool = true
    ) throws -> [Int64] {
        try orderedTracks("t.file_id", filter, column, ascending) { try $0.int64(0) }
    }

    /// The names of the tracks `trackIDs` gives, in the same order, for Go to Item and
    /// type-to-select.
    public func trackNames(
        _ filter: TrackFilter = TrackFilter(), sortedBy column: TrackColumn,
        ascending: Bool = true
    ) throws -> [TrackName] {
        try orderedTracks(
            "t.file_id, f.path, t.title, ar.name, al.title, g.name", filter, column, ascending
        ) { row in
            let path = try row.text(1)
            return TrackName(
                id: try row.int64(0), title: row.optionalText(2) ?? displayName(path),
                artist: row.optionalText(3), album: row.optionalText(4),
                genre: row.optionalText(5))
        }
    }

    private func orderedTracks<T>(
        _ columns: String, _ filter: TrackFilter, _ column: TrackColumn, _ ascending: Bool,
        _ read: (Row) throws -> T
    ) throws -> [T] {
        let (conditions, values) = try trackConditions(
            filter, panes: [.source, .genre, .artist, .album, .search])
        // Playlist order is the shown playlist's; anywhere else it's null, which leaves the
        // album order below.
        var entries = ""
        var entryValues: [(any SQLiteValue)?] = []
        if column == .playlistOrder {
            entries = "LEFT JOIN playlist_entries pe ON pe.playlist_id = ? AND pe.path = f.path"
            if case .playlist(let id) = filter.source {
                entryValues = [id]
            } else {
                entryValues = [nil]
            }
        }
        let sql = """
            SELECT \(columns) FROM tracks t
            \(trackJoins)
            \(entries)
            \(whereClause(conditions))
            ORDER BY \(column.expression) \(ascending ? "ASC" : "DESC"), ar.sort_name,
                al.sort_title, t.disc_number, t.track_number, t.sort_title, t.file_id
            """
        return try statement(sql).map(binding: entryValues + values, row: read)
    }

    /// The genres of the tracks in `filter`'s source.
    public func genres(_ filter: TrackFilter = TrackFilter()) throws -> [BrowserEntry] {
        try pane("SELECT id, name FROM genres", "genre_id", "sort_name", filter, [.source])
    }

    /// The artists of the tracks in `filter`'s source and genre.
    public func artists(_ filter: TrackFilter = TrackFilter()) throws -> [BrowserEntry] {
        try pane(
            "SELECT id, name FROM artists", "artist_id", "sort_name", filter, [.source, .genre])
    }

    /// The albums of the tracks in `filter`'s source, genre and artist.
    public func albums(_ filter: TrackFilter = TrackFilter()) throws -> [BrowserEntry] {
        try pane(
            "SELECT id, title, (SELECT name FROM artists WHERE id = albums.artist_id) FROM albums",
            "album_id", "sort_title", filter, [.source, .genre, .artist], row: albumEntry)
    }

    /// The rows for `ids`, in the same order. An ID with no track, such as one a rescan just
    /// removed, is left out.
    public func rows(ids: [Int64]) throws -> [TrackRow] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let found = try statement(rowSelect + " WHERE t.file_id IN (\(placeholders))").map(
            binding: ids, row: trackRow)
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// The row for the file at `path`, or nil when the index has no track for it.
    public func track(path: String) throws -> TrackRow? {
        try statement(rowSelect + " WHERE f.path = ?").map(path, row: trackRow).first
    }

    /// The path of each of `ids` that is still in the index.
    public func paths(ids: [Int64]) throws -> [Int64: String] {
        let select = try statement("SELECT path FROM files WHERE id = ?")
        var paths: [Int64: String] = [:]
        for id in ids {
            if let path = try select.map(id, row: { try $0.text(0) }).first { paths[id] = path }
        }
        return paths
    }

    public func trackCount() throws -> Int {
        try statement("SELECT count(*) FROM tracks").map { try $0.int(0) }[0]
    }

    /// Every stored failure, then every warning, each in path order.
    public func fileIssues() throws -> [FileIssue] {
        let failures = try statement(
            """
            SELECT path, failure_kind, failure_offset, failure_detail FROM files
            WHERE failure_kind IS NOT NULL ORDER BY path
            """
        ).map { row in
            FileIssue(
                path: try row.text(0), problem: .failure(try errorKind(try row.text(1))),
                offset: row.optionalInt(2), detail: try row.text(3))
        }
        let warnings = try statement(
            """
            SELECT f.path, w.kind, w.offset, w.detail FROM warnings w
            JOIN files f ON f.id = w.file_id ORDER BY f.path, w.rowid
            """
        ).map { row in
            FileIssue(
                path: try row.text(0), problem: .warning(try warningKind(try row.text(1))),
                offset: row.optionalInt(2), detail: try row.text(3))
        }
        return failures + warnings
    }

    /// A pane's entries: those `rowSQL` selects whose ID is in `column` of a track `filter`'s
    /// `panes` let through.
    private func pane(
        _ rowSQL: String, _ column: String, _ order: String, _ filter: TrackFilter,
        _ panes: [FilterPart], row read: (Row) throws -> BrowserEntry = entry
    ) throws -> [BrowserEntry] {
        let (conditions, values) = try trackConditions(filter, panes: panes)
        // Joined to files only when a source needs it, since the join costs a lookup per track.
        let files = filter.source == nil ? "" : " JOIN files f ON f.id = t.file_id"
        let sql =
            "\(rowSQL) WHERE id IN (SELECT t.\(column) FROM tracks t\(files)"
            + "\(whereClause(conditions).isEmpty ? "" : " " + whereClause(conditions)))"
            + " ORDER BY \(order), id"
        return try statement(sql).map(binding: values, row: read)
    }
}

/// The parts of a `TrackFilter`, so each query names the ones it applies.
private enum FilterPart {
    case source, genre, artist, album, search
}

extension LibraryIndex {
    /// SQL conditions on tracks `t` and files `f` for the `panes` of `filter` that are set, and
    /// the values they bind, in order.
    fileprivate func trackConditions(_ filter: TrackFilter, panes: [FilterPart]) throws -> (
        [String], [(any SQLiteValue)?]
    ) {
        var conditions: [String] = []
        var values: [(any SQLiteValue)?] = []
        for part in panes {
            switch part {
            case .source:
                guard let source = filter.source else { continue }
                let (condition, sourceValues) = try sourceCondition(source)
                conditions.append(condition)
                values += sourceValues
            case .genre:
                guard let genre = filter.genre else { continue }
                conditions.append("t.genre_id = ?")
                values.append(genre)
            case .artist:
                guard let artist = filter.artist else { continue }
                conditions.append("t.artist_id = ?")
                values.append(artist)
            case .album:
                guard let album = filter.album else { continue }
                conditions.append("t.album_id = ?")
                values.append(album)
            case .search:
                guard let search = ftsQuery(filter.search) else { continue }
                conditions.append(
                    "t.file_id IN (SELECT rowid FROM track_search WHERE track_search MATCH ?)")
                values.append(search)
            }
        }
        return (conditions, values)
    }

    private func sourceCondition(_ source: BrowserSource) throws -> (
        String, [(any SQLiteValue)?]
    ) {
        switch source {
        case .folder(let folder):
            let range = pathRange(under: folder)
            return ("f.path >= ? AND f.path < ?", [range.lowerBound, range.upperBound])
        case .history:
            return ("f.path IN (SELECT path FROM history)", [])
        case .playlist(let id):
            let playlist = try playlist(id)
            switch playlist.kind {
            case .manual:
                return ("f.path IN (SELECT path FROM playlist_entries WHERE playlist_id = ?)", [id])
            case .smart(let rules):
                let (condition, values) = rules.condition(now: Date().timeIntervalSince1970)
                return (condition, values)
            case .unreadable(let detail):
                throw LibraryError.unreadableRules(playlist: playlist.name, detail: detail)
            }
        }
    }
}

private func whereClause(_ conditions: [String]) -> String {
    conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
}

/// Selects what `trackRow` reads, from tracks `t` and files `f`.
private let rowSelect = """
    SELECT t.file_id, f.path, t.title, ar.name, al.title, t.album_id, aa.name, g.name, t.date,
        t.track_number, t.disc_number, t.codec, t.sample_rate_hz, t.bits_per_sample,
        t.length_frames, f.added_seconds, t.art_offset, t.art_byte_count, t.art_mime_type,
        t.art_unsynchronised, al_ar.name, p.play_count, p.skip_count, p.last_played_seconds,
        r.rating
    FROM tracks t
    \(trackJoins)
    LEFT JOIN artists al_ar ON al_ar.id = al.artist_id
    """

private func trackRow(_ row: Row) throws -> TrackRow {
    let path = try row.text(1)
    let rate = try row.int(12)
    let art = try row.optionalInt(16).map { offset in
        EmbeddedArt(
            offset: offset, byteCount: try row.int(17), mimeType: try row.text(18),
            unsynchronised: try row.int(19) == 1)
    }
    return TrackRow(
        id: try row.int64(0), path: path,
        title: row.optionalText(2) ?? displayName(path), artist: row.optionalText(3),
        album: row.optionalText(4), albumID: row.optionalInt(5).map(Int64.init),
        albumArtist: row.optionalText(6), albumEntryArtist: row.optionalText(20),
        genre: row.optionalText(7), date: row.optionalText(8),
        trackNumber: row.optionalInt(9), discNumber: row.optionalInt(10), codec: try row.text(11),
        sampleRateHz: rate, bitsPerSample: row.optionalInt(13),
        durationSeconds: rate > 0 ? Double(try row.int(14)) / Double(rate) : 0,
        addedSeconds: try row.double(15), art: art, playCount: row.optionalInt(21) ?? 0,
        skipCount: row.optionalInt(22) ?? 0, lastPlayedSeconds: row.optionalDouble(23),
        rating: row.optionalInt(24) ?? 0)
}

private func entry(_ row: Row) throws -> BrowserEntry {
    BrowserEntry(id: try row.int64(0), name: try row.text(1))
}

private func albumEntry(_ row: Row) throws -> BrowserEntry {
    BrowserEntry(id: try row.int64(0), name: try row.text(1), artist: row.optionalText(2))
}

/// Each typed word as an FTS5 prefix phrase, so "beat abb" finds "The Beatles, Abbey Road".
/// Quotes are doubled, which is how FTS5 escapes them inside a phrase. Nil when nothing typed
/// has a letter or digit, which means no filter.
func ftsQuery(_ text: String) -> String? {
    let words = text.split(whereSeparator: \.isWhitespace)
        .filter { $0.contains { $0.isLetter || $0.isNumber } }
        .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
    return words.isEmpty ? nil : words.joined(separator: " ")
}

/// A stored warning kind. An unknown name means the database came from a different build.
private func warningKind(_ name: String) throws -> MetadataWarning.Kind {
    guard let kind = MetadataWarning.Kind(rawValue: name) else {
        throw LibraryError.unknownKind(name)
    }
    return kind
}
