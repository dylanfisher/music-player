import Foundation
import SQLite3
import Settings
import Testing

@testable import Fixtures
@testable import Library
@testable import SQLite

private func ratingPaths(_ index: LibraryIndex) throws -> [String] {
    try index.database.prepare(
        "SELECT pa.path FROM ratings r JOIN paths pa ON pa.id = r.path_id"
    ).map { try $0.text(0) }
}

@Test func indexRebuildKeepsTheStats() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let id = try #require(try index.track(path: library.path(library.manifest.files[0]))).id
    try index.database.prepare("INSERT INTO ratings (path_id, rating) VALUES (?, ?)").run(id, 80)
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'index'")

    let rebuilt = try library.index()
    #expect(try rebuilt.trackCount() == 0)
    #expect(try ratingPaths(rebuilt) == [library.path(library.manifest.files[0])])
    // Nothing is known, so the rescan reads every file again and finds the same paths.
    #expect(try library.scan().read == library.manifest.files.count)
    #expect(try rebuilt.trackCount() == library.readableCount)
}

@Test func statsThatDontMatchAreDiscardedAndReportedOnce() throws {
    let library = try TestLibrary()
    let index = try library.index()
    try index.recordPlay("/x.flac", at: 100)
    let id = try index.database.transaction { try index.pathID("/x.flac", seenAt: 0) }
    try index.setRating(1, trackIDs: [id])
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'stats'")

    let rebuilt = try library.index()
    #expect(try ratingPaths(rebuilt).isEmpty)
    let discards = try rebuilt.discards()
    #expect(discards.count == 1)
    #expect(
        discards.first?.text.hasSuffix(
            "(rows: history 1, paths 1, plays 1, ratings 1)") == true, "\(discards)")
    // Until it's been shown, it stays.
    #expect(try rebuilt.discards() == discards)
    try rebuilt.forgetDiscards(discards.map(\.id))
    #expect(try rebuilt.discards().isEmpty)
    // Empty stats lose nothing, so nothing is recorded.
    try rebuilt.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'stats'")
    #expect(try library.index().discards().isEmpty)
}

@Test func aRecordedDiscardSurvivesAnotherRebuild() throws {
    let library = try TestLibrary()
    let index = try library.index()
    try index.recordSkip("/x.flac")
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'stats'")
    let rebuilt = try library.index()
    try rebuilt.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'index'")
    #expect(try library.index().discards().count == 1)
}

@Test func theRecordedPathsRefillFromHistoryAndDiscardNothing() throws {
    let library = try TestLibrary()
    let index = try library.index()
    try index.recordPlay("/x.flac", at: 100)
    try index.database.execute(
        """
        DELETE FROM \(recordedTable);
        UPDATE schema_identity SET sql = 'older' WHERE part = 'recorded'
        """)

    let rebuilt = try library.index()
    #expect(try rebuilt.discards().isEmpty)
    #expect(
        try rebuilt.database.prepare(
            "SELECT pa.path FROM \(recordedTable) r JOIN paths pa ON pa.id = r.path_id"
        ).map { try $0.text(0) } == ["/x.flac"])
}

private func historyIndexes(_ index: LibraryIndex) throws -> [String] {
    try index.database.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'history' ORDER BY name"
    ).map { try $0.text(0) }
}

private func playedPaths(_ index: LibraryIndex) throws -> [String] {
    try index.database.prepare(
        "SELECT pa.path FROM history h JOIN paths pa ON pa.id = h.path_id"
    ).map { try $0.text(0) }
}

@Test func anIndexWithoutTheHistoryByPathPartKeepsItsPlaysAndGainsTheIndex() throws {
    let library = try TestLibrary()
    let index = try library.index()
    try index.recordPlay("/x.flac", at: 100)
    try index.database.execute(
        """
        DROP INDEX \(historyByPathIndex);
        DELETE FROM schema_identity WHERE part = 'historyByPath'
        """)

    let opened = try library.index()
    #expect(try opened.discards().isEmpty)
    #expect(try playedPaths(opened) == ["/x.flac"])
    #expect(try historyIndexes(opened) == ["history_path", historyByPathIndex])
    // A part of an earlier shape is made again, its index dropped first.
    try opened.database.execute(
        "UPDATE schema_identity SET sql = 'older' WHERE part = 'historyByPath'")
    let rebuilt = try library.index()
    #expect(try rebuilt.discards().isEmpty)
    #expect(try playedPaths(rebuilt) == ["/x.flac"])
    #expect(try historyIndexes(rebuilt) == ["history_path", historyByPathIndex])
}

@Test func idsAndDateAddedSurviveAnIndexRebuild() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let before = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'index'")
    let rebuilt = try library.index()
    _ = try library.scan()
    let after = try rebuilt.rows(ids: try rebuilt.trackIDs(sortedBy: .path))
    #expect(after.map(\.path) == before.map(\.path))
    #expect(after.map(\.id) == before.map(\.id))
    #expect(after.map(\.addedSeconds) == before.map(\.addedSeconds))
}

@Test func aFileThatLeavesAndComesBackKeepsItsIDDateAddedAndStats() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let file = try #require(library.manifest.files.first { $0.malformation == nil })
    let path = library.path(file)
    let row = try #require(try index.track(path: path))
    try index.recordPlay(path, at: 500)
    try index.setRating(2, trackIDs: [row.id])
    let aside = path + ".aside"
    try FileManager.default.moveItem(atPath: path, toPath: aside)
    #expect(try library.scan().removed == 1)
    #expect(try index.track(path: path) == nil)
    // A different path is a different ID, as before.
    #expect(try index.database.transaction { try index.pathID(aside, seenAt: 0) } != row.id)

    try FileManager.default.moveItem(atPath: aside, toPath: path)
    _ = try library.scan()
    let back = try #require(try index.track(path: path))
    #expect(back.id == row.id)
    #expect(back.addedSeconds == row.addedSeconds)
    #expect(back.playCount == 1)
    #expect(back.lastPlayedSeconds == 500)
    #expect(back.rating == 2)
}

@Test func statsTablesListsWhatTheStatsSQLCreates() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("stats-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try Database(at: directory.appendingPathComponent("stats.sqlite"))
    try database.execute(SchemaPart.stats.sql())
    let tables = try database.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
    ).map {
        try $0.text(0)
    }
    #expect(Set(tables) == statsTables)
}

@Test func everySortColumnOrdersEveryTrack() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let all = Set(try index.trackIDs(sortedBy: .path))
    #expect(all.count == library.readableCount)
    for column in TrackColumn.allCases where column.isSortable {
        for ascending in [true, false] {
            let ids = try index.trackIDs(sortedBy: column, ascending: ascending)
            #expect(ids.count == all.count && Set(ids) == all, "\(column)")
        }
    }
}

@Test func sortsByFoldedArtistThenAlbumOrder() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let ascending = try index.trackIDs(sortedBy: .artist)
    let rows = try ascending.map { id in
        try index.database.prepare(
            """
            SELECT ifnull(ar.sort_name, ''), ifnull(t.disc_number, 0), ifnull(t.track_number, 0),
                ifnull(al.sort_title, '')
            FROM tracks t LEFT JOIN artists ar ON ar.id = t.artist_id
            LEFT JOIN albums al ON al.id = t.album_id WHERE t.file_id = ?
            """
        ).map(id) { row in
            (try row.text(0), try row.text(3), try row.int(1), try row.int(2))
        }[0]
    }
    for (earlier, later) in zip(rows, rows.dropFirst()) {
        #expect(
            earlier.0 < later.0 || (earlier.0 == later.0 && earlier.1 < later.1)
                || (earlier.0 == later.0 && earlier.1 == later.1
                    && (earlier.2, earlier.3) <= (later.2, later.3)),
            "\(earlier) before \(later)")
    }
    let sortNames = Dictionary(uniqueKeysWithValues: zip(ascending, rows.map(\.0)))
    let descending = try index.trackIDs(sortedBy: .artist, ascending: false)
    #expect(descending.first.flatMap { sortNames[$0] } == rows.map(\.0).max())
}

@Test func searchMatchesWordPrefixesInAnyField() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let tagged = library.manifest.files.filter {
        $0.malformation == nil && $0.tags?.artist != nil && $0.tags?.album != nil
    }
    let artist = try #require(tagged.first?.tags?.artist)
    let album = try #require(tagged.first?.tags?.album)
    let word = String(try #require(artist.split(separator: " ").first).prefix(3))
    let byArtist = Set(try index.trackIDs(TrackFilter(search: word.uppercased()), sortedBy: .title))
    let known = try index.knownFiles(under: library.root)
    for file in tagged where file.tags?.artist == artist {
        #expect(byArtist.contains(try #require(known[library.path(file)]).id), "\(file.path)")
    }

    let albumWord = String(try #require(album.split(separator: " ").last))
    let both = try index.trackIDs(TrackFilter(search: "\(word) \(albumWord)"), sortedBy: .title)
    #expect(!both.isEmpty)
    #expect(Set(both).isSubset(of: byArtist))
    #expect(try index.trackIDs(TrackFilter(search: "zzqx"), sortedBy: .title).isEmpty)
    #expect(
        try index.trackIDs(TrackFilter(search: "\" ' - ( *"), sortedBy: .title).count
            == library.readableCount)
}

@Test func searchTextBecomesQuotedPrefixPhrases() {
    #expect(ftsQuery("beat abb") == "\"beat\"* \"abb\"*")
    #expect(ftsQuery("say \"hi\"") == "\"say\"* \"\"\"hi\"\"\"*")
    #expect(ftsQuery("AC/DC") == "\"AC/DC\"*")
    #expect(ftsQuery("  - ( ") == nil)
}

@Test func browserPanesNarrowByGenreAndArtist() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let tagged = library.manifest.files.compactMap { file in
        file.malformation.map { $0 == .truncated || $0.isFieldLevel } ?? true ? file.tags : nil
    }
    #expect(Set(try index.genres().map(\.name)) == Set(tagged.compactMap(\.genre)))
    #expect(Set(try index.artists().map(\.name)) == Set(tagged.compactMap(\.artist)))
    for genre in try index.genres() {
        let expected = Set(tagged.filter { $0.genre == genre.name }.compactMap(\.artist))
        #expect(
            Set(try index.artists(TrackFilter(genre: genre.id)).map(\.name)) == expected,
            "\(genre.name)")
    }
    for artist in try index.artists() {
        let expected = Set(tagged.filter { $0.artist == artist.name }.compactMap(\.album))
        #expect(
            Set(try index.albums(TrackFilter(artist: artist.id)).map(\.name)) == expected,
            "\(artist.name)")
        if let genre = try index.genres().first {
            let narrowed = Set(
                tagged.filter { $0.artist == artist.name && $0.genre == genre.name }
                    .compactMap(\.album))
            #expect(
                Set(try index.albums(TrackFilter(genre: genre.id, artist: artist.id)).map(\.name))
                    == narrowed)
        }
    }
    #expect(Set(try index.albums().map(\.name)) == Set(tagged.compactMap(\.album)))
    // An album's artist is its album artist, else its track artist.
    #expect(
        Set(try index.albums().map { "\($0.name)|\($0.artist ?? "")" })
            == Set(
                tagged.compactMap { tags in
                    tags.album.map { "\($0)|\(tags.albumArtist ?? tags.artist ?? "")" }
                }))
    // Each track names its album's artist as the album pane does.
    let albums = Dictionary(uniqueKeysWithValues: try index.albums().map { ($0.id, $0) })
    for row in try index.rows(ids: try index.trackIDs(sortedBy: .path)) {
        guard let id = row.albumID else { continue }
        #expect(row.albumEntryArtist == albums[id]?.artist, "\(row.path)")
    }
}

@Test func unknownStoredKindFailsLoudly() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    try index.database.execute(
        "UPDATE files SET failure_kind = 'gremlins' WHERE failure_kind IS NOT NULL")
    #expect(throws: LibraryError.unknownKind("gremlins")) { try index.fileIssues() }
}

@Test func trailingSlashesComeOffEveryPathButTheRoot() {
    #expect(canonicalPath("/a/b//") == "/a/b")
    #expect(canonicalPath("/a/b") == "/a/b")
    #expect(canonicalPath("/") == "/")
    #expect(isPath("/a/b/c", under: "/a/b/"))
    #expect(pathRange(under: "/a/b//") == "/a/b/"..<"/a/b0")
}

@Test func aPathIDOutsideATransactionTraps() async {
    await #expect(processExitsWith: .failure) {
        let index = try TestLibrary().index()
        _ = try index.pathID("/a.flac", seenAt: 0)
    }
}

/// The library files a folder holds that were moved aside, by name, without their logs and
/// shared memory.
private func movedAside(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .filter {
            $0.hasPrefix("library.sqlite.unreadable-") && !$0.hasSuffix("-wal")
                && !$0.hasSuffix("-shm")
        }
        .sorted()
}

@Test func aLibraryFileThatIsntADatabaseIsMovedAsideAndReported() throws {
    let library = try TestLibrary()
    let folder = library.databaseURL.deletingLastPathComponent()
    let garbage = Data(repeating: 0x5A, count: 8192)
    try garbage.write(to: library.databaseURL)
    try Data("old log".utf8).write(to: URL(fileURLWithPath: library.databaseURL.path + "-wal"))

    // Only the launch open moves it; every other open, a scan's among them, throws.
    #expect {
        try library.scan()
    } throws: { ($0 as? SQLiteError)?.isUnreadableFile == true }
    #expect(try movedAside(in: folder).isEmpty)
    #expect(try Data(contentsOf: library.databaseURL) == garbage)

    let index = try LibraryIndex(at: library.databaseURL, movingAsideIfUnreadable: true)
    #expect(try index.trackCount() == 0)
    let aside = try #require(index.movedAside)
    #expect(try movedAside(in: folder) == [aside.lastPathComponent])
    #expect(FileManager.default.fileExists(atPath: aside.path + "-wal"), "its log goes with it")
    let discards = try index.discards()
    #expect(discards.count == 1)
    #expect(discards.first?.text.contains(aside.path) == true)
    #expect(try Data(contentsOf: aside) == garbage)
    // The new library works and reads as a good one next time.
    #expect(try library.scan().read == library.manifest.files.count)
    #expect(try library.index().discards() == discards)
    #expect(try library.index().movedAside == nil)
}

@Test func onlyTheNewestUnreadableFilesAreKeptEachUnderItsOwnName() throws {
    let library = try TestLibrary()
    let folder = library.databaseURL.deletingLastPathComponent()
    var moved: [URL] = []
    // More moves than are kept, faster than a clock second.
    for _ in 0...LibraryIndex.keptUnreadableFiles {
        try Data(repeating: 0x5A, count: 8192).write(to: library.databaseURL)
        let index = try LibraryIndex(at: library.databaseURL, movingAsideIfUnreadable: true)
        moved.append(try #require(index.movedAside))
    }
    #expect(Set(moved).count == moved.count)
    #expect(
        try movedAside(in: folder)
            == moved.suffix(LibraryIndex.keptUnreadableFiles).map(\.lastPathComponent))
}

/// Files moved aside for a restore are pruned among themselves, and only when asked: a
/// restore prunes once it's in place.
@Test func filesMovedAsideArePrunedByTheirReason() throws {
    let library = try TestLibrary()
    let folder = library.databaseURL.deletingLastPathComponent()
    try Data(repeating: 0x5A, count: 8192).write(to: library.databaseURL)
    let unreadable = try #require(
        LibraryIndex(at: library.databaseURL, movingAsideIfUnreadable: true).movedAside)
    func replaced() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter {
                $0.hasPrefix("library.sqlite.replaced-") && !$0.hasSuffix("-wal")
                    && !$0.hasSuffix("-shm")
            }.sorted()
    }
    var moved: [URL] = []
    for _ in 0...LibraryIndex.keptUnreadableFiles {
        try Data("index".utf8).write(to: library.databaseURL)
        moved.append(
            try LibraryIndex.moveAside(library.databaseURL, reason: "replaced", pruning: false))
    }
    #expect(try replaced() == moved.map(\.lastPathComponent).sorted())
    try LibraryIndex.pruneMovedAside(library.databaseURL, reason: "replaced")
    #expect(
        try replaced()
            == moved.map(\.lastPathComponent).sorted().suffix(LibraryIndex.keptUnreadableFiles))
    #expect(try movedAside(in: folder) == [unreadable.lastPathComponent])
}

@Test func aLockedDatabaseAtLaunchFailsAndIsntMovedAside() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let other = try Database(at: library.databaseURL)
    try other.execute("BEGIN EXCLUSIVE")
    #expect {
        try LibraryIndex(at: library.databaseURL, movingAsideIfUnreadable: true)
    } throws: { error in
        ((error as? SQLiteError)?.code ?? 0) & 0xFF == SQLITE_BUSY
    }
    #expect(try movedAside(in: library.databaseURL.deletingLastPathComponent()).isEmpty)
    try other.execute("ROLLBACK")
    #expect(
        try LibraryIndex(at: library.databaseURL, movingAsideIfUnreadable: true).trackCount()
            == library.readableCount)
}

@Test func aLockedDatabaseFailsAfterTheTimeoutAndThenOpens() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let other = try Database(at: library.databaseURL)
    try other.execute("BEGIN EXCLUSIVE")
    let started = Date()
    #expect {
        try library.scan()
    } throws: { error in
        ((error as? SQLiteError)?.code ?? 0) & 0xFF == SQLITE_BUSY
    }
    #expect(Date().timeIntervalSince(started) >= Double(Database.busyTimeoutMs) / 1000 - 0.5)
    // Readers go on beside the lock; opening the index takes a write lock, so it waits too.
    let reader = try Database(at: library.databaseURL)
    #expect(
        try reader.prepare("SELECT count(*) FROM tracks").map { try $0.int(0) }
            == [library.readableCount])
    try other.execute("ROLLBACK")
    #expect(try library.scan().unchanged == library.manifest.files.count)
}

@Test func twoLaunchOpensAtOnceMoveTheFileAsideOnce() throws {
    let library = try TestLibrary()
    try Data(repeating: 0x5A, count: 8192).write(to: library.databaseURL)
    let url = library.databaseURL
    let results = LockedResults()
    DispatchQueue.concurrentPerform(iterations: 4) { _ in
        results.add(Result { try LibraryIndex(at: url, movingAsideIfUnreadable: true).movedAside })
    }
    let moved = try results.all.map { try $0.get() }
    #expect(moved.compactMap { $0 }.count == 1)
    #expect(try movedAside(in: url.deletingLastPathComponent()).count == 1)
}

private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<URL?, any Error>] = []
    func add(_ result: Result<URL?, any Error>) { lock.withLock { results.append(result) } }
    var all: [Result<URL?, any Error>] { lock.withLock { results } }
}

@Test func aTableNamedToBreakOutOfItsQuotesIsDroppedAlone() throws {
    let library = try TestLibrary()
    let index = try library.index()
    try index.recordPlay("/x.flac", at: 100)
    // Read back from sqlite_master when the index is rebuilt; unquoted, it would end the DROP
    // and drop the plays.
    try index.database.execute("CREATE TABLE \"x\"\"; DROP TABLE plays; --\" (a)")
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'index'")

    let rebuilt = try library.index()
    #expect(
        try rebuilt.database.prepare("SELECT count(*) FROM sqlite_master WHERE name LIKE 'x%'")
            .map { try $0.int(0) } == [0])
    #expect(try rebuilt.database.prepare("SELECT count(*) FROM plays").map { try $0.int(0) } == [1])
}
