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
            filter, panes: [.source, .genre, .artist, .album, .search], playsJoined: true)
        // Playlist order is the shown playlist's; anywhere else it's null, which leaves the
        // album order below.
        var entries = ""
        var entryValues: [(any SQLiteValue)?] = []
        if column == .playlistOrder {
            entries =
                "LEFT JOIN playlist_entries pe ON pe.playlist_id = ? AND pe.path_id = t.file_id"
            if case .playlist(let id) = filter.source {
                entryValues = [id]
            } else {
                entryValues = [nil]
            }
        }
        let direction = ascending ? "ASC" : "DESC"
        var order = "\(column.expression) \(direction)"
        let tieBreak: String
        if filter.groupByAlbumArtist, column == .artist || column == .album {
            // Each album's tracks stay together, in disc and track order, whoever plays on them.
            let artist = "ga.sort_name \(direction)"
            let album = "al.sort_title \(direction)"
            order =
                (column == .artist ? "\(artist), \(album)" : "\(album), \(artist)")
                + ", t.album_id \(direction)"
            tieBreak = "t.disc_number, t.track_number, t.sort_title, t.file_id"
        } else if column == .lastPlayed {
            // A time is almost unique, so the ID breaks ties without the artist and album
            // lookups the other columns need. In History every row has plays, so p.path_id is
            // t.file_id, and naming it lets plays_last_played supply the whole order.
            tieBreak = "\(filter.source == .history ? "p.path_id" : "t.file_id") \(direction)"
        } else {
            tieBreak =
                "\(filter.groupByAlbumArtist ? "ga" : "ar").sort_name, al.sort_title,"
                + " t.disc_number, t.track_number, t.sort_title, t.file_id"
        }
        let sql = """
            SELECT \(columns) FROM tracks t
            \(trackJoins)
            \(entries)
            \(whereClause(conditions))
            ORDER BY \(order), \(tieBreak)
            """
        return try statement(sql).map(binding: entryValues + values, row: read)
    }

    /// The genres of the tracks in `filter`'s source.
    public func genres(_ filter: TrackFilter = TrackFilter()) throws -> [BrowserEntry] {
        try pane("SELECT id, name FROM genres", "genre_id", "sort_name", filter, [.source])
    }

    /// The artists of the tracks in `filter`'s source and genre: their album artists when it
    /// groups by album artist.
    public func artists(_ filter: TrackFilter = TrackFilter()) throws -> [BrowserEntry] {
        try pane(
            "SELECT id, name FROM artists", artistColumn(filter), "sort_name", filter,
            [.source, .genre])
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
        let found = try inChunks(ids, { rowSelect + " WHERE t.file_id IN (\($0))" }, trackRow)
        // An ID asked for in two chunks comes back from both.
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Runs `sql`, given the placeholders of one `IN` list, over `ids` a chunk at a time, since
    /// SQLite takes at most 32,766 parameters. The last chunk repeats its last ID to the full
    /// size, which `IN` ignores, so one prepared statement serves every chunk.
    func inChunks<T>(_ ids: [Int64], _ sql: (String) -> String, _ read: (Row) throws -> T)
        throws -> [T]
    {
        guard let last = ids.last else { return [] }
        let size = min(ids.count, inListSize)
        let select = try statement(
            sql(Array(repeating: "?", count: size).joined(separator: ", ")))
        var results: [T] = []
        for start in stride(from: 0, to: ids.count, by: size) {
            var chunk = Array(ids[start..<min(start + size, ids.count)])
            chunk += Array(repeating: last, count: size - chunk.count)
            results += try select.map(binding: chunk, row: read)
        }
        return results
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
    /// `playsJoined` says the query joins plays as `p`, as `trackJoins` does.
    fileprivate func trackConditions(
        _ filter: TrackFilter, panes: [FilterPart], playsJoined: Bool = false
    ) throws -> ([String], [(any SQLiteValue)?]) {
        var conditions: [String] = []
        var values: [(any SQLiteValue)?] = []
        for part in panes {
            switch part {
            case .source:
                guard let source = filter.source else { continue }
                let (condition, sourceValues) = try sourceCondition(
                    source, playsJoined: playsJoined)
                conditions.append(condition)
                values += sourceValues
            case .genre:
                guard let genre = filter.genre else { continue }
                conditions.append("t.genre_id = ?")
                values.append(genre)
            case .artist:
                guard let artist = filter.artist else { continue }
                conditions.append("t.\(artistColumn(filter)) = ?")
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

    private func sourceCondition(_ source: BrowserSource, playsJoined: Bool) throws -> (
        String, [(any SQLiteValue)?]
    ) {
        switch source {
        case .folder(let folder):
            let range = pathRange(under: folder)
            return ("f.path >= ? AND f.path < ?", [range.lowerBound, range.upperBound])
        case .history:
            // On the joined plays the condition lets SQLite start from plays_last_played.
            if playsJoined { return ("p.last_played_seconds IS NOT NULL", []) }
            return (
                "t.file_id IN (SELECT path_id FROM plays WHERE last_played_seconds IS NOT NULL)",
                []
            )
        case .playlist(let id):
            let playlist = try playlist(id)
            switch playlist.kind {
            case .manual:
                return (
                    "t.file_id IN (SELECT path_id FROM playlist_entries WHERE playlist_id = ?)",
                    [id]
                )
            case .smart(let rules):
                let (condition, values) = rules.condition(now: Date().timeIntervalSince1970)
                return (condition, values)
            case .unreadable(let detail):
                throw LibraryError.unreadableRules(playlist: playlist.name, detail: detail)
            }
        case .timeline:
            // The timeline pages through plays with `timeline(before:limit:)` instead.
            throw LibraryError.playsNotTracks
        }
    }
}

/// The column of tracks the Artist pane lists and its selection matches.
private func artistColumn(_ filter: TrackFilter) -> String {
    filter.groupByAlbumArtist ? "group_artist_id" : "artist_id"
}

private func whereClause(_ conditions: [String]) -> String {
    conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
}

/// The most IDs one `IN` list binds: well under SQLite's limit, and few statement shapes.
let inListSize = 500

/// Selects what `trackRow` reads, from tracks `t` and files `f`.
private let rowSelect = """
    SELECT t.file_id, f.path, t.title, ar.name, al.title, t.album_id, aa.name, g.name, t.date,
        t.track_number, t.disc_number, t.codec, t.sample_rate_hz, t.bits_per_sample,
        t.length_frames, pa.added_seconds, t.art_offset, t.art_byte_count, t.art_mime_type,
        t.art_unsynchronised, al_ar.name, p.play_count, p.skip_count, p.last_played_seconds,
        r.rating, t.track_total, t.disc_total, t.compilation, t.composer, t.comment, t.channels,
        f.size_bytes, \(bitRateSQL), \(fileNameSQL), \(fileTypeSQL), f.created_seconds,
        f.modified_seconds, t.grouping, t.catalog_number, t.barcode, t.bpm, t.musical_key,
        t.conductor, t.lyricist, t.publisher, t.copyright, t.encoder, t.description,
        t.disc_subtitle, t.work, t.movement_number, t.movement_name, t.original_date,
        \(lovedSQL)
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
    var track = TrackRow(
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
    track.trackTotal = row.optionalInt(25)
    track.discTotal = row.optionalInt(26)
    track.compilation = try row.int(27) == 1
    track.composer = row.optionalText(28)
    track.comment = row.optionalText(29)
    track.channels = try row.int(30)
    track.sizeBytes = try row.int(31)
    track.bitRateKbps = row.optionalDouble(32)
    track.fileName = try row.text(33)
    track.fileType = try row.text(34)
    track.createdSeconds = row.optionalDouble(35)
    track.modifiedSeconds = try row.double(36)
    track.grouping = row.optionalText(37)
    track.catalogNumber = row.optionalText(38)
    track.barcode = row.optionalText(39)
    track.bpm = row.optionalInt(40)
    track.key = row.optionalText(41)
    track.conductor = row.optionalText(42)
    track.lyricist = row.optionalText(43)
    track.publisher = row.optionalText(44)
    track.copyright = row.optionalText(45)
    track.encoder = row.optionalText(46)
    track.description = row.optionalText(47)
    track.discSubtitle = row.optionalText(48)
    track.work = row.optionalText(49)
    track.movementNumber = row.optionalInt(50)
    track.movementName = row.optionalText(51)
    track.originalDate = row.optionalText(52)
    track.loved = try row.int(53) == 1
    return track
}

private func entry(_ row: Row) throws -> BrowserEntry {
    BrowserEntry(id: try row.int64(0), name: try row.text(1))
}

private func albumEntry(_ row: Row) throws -> BrowserEntry {
    BrowserEntry(id: try row.int64(0), name: try row.text(1), artist: row.optionalText(2))
}

/// Each typed word as an FTS5 prefix phrase, so "beat abb" finds "The Beatles, Abbey Road".
/// Quotes are doubled, which is how FTS5 escapes them inside a phrase. A NUL separates words,
/// since FTS5 would end the query there. Nil when nothing typed has a letter or digit, which
/// means no filter.
func ftsQuery(_ text: String) -> String? {
    let words = text.split { $0.isWhitespace || $0 == "\u{0}" }
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
