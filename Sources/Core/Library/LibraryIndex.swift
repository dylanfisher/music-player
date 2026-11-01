import Foundation
import Log
import Metadata
import SQLite

private let logger = moduleLogger()

/// `library.sqlite` in the app's data folder, `~/Library/Application Support/MusicPlayer`.
public func libraryFileURL(in dataDirectory: URL) -> URL {
    dataDirectory.appendingPathComponent("library.sqlite")
}

/// The library database: what every scanned file holds, and the stats no scan can recreate.
///
/// One connection. Like `Database`, it isn't `Sendable`: open one per thread or actor. The
/// scanner writes through its own; readers on other connections see each committed batch.
public final class LibraryIndex {
    let database: Database
    /// Name to row ID, loaded on first use and cleared when orphans are deleted.
    private var artistIDs: [String: Int64]?
    private var genreIDs: [String: Int64]?
    private var albumIDs: [AlbumKey: Int64]?

    /// Opens or creates the database at `url`. A part whose stored SQL differs from this build's
    /// is rebuilt: the index tables are emptied (the next scan refills them), and the stats are
    /// kept unless their own SQL changed.
    public init(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try Database(at: url)
        try prepareSchema()
    }

    private func prepareSchema() throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS \(schemaIdentityTable) (
                part TEXT PRIMARY KEY, sql TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS \(schemaDiscardsTable) (
                discarded_seconds REAL NOT NULL, detail TEXT NOT NULL)
            """)
        // A rebuild drops parents and children in any order, and dropping a table deletes its
        // rows, which foreign keys would check against tables already dropped. The pragma does
        // nothing inside a transaction, so it goes around it.
        try database.execute("PRAGMA foreign_keys = OFF")
        let rebuilt = Result { try rebuildStaleParts() }
        try database.execute("PRAGMA foreign_keys = ON")
        try rebuilt.get()
    }

    private func rebuildStaleParts() throws {
        try database.transaction {
            let stored = Dictionary(
                uniqueKeysWithValues: try database.prepare(
                    "SELECT part, sql FROM \(schemaIdentityTable)"
                ).map { row in (try row.text(0), try row.text(1)) })
            let stale = SchemaPart.allCases.filter { stored[$0.rawValue] != $0.sql }
            guard !stale.isEmpty else { return }
            // Stats tables that don't match are discarded with everything else; an index that
            // doesn't match is rebuilt around the stats.
            let rebuilt = stale.contains(.stats) ? SchemaPart.allCases : stale
            for part in rebuilt where stored[part.rawValue] != nil {
                logger.notice("the \(part.rawValue) tables don't match this build; rebuilding them")
            }
            if rebuilt.contains(.stats), stored[SchemaPart.stats.rawValue] != nil {
                try recordDiscardedStats()
            }
            try dropTables(keeping: rebuilt.contains(.stats) ? [] : statsTables)
            let identity = try database.prepare(
                "INSERT OR REPLACE INTO \(schemaIdentityTable) (part, sql) VALUES (?, ?)")
            for part in rebuilt {
                try database.execute(part.sql)
                try identity.run(part.rawValue, part.sql)
            }
        }
    }

    /// Counts the rows of the stats tables about to be dropped, and records them for the window
    /// to show once, when there were any (ADR 0022).
    private func recordDiscardedStats() throws {
        let existing = Set(
            try database.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").map {
                try $0.text(0)
            })
        var counts: [String] = []
        for table in statsTables.intersection(existing).sorted() {
            let rows = try database.prepare("SELECT count(*) FROM \"\(table)\"").map {
                try $0.int(0)
            }[0]
            if rows > 0 { counts.append("\(table) \(rows)") }
        }
        guard !counts.isEmpty else { return }
        let detail =
            "this build stores plays, ratings and playlists in a new shape, so those of the"
            + " earlier build were discarded (rows: \(counts.joined(separator: ", ")))"
        logger.error("\(detail)")
        try database.prepare(
            "INSERT INTO \(schemaDiscardsTable) (discarded_seconds, detail) VALUES (?, ?)"
        ).run(Date().timeIntervalSince1970, detail)
    }

    /// What stats rebuilds have discarded and the owner hasn't been shown, oldest first.
    public func discards() throws -> [DiscardNotice] {
        try database.prepare(
            "SELECT rowid, discarded_seconds, detail FROM \(schemaDiscardsTable) ORDER BY rowid"
        ).map { row in
            let date = Date(timeIntervalSince1970: try row.double(1))
            return DiscardNotice(
                id: try row.int64(0),
                text: "\(ISO8601DateFormatter().string(from: date)): \(try row.text(2))")
        }
    }

    /// Forgets the discards `ids` once they've been shown, so each shows once, and one the app
    /// crashed before showing shows next time.
    public func forgetDiscards(_ ids: [Int64]) throws {
        try database.transaction {
            let delete = try database.prepare("DELETE FROM \(schemaDiscardsTable) WHERE rowid = ?")
            for id in ids { try delete.run(id) }
        }
    }

    /// Drops every table but the identity table and `keeping`. Virtual tables go first, because
    /// dropping one also drops its shadow tables.
    private func dropTables(keeping: Set<String>) throws {
        let tables = try database.prepare(
            "SELECT name, sql LIKE 'CREATE VIRTUAL TABLE%' FROM sqlite_master"
                + " WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).map { row in (name: try row.text(0), isVirtual: try row.int(1) == 1) }
        let doomed = tables.filter {
            $0.name != schemaIdentityTable && $0.name != schemaDiscardsTable
                && !keeping.contains($0.name)
        }
        for table in doomed where table.isVirtual {
            try database.execute("DROP TABLE \"\(table.name)\"")
        }
        let remaining = Set(
            try database.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").map {
                try $0.text(0)
            })
        for table in doomed where !table.isVirtual && remaining.contains(table.name) {
            try database.execute("DROP TABLE \"\(table.name)\"")
        }
    }

    // MARK: Writes, for the scanner

    /// Every indexed file under `directory`, by path.
    func knownFiles(under directory: String) throws -> [String: KnownFile] {
        let range = pathRange(under: directory)
        var files: [String: KnownFile] = [:]
        try database.prepare(
            """
            SELECT f.path, f.id, f.size_bytes, f.modified_seconds, f.failure_kind,
                t.file_id IS NOT NULL
            FROM files f LEFT JOIN tracks t ON t.file_id = f.id
            WHERE f.path >= ? AND f.path < ?
            """
        ).query(range.lowerBound, range.upperBound) { row in
            files[try row.text(0)] = KnownFile(
                id: try row.int64(1), sizeBytes: try row.int(2), modifiedSeconds: try row.double(3),
                failure: try row.optionalText(4).map(errorKind), hasTrack: try row.int(5) == 1)
        }
        return files
    }

    /// Stores a batch of read results in one transaction.
    func store(_ files: [ScannedFile]) throws {
        do {
            try storeBatch(files)
        } catch let error as SQLiteError where error.isForeignKeyViolation {
            // Another scan (the command line beside the app) deleted orphans this connection
            // still has cached IDs for. The batch rolled back; reload the IDs and run it again.
            artistIDs = nil
            genreIDs = nil
            albumIDs = nil
            try storeBatch(files)
        }
    }

    private func storeBatch(_ files: [ScannedFile]) throws {
        try database.transaction {
            for file in files { try store(file) }
        }
    }

    private func store(_ file: ScannedFile) throws {
        switch file.outcome {
        case .success(let parsed):
            let id = try upsertFile(file, failure: nil)
            try clearTrack(id)
            try insertTrack(id, path: file.path, parsed.metadata)
            for warning in parsed.warnings {
                try statement(
                    "INSERT INTO warnings (file_id, kind, offset, detail) VALUES (?, ?, ?, ?)"
                ).run(id, warning.kind.rawValue, warning.offset, warning.detail)
            }
        case .failure(let error):
            if error.kind == .unreadable, let known = file.known, known.hasTrack {
                // Most likely the volume going away mid-read: keep what was read before, and its
                // size and mtime, so the next scan reads it again.
                try statement(
                    "UPDATE files SET failure_kind = ?, failure_offset = ?, failure_detail = ?"
                        + " WHERE id = ?"
                ).run(error.kind.rawValue, error.offset, error.detail, known.id)
                return
            }
            let id = try upsertFile(file, failure: error)
            try clearTrack(id)
        }
    }

    private func upsertFile(_ file: ScannedFile, failure: MetadataError?) throws -> Int64 {
        let values: [(any SQLiteValue)?] = [
            file.sizeBytes, file.modifiedSeconds, failure?.kind.rawValue, failure?.offset,
            failure?.detail,
        ]
        if let known = file.known {
            try statement(
                """
                UPDATE files SET size_bytes = ?, modified_seconds = ?, failure_kind = ?,
                    failure_offset = ?, failure_detail = ?
                WHERE id = ?
                """
            ).run(values[0], values[1], values[2], values[3], values[4], known.id)
            return known.id
        }
        // An upsert, since another scan (the command line beside the app) may have added the
        // path since this one listed what the index knew. The ID is the path's for good, so a
        // conflict on it is the same file.
        let id = try pathID(file.path, seenAt: Date().timeIntervalSince1970)
        try statement(
            """
            INSERT INTO files (id, path, size_bytes, modified_seconds, failure_kind,
                failure_offset, failure_detail)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET size_bytes = excluded.size_bytes,
                modified_seconds = excluded.modified_seconds,
                failure_kind = excluded.failure_kind, failure_offset = excluded.failure_offset,
                failure_detail = excluded.failure_detail
            """
        ).run(id, file.path, values[0], values[1], values[2], values[3], values[4])
        return id
    }

    /// The permanent ID of `path`, adding it to `paths` as first seen at `seconds` when it's
    /// new. Call inside a transaction, so no other connection adds it between the two steps.
    func pathID(_ path: String, seenAt seconds: Double) throws -> Int64 {
        precondition(database.isInTransaction, "pathID outside a transaction, for \(path)")
        if let id = try statement("SELECT id FROM paths WHERE path = ?").map(
            path,
            row: {
                try $0.int64(0)
            }
        ).first {
            return id
        }
        try statement("INSERT INTO paths (path, added_seconds) VALUES (?, ?)").run(path, seconds)
        return database.lastInsertRowID
    }

    private func clearTrack(_ id: Int64) throws {
        try statement("DELETE FROM track_search WHERE rowid = ?").run(id)
        try statement("DELETE FROM tracks WHERE file_id = ?").run(id)
        try statement("DELETE FROM warnings WHERE file_id = ?").run(id)
    }

    private func insertTrack(_ id: Int64, path: String, _ metadata: TrackMetadata) throws {
        let tags = metadata.tags
        let audio = metadata.audio
        let displayTitle = tags.title ?? displayName(path)
        let artist = try artistID(tags.artist)
        let albumArtist = try artistID(tags.albumArtist)
        let album = try albumID(
            tags.album,
            artist: tags.albumArtist != nil ? albumArtist : tags.compilation ? nil : artist)
        try statement(
            """
            INSERT INTO tracks (file_id, title, sort_title, artist_id, album_artist_id, album_id,
                genre_id, date, track_number, track_total, disc_number, disc_total, compilation,
                composer, comment, codec, sample_rate_hz, bits_per_sample, channels, length_frames,
                art_offset, art_byte_count, art_mime_type, art_unsynchronised)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ).run(
            id, tags.title, sortKey(displayTitle), artist, albumArtist, album,
            try genreID(tags.genre), tags.date, tags.trackNumber, tags.trackTotal, tags.discNumber,
            tags.discTotal, tags.compilation, tags.composer, tags.comment, audio.codec.rawValue,
            audio.sampleRateHz, audio.bitsPerSample, audio.channels, audio.lengthFrames,
            metadata.art?.offset, metadata.art?.byteCount, metadata.art?.mimeType,
            metadata.art?.unsynchronised)
        try statement(
            """
            INSERT INTO track_search (rowid, title, artist, album, album_artist, genre, composer)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        ).run(
            id, displayTitle, tags.artist, tags.album, tags.albumArtist, tags.genre, tags.composer)
    }

    /// Deletes files and everything stored for them, in one transaction.
    func remove(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try database.transaction {
            for id in ids {
                try statement("DELETE FROM track_search WHERE rowid = ?").run(id)
                try statement("DELETE FROM files WHERE id = ?").run(id)
            }
        }
    }

    /// Deletes every file outside `roots`, such as those of a folder no longer watched, and
    /// returns how many.
    public func removeFiles(outside roots: [String]) throws -> Int {
        let outside = try database.prepare("SELECT id, path FROM files").map { row in
            (id: try row.int64(0), path: try row.text(1))
        }.filter { file in !roots.contains { isPath(file.path, under: $0) } }
        try remove(outside.map(\.id))
        return outside.count
    }

    /// Deletes artists, albums and genres no track refers to any more.
    func deleteOrphans() throws {
        try database.transaction {
            try database.execute(
                """
                DELETE FROM albums WHERE id NOT IN
                    (SELECT album_id FROM tracks WHERE album_id IS NOT NULL);
                DELETE FROM artists WHERE id NOT IN
                    (SELECT artist_id FROM tracks WHERE artist_id IS NOT NULL)
                    AND id NOT IN
                    (SELECT album_artist_id FROM tracks WHERE album_artist_id IS NOT NULL)
                    AND id NOT IN (SELECT artist_id FROM albums WHERE artist_id IS NOT NULL);
                DELETE FROM genres WHERE id NOT IN
                    (SELECT genre_id FROM tracks WHERE genre_id IS NOT NULL);
                """)
        }
        artistIDs = nil
        genreIDs = nil
        albumIDs = nil
    }

    /// Folds the write-ahead log into the database file, so its size is the library's size.
    func checkpoint() throws {
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func artistID(_ name: String?) throws -> Int64? {
        guard let name else { return nil }
        if artistIDs == nil { artistIDs = try names("artists") }
        if let id = artistIDs?[name] { return id }
        try statement("INSERT INTO artists (name, sort_name) VALUES (?, ?)").run(
            name, sortKey(name))
        artistIDs?[name] = database.lastInsertRowID
        return database.lastInsertRowID
    }

    private func genreID(_ name: String?) throws -> Int64? {
        guard let name else { return nil }
        if genreIDs == nil { genreIDs = try names("genres") }
        if let id = genreIDs?[name] { return id }
        try statement("INSERT INTO genres (name, sort_name) VALUES (?, ?)").run(name, sortKey(name))
        genreIDs?[name] = database.lastInsertRowID
        return database.lastInsertRowID
    }

    private func albumID(_ title: String?, artist: Int64?) throws -> Int64? {
        guard let title else { return nil }
        if albumIDs == nil {
            albumIDs = Dictionary(
                uniqueKeysWithValues: try database.prepare(
                    "SELECT title, artist_id, id FROM albums"
                ).map { row in
                    (
                        AlbumKey(
                            title: try row.text(0), artist: row.optionalInt(1).map(Int64.init)),
                        try row.int64(2)
                    )
                })
        }
        let key = AlbumKey(title: title, artist: artist)
        if let id = albumIDs?[key] { return id }
        try statement("INSERT INTO albums (title, artist_id, sort_title) VALUES (?, ?, ?)").run(
            title, artist, sortKey(title))
        albumIDs?[key] = database.lastInsertRowID
        return database.lastInsertRowID
    }

    private func names(_ table: String) throws -> [String: Int64] {
        Dictionary(
            uniqueKeysWithValues: try database.prepare("SELECT name, id FROM \(table)").map { row in
                (try row.text(0), try row.int64(1))
            })
    }

    private var statements: [String: Statement] = [:]

    /// Prepares each write statement once per connection.
    func statement(_ sql: String) throws -> Statement {
        if let statement = statements[sql] { return statement }
        let statement = try database.prepare(sql)
        statements[sql] = statement
        return statement
    }
}

/// What the index holds about a file, enough to tell whether it changed.
struct KnownFile: Sendable {
    var id: Int64
    var sizeBytes: Int
    var modifiedSeconds: Double
    var failure: MetadataError.Kind?
    var hasTrack: Bool
}

/// A file the scanner read, or failed to read, with what it stats as.
struct ScannedFile: Sendable {
    var path: String
    var sizeBytes: Int
    var modifiedSeconds: Double
    var known: KnownFile?
    var outcome: Result<ParsedFile, MetadataError>
}

private struct AlbumKey: Hashable {
    var title: String
    var artist: Int64?
}

/// `path` as the library stores and compares it: without trailing slashes, except that "/"
/// stays, and in the decomposed Unicode form APFS lists names in. A folder typed or picked in
/// Settings can be precomposed, which Swift treats as equal but SQLite's bytewise comparison
/// and range queries don't (ADR 0009). Every configured root goes through this.
func canonicalPath(_ path: String) -> String {
    var trimmed = Substring(path.decomposedStringWithCanonicalMapping)
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
    return String(trimmed)
}

/// `directory` as a prefix of the paths under it: "dir" becomes "dir", and "/" becomes "".
private func stem(_ directory: String) -> String {
    let base = canonicalPath(directory)
    return base == "/" ? "" : base
}

/// Paths strictly under `directory`: from "dir/" up to, not including, "dir0", since "0" follows
/// "/" in byte order. The index on `files.path` serves the range.
func pathRange(under directory: String) -> Range<String> {
    let base = stem(directory)
    return (base + "/")..<(base + "0")
}

func isPath(_ path: String, under directory: String) -> Bool {
    path.hasPrefix(stem(directory) + "/")
}

/// What a track without a title tag is called: its file name without the extension.
func displayName(_ path: String) -> String {
    ((path as NSString).lastPathComponent as NSString).deletingPathExtension
}

/// Case, diacritic and width folded, so "élan", "Elan" and "ELAN" sort together.
func sortKey(_ text: String) -> String {
    text.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
}

/// A stored failure kind. An unknown name means the database came from a different build.
func errorKind(_ name: String) throws -> MetadataError.Kind {
    guard let kind = MetadataError.Kind(rawValue: name) else {
        throw LibraryError.unknownKind(name)
    }
    return kind
}
