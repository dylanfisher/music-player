import Darwin
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
    /// Where the database is; other files of the library sit beside it.
    let fileURL: URL
    /// Name to row ID, loaded on first use and cleared when orphans are deleted.
    private var artistIDs: [String: Int64]?
    private var genreIDs: [String: Int64]?
    private var albumIDs: [AlbumKey: Int64]?

    /// Where the file SQLite couldn't read was moved, when this open moved it.
    public private(set) var movedAside: URL?
    /// Unreadable files kept beside the library; older ones are deleted when another is moved.
    static let keptUnreadableFiles = 3
    /// The wall clock sync events are stamped by, in milliseconds since 1970; tests set their
    /// own to skew one machine's.
    var wallClockMs: () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
    /// New `paths` rows one sync adds at most, so a hostile log can't fill the disk in one go;
    /// tests lower it.
    var maximumNewPathsPerSync = 500_000

    /// Opens or creates the database at `url`. A part whose stored SQL differs from this build's
    /// is rebuilt: the index tables are emptied (the next scan refills them), and the stats are
    /// kept unless their own SQL changed.
    ///
    /// A file SQLite can't read at all throws, unless `movingAsideIfUnreadable`, which only the
    /// window's first open at launch passes: then it's moved aside, with a discard notice
    /// saying where, and a new library is made (ADR 0023). Any other open moving it could leave
    /// a connection opened before on the old file, and the library split in two.
    public init(at url: URL, movingAsideIfUnreadable: Bool = false) throws {
        fileURL = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let detail: String?
        (database, movedAside, detail) = try Self.open(url, movingAside: movingAsideIfUnreadable)
        try prepareSchema()
        if let detail { try recordDiscard(detail) }
    }

    /// The database at `url`, after reading its header and schema, which any damage there fails.
    private static func readable(_ url: URL) throws(SQLiteError) -> Database {
        let database = try Database(at: url)
        try database.execute("SELECT count(*) FROM sqlite_master")
        return database
    }

    /// The database at `url`, and where and why the file there was moved aside, if it was.
    private static func open(_ url: URL, movingAside: Bool) throws -> (Database, URL?, String?) {
        do throws(SQLiteError) {
            return (try readable(url), nil, nil)
        } catch  where movingAside && error.isUnreadableFile {
            // Two launches at once: the second to take the lock finds the first's new file.
            let lock = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
            guard lock >= 0, flock(lock, LOCK_EX) == 0 else {
                throw CocoaError(
                    .fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path + ".lock"])
            }
            defer { Darwin.close(lock) }
            do throws(SQLiteError) {
                return (try readable(url), nil, nil)
            } catch  where error.isUnreadableFile {
                let aside = try moveAside(url)
                let detail =
                    "the library file couldn't be read (\(error.message)), so it was moved to"
                    + " \(aside.path) and a new library was started; the next scan fills it,"
                    + " and the plays, ratings and playlists stay in the old file"
                logger.error("\(detail)")
                return (try Database(at: url), aside, detail)
            }
        }
    }

    /// Renames the file at `url`, with its log and shared memory, which would otherwise be read
    /// into the new file, to a name no other move uses, and deletes all but the newest
    /// `keptUnreadableFiles` moved before.
    private static func moveAside(_ url: URL) throws -> URL {
        let stamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        ).replacingOccurrences(of: ":", with: "-")
        let prefix = url.lastPathComponent + ".unreadable-"
        let aside = url.deletingLastPathComponent().appendingPathComponent(
            prefix + stamp + "-" + UUID().uuidString.prefix(8))
        let suffixes = ["", Database.walSuffix, Database.shmSuffix]
        for suffix in suffixes where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.moveItem(atPath: url.path + suffix, toPath: aside.path + suffix)
        }
        let folder = url.deletingLastPathComponent()
        let moved = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(prefix) && !suffixes.dropFirst().contains(where: $0.hasSuffix) }
            .sorted()
        for old in moved.dropLast(keptUnreadableFiles) {
            for suffix in suffixes
            where FileManager.default.fileExists(atPath: folder.path + "/" + old + suffix) {
                try FileManager.default.removeItem(atPath: folder.path + "/" + old + suffix)
            }
        }
        return aside
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
        try database.execute(healthTracksSchema)
    }

    private func rebuildStaleParts() throws {
        try database.transaction {
            let stored = Dictionary(
                uniqueKeysWithValues: try database.prepare(
                    "SELECT part, sql FROM \(schemaIdentityTable)"
                ).map { row in (try row.text(0), try row.text(1)) })
            let stale = SchemaPart.allCases.filter { stored[$0.rawValue] != $0.sql }
            guard !stale.isEmpty else { return }
            // Stats tables that don't match are discarded with everything else, since every
            // other part refers to their paths, and so are they when an earlier sync part is
            // (SchemaPart.sync); any other part is rebuilt around the rest.
            var rebuilt =
                stale.contains(.stats)
                    || (stale.contains(.sync) && stored[SchemaPart.sync.rawValue] != nil)
                ? SchemaPart.allCases : stale
            if rebuilt.contains(.index), !rebuilt.contains(.scans) { rebuilt.append(.scans) }
            for part in rebuilt where stored[part.rawValue] != nil {
                logger.notice("the \(part.rawValue) tables don't match this build; rebuilding them")
            }
            // The sync part's rows are where reading the logs got to, which the next sync
            // reads again, not the owner's stats.
            let discarded = rebuilt.filter {
                stored[$0.rawValue] != nil && $0 != .sync && $0 != .scans
            }
            .compactMap(\.tables).reduce(into: Set<String>()) { $0.formUnion($1) }
            if !discarded.isEmpty { try recordDiscardedStats(discarded) }
            let kept = SchemaPart.allCases.filter { !rebuilt.contains($0) }.compactMap(\.tables)
                .reduce(into: Set<String>()) { $0.formUnion($1) }
            let rebuiltTables = rebuilt.compactMap(\.tables)
                .reduce(into: Set<String>()) { $0.formUnion($1) }
            try dropTables {
                rebuilt.contains(.index) ? !kept.contains($0) : rebuiltTables.contains($0)
            }
            let identity = try database.prepare(
                "INSERT OR REPLACE INTO \(schemaIdentityTable) (part, sql) VALUES (?, ?)")
            for part in rebuilt {
                try database.execute(part.sql)
                try identity.run(part.rawValue, part.sql)
            }
        }
    }

    /// Counts the rows of the stats `tables` about to be dropped, and records them for the
    /// window to show once, when there were any (ADR 0022).
    private func recordDiscardedStats(_ tables: Set<String>) throws {
        let existing = Set(
            try database.prepare(tableNamesSQL).map {
                try $0.text(0)
            })
        var counts: [String] = []
        for table in tables.intersection(existing).sorted() {
            let rows = try database.prepare("SELECT count(*) FROM \(quotedIdentifier(table))").map {
                try $0.int(0)
            }[0]
            if rows > 0 { counts.append("\(table) \(rows)") }
        }
        guard !counts.isEmpty else { return }
        let detail =
            "this build stores plays, ratings, loved tracks or playlists in a new shape, so those of the"
            + " earlier build were discarded (rows: \(counts.joined(separator: ", ")))"
        logger.error("\(detail)")
        try recordDiscard(detail)
    }

    /// Keeps `detail` for the window to show once.
    func recordDiscard(_ detail: String) throws {
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

    /// Drops every table `doomed` names but the identity and discards tables. Virtual tables go
    /// first, because dropping one also drops its shadow tables.
    private func dropTables(_ doomed: (String) -> Bool) throws {
        let tables = try database.prepare(
            "SELECT name, sql LIKE 'CREATE VIRTUAL TABLE%' FROM sqlite_master"
                + " WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).map { row in (name: try row.text(0), isVirtual: try row.int(1) == 1) }
        let doomed = tables.filter {
            $0.name != schemaIdentityTable && $0.name != schemaDiscardsTable && doomed($0.name)
        }
        for table in doomed where table.isVirtual {
            try database.execute("DROP TABLE \(quotedIdentifier(table.name))")
        }
        let remaining = Set(
            try database.prepare(tableNamesSQL).map {
                try $0.text(0)
            })
        for table in doomed where !table.isVirtual && remaining.contains(table.name) {
            try database.execute("DROP TABLE \(quotedIdentifier(table.name))")
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

    /// Whether the last whole scan of the folder at `root` finished, so the index holds all of
    /// it as of then.
    func finishedWholeScan(of root: String) throws -> Bool {
        try database.prepare(
            "SELECT EXISTS (SELECT 1 FROM \(scannedFoldersTable) WHERE root = ?)"
        ).map(canonicalPath(root)) { try $0.int(0) == 1 }[0]
    }

    /// Records whether the whole scan of the folder at `root` finished: false as one starts.
    func setFinishedWholeScan(of root: String, _ finished: Bool) throws {
        try statement(
            finished
                ? "INSERT OR IGNORE INTO \(scannedFoldersTable) (root) VALUES (?)"
                : "DELETE FROM \(scannedFoldersTable) WHERE root = ?"
        ).run(canonicalPath(root))
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
            let roots = try syncRoots()
            for file in files { try store(file, roots) }
        }
    }

    private func store(_ file: ScannedFile, _ roots: SyncRoots) throws {
        switch file.outcome {
        case .success(let parsed):
            let id = try upsertFile(file, failure: nil, roots)
            try clearTrack(id)
            try insertTrack(id, path: file.path, parsed.metadata)
            try recordFacts(id, parsed.metadata)
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
            let id = try upsertFile(file, failure: error, roots)
            try clearTrack(id)
        }
    }

    /// A new path's Date Added goes in the sync log.
    private func upsertFile(_ file: ScannedFile, failure: MetadataError?, _ roots: SyncRoots)
        throws -> Int64
    {
        let values: [(any SQLiteValue)?] = [
            file.sizeBytes, file.modifiedSeconds, file.createdSeconds, failure?.kind.rawValue,
            failure?.offset, failure?.detail,
        ]
        if let known = file.known {
            try statement(
                """
                UPDATE files SET size_bytes = ?, modified_seconds = ?, created_seconds = ?,
                    failure_kind = ?, failure_offset = ?, failure_detail = ?
                WHERE id = ?
                """
            ).run(values[0], values[1], values[2], values[3], values[4], values[5], known.id)
            return known.id
        }
        // An upsert, since another scan (the command line beside the app) may have added the
        // path since this one listed what the index knew. The ID is the path's for good, so a
        // conflict on it is the same file.
        let seen = Date().timeIntervalSince1970
        let nfc = file.path.precomposedStringWithCanonicalMapping
        let id: Int64
        if let known = try existingPathID(nfc) {
            id = known
        } else {
            id = try insertPath(nfc, seenAt: seen)
            if let path = roots.syncPath(nfc) { try logSync(.added(path: path, at: seen)) }
        }
        try statement(
            """
            INSERT INTO files (id, path, name_offset, size_bytes, modified_seconds,
                created_seconds, failure_kind, failure_offset, failure_detail)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET size_bytes = excluded.size_bytes,
                modified_seconds = excluded.modified_seconds,
                created_seconds = excluded.created_seconds,
                failure_kind = excluded.failure_kind, failure_offset = excluded.failure_offset,
                failure_detail = excluded.failure_detail
            """
        ).run(
            id, file.path, nameOffset(file.path), values[0], values[1], values[2], values[3],
            values[4], values[5])
        return id
    }

    /// The permanent ID of `path`, in any Unicode spelling, adding it to `paths` as first seen
    /// at `seconds` when it's new. Call inside a transaction, so no other connection adds it
    /// between the two steps.
    func pathID(_ path: String, seenAt seconds: Double) throws -> Int64 {
        precondition(database.isInTransaction, "pathID outside a transaction, for \(path)")
        let nfc = path.precomposedStringWithCanonicalMapping
        return try existingPathID(nfc) ?? insertPath(nfc, seenAt: seconds)
    }

    /// The ID of `nfc`, a path in NFC, when `paths` has it.
    func existingPathID(_ nfc: String) throws -> Int64? {
        try statement("SELECT id FROM paths WHERE path = ?").map(nfc) { try $0.int64(0) }.first
    }

    private func insertPath(_ nfc: String, seenAt seconds: Double) throws -> Int64 {
        try statement("INSERT INTO paths (path, added_seconds) VALUES (?, ?)").run(nfc, seconds)
        return database.lastInsertRowID
    }

    /// Keeps what move matching compares on the path `id`, since a gone file can't be read.
    private func recordFacts(_ id: Int64, _ metadata: TrackMetadata) throws {
        let audio = metadata.audio
        try statement(
            """
            UPDATE paths SET codec = ?, sample_rate_hz = ?, length_frames = ?, title = ?,
                lost_dismissed = 0
            WHERE id = ?
            """
        ).run(
            audio.codec.rawValue, audio.sampleRateHz, audio.lengthFrames,
            metadata.tags.title?.precomposedStringWithCanonicalMapping, id)
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
        let groupArtist =
            tags.albumArtist != nil
            ? albumArtist : tags.compilation ? try artistID(variousArtists) : artist
        try statement(
            """
            INSERT INTO tracks (file_id, title, sort_title, artist_id, album_artist_id,
                group_artist_id, album_id, genre_id, date, track_number, track_total,
                disc_number, disc_total, compilation, composer, comment, grouping,
                catalog_number, barcode, bpm, musical_key, conductor, lyricist, publisher,
                copyright, encoder, description, disc_subtitle, work, movement_number,
                movement_name, original_date, codec, sample_rate_hz, bits_per_sample, channels,
                length_frames, art_offset, art_byte_count, art_mime_type, art_unsynchronised)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ).run(
            binding: [
                id, tags.title, sortKey(displayTitle), artist, albumArtist, groupArtist, album,
                try genreID(tags.genre), tags.date, tags.trackNumber, tags.trackTotal,
                tags.discNumber, tags.discTotal, tags.compilation, tags.composer, tags.comment,
                tags.grouping, tags.catalogNumber, tags.barcode, tags.bpm, tags.key,
                tags.conductor, tags.lyricist, tags.publisher, tags.copyright, tags.encoder,
                tags.description, tags.discSubtitle, tags.work, tags.movementNumber,
                tags.movementName, tags.originalDate, audio.codec.rawValue, audio.sampleRateHz,
                audio.bitsPerSample, audio.channels, audio.lengthFrames, metadata.art?.offset,
                metadata.art?.byteCount, metadata.art?.mimeType, metadata.art?.unsynchronised,
            ])
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
            for id in ids { try deleteFile(id) }
        }
    }

    /// Deletes the file `id` and everything stored for it. Call inside a transaction.
    func deleteFile(_ id: Int64) throws {
        try statement("DELETE FROM track_search WHERE rowid = ?").run(id)
        try statement("DELETE FROM files WHERE id = ?").run(id)
    }

    /// Deletes every file outside `roots`, such as those of a folder no longer watched, and
    /// returns how many.
    func removeFiles(outside roots: [String]) throws -> Int {
        let outside = try database.prepare("SELECT id, path FROM files").map { row in
            (id: try row.int64(0), path: try row.text(1))
        }.filter { file in !roots.contains { isPath(file.path, under: $0) } }
        try remove(outside.map(\.id))
        let watched = Set(roots.map(canonicalPath))
        let finished = try database.prepare("SELECT root FROM \(scannedFoldersTable)").map {
            try $0.text(0)
        }
        for root in finished where !watched.contains(root) {
            try setFinishedWholeScan(of: root, false)
        }
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
                    AND id NOT IN
                    (SELECT group_artist_id FROM tracks WHERE group_artist_id IS NOT NULL)
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
    package func checkpoint() throws {
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

/// Every table's name in a database.
let tableNamesSQL = "SELECT name FROM sqlite_master WHERE type = 'table'"

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
    var createdSeconds: Double? = nil
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
func stem(_ directory: String) -> String {
    let base = canonicalPath(directory)
    return base == "/" ? "" : base
}

/// Paths strictly under `directory`: from "dir/" up to, not including, "dir0", since "0" follows
/// "/" in byte order. The index on `files.path` serves the range.
func pathRange(under directory: String) -> Range<String> {
    let base = stem(directory)
    return (base + "/")..<(base + "0")
}

/// `pathRange` for `directory` byte for byte, without putting it in canonical form first.
func exactPathRange(under directory: String) -> Range<String> {
    let base = directory == "/" ? "" : directory
    return (base + "/")..<(base + "0")
}

func isPath(_ path: String, under directory: String) -> Bool {
    path.hasPrefix(stem(directory) + "/")
}

/// Where the file name starts in `path`, counting Unicode scalars from 1, as SQLite's `substr`
/// counts characters.
func nameOffset(_ path: String) -> Int {
    path.unicodeScalars.count - (path as NSString).lastPathComponent.unicodeScalars.count + 1
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
