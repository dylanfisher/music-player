import Metadata
import SQLite

/// The queries the library window runs. Each is a single indexed statement, prepared once.
extension LibraryIndex {
    /// Every track's ID in display order: by `column`, then by artist and album order. With
    /// `matching`, only tracks whose title, artist, album, album artist, genre or composer have
    /// words starting with each word typed, as search-as-you-type needs.
    public func trackIDs(
        sortedBy column: TrackSortColumn, ascending: Bool = true, matching text: String = ""
    ) throws -> [Int64] {
        let search = ftsQuery(text)
        let sql = """
            SELECT t.file_id FROM tracks t
            JOIN files f ON f.id = t.file_id
            LEFT JOIN artists ar ON ar.id = t.artist_id
            LEFT JOIN artists aa ON aa.id = t.album_artist_id
            LEFT JOIN albums al ON al.id = t.album_id
            LEFT JOIN genres g ON g.id = t.genre_id
            \(search == nil ? "" : "WHERE t.file_id IN (SELECT rowid FROM track_search WHERE track_search MATCH ?)")
            ORDER BY \(column.expression) \(ascending ? "ASC" : "DESC"), ar.sort_name,
                al.sort_title, t.disc_number, t.track_number, t.sort_title, t.file_id
            """
        let statement = try statement(sql)
        if let search { return try statement.map(search) { try $0.int64(0) } }
        return try statement.map { try $0.int64(0) }
    }

    public func genres() throws -> [BrowserEntry] {
        try statement("SELECT id, name FROM genres ORDER BY sort_name, id").map(row: entry)
    }

    /// The artists of tracks in `genre`, or of every track.
    public func artists(genre: Int64? = nil) throws -> [BrowserEntry] {
        let filter = genre == nil ? "" : " WHERE genre_id = ?"
        return try entries(
            "SELECT id, name FROM artists WHERE id IN (SELECT artist_id FROM tracks\(filter))"
                + " ORDER BY sort_name, id", genre)
    }

    /// The albums of tracks by `artist` and in `genre`, either of which may be nil for any.
    public func albums(artist: Int64? = nil, genre: Int64? = nil) throws -> [BrowserEntry] {
        let conditions = [artist.map { _ in "artist_id = ?" }, genre.map { _ in "genre_id = ?" }]
            .compactMap { $0 }
        let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let sql =
            "SELECT id, title FROM albums WHERE id IN (SELECT album_id FROM tracks\(filter))"
            + " ORDER BY sort_title, id"
        return switch (artist, genre) {
        case (let artist?, let genre?): try statement(sql).map(artist, genre, row: entry)
        case (let artist?, nil): try entries(sql, artist)
        case (nil, let genre?): try entries(sql, genre)
        case (nil, nil): try entries(sql, nil)
        }
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

    /// Runs a pane query with at most one parameter.
    private func entries(_ sql: String, _ value: Int64?) throws -> [BrowserEntry] {
        let statement = try statement(sql)
        if let value { return try statement.map(value, row: entry) }
        return try statement.map(row: entry)
    }
}

private func entry(_ row: Row) throws -> BrowserEntry {
    BrowserEntry(id: try row.int64(0), name: try row.text(1))
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
