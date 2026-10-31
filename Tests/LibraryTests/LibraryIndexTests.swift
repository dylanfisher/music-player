import Foundation
import Testing

@testable import Fixtures
@testable import Library
@testable import SQLite

private func ratingPaths(_ index: LibraryIndex) throws -> [String] {
    try index.database.prepare("SELECT path FROM ratings").map { try $0.text(0) }
}

@Test func indexRebuildKeepsTheStats() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    try index.database.prepare("INSERT INTO ratings (path, rating) VALUES (?, ?)").run(
        library.path(library.manifest.files[0]), 80)
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'index'")

    let rebuilt = try library.index()
    #expect(try rebuilt.trackCount() == 0)
    #expect(try ratingPaths(rebuilt) == [library.path(library.manifest.files[0])])
    // Nothing is known, so the rescan reads every file again and finds the same paths.
    #expect(try library.scan().read == library.manifest.files.count)
    #expect(try rebuilt.trackCount() == library.readableCount)
}

@Test func statsThatDontMatchAreDiscarded() throws {
    let library = try TestLibrary()
    let index = try library.index()
    try index.database.prepare("INSERT INTO ratings (path, rating) VALUES (?, ?)").run("/x", 1)
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'stats'")
    #expect(try ratingPaths(try library.index()).isEmpty)
}

@Test func statsTablesListsWhatTheStatsSQLCreates() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("stats-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try Database(at: directory.appendingPathComponent("stats.sqlite"))
    try database.execute(SchemaPart.stats.sql)
    let tables = try database.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").map {
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
    for column in TrackSortColumn.allCases {
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
    let byArtist = Set(try index.trackIDs(sortedBy: .title, matching: word.uppercased()))
    let known = try index.knownFiles(under: library.root)
    for file in tagged where file.tags?.artist == artist {
        #expect(byArtist.contains(try #require(known[library.path(file)]).id), "\(file.path)")
    }

    let albumWord = String(try #require(album.split(separator: " ").last))
    let both = try index.trackIDs(sortedBy: .title, matching: "\(word) \(albumWord)")
    #expect(!both.isEmpty)
    #expect(Set(both).isSubset(of: byArtist))
    #expect(try index.trackIDs(sortedBy: .title, matching: "zzqx").isEmpty)
    #expect(
        try index.trackIDs(sortedBy: .title, matching: "\" ' - ( *").count == library.readableCount)
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
        #expect(Set(try index.artists(genre: genre.id).map(\.name)) == expected, "\(genre.name)")
    }
    for artist in try index.artists() {
        let expected = Set(tagged.filter { $0.artist == artist.name }.compactMap(\.album))
        #expect(Set(try index.albums(artist: artist.id).map(\.name)) == expected, "\(artist.name)")
        if let genre = try index.genres().first {
            let narrowed = Set(
                tagged.filter { $0.artist == artist.name && $0.genre == genre.name }
                    .compactMap(\.album))
            #expect(
                Set(try index.albums(artist: artist.id, genre: genre.id).map(\.name)) == narrowed)
        }
    }
    #expect(Set(try index.albums().map(\.name)) == Set(tagged.compactMap(\.album)))
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
    #expect(trimmingTrailingSlashes("/a/b//") == "/a/b")
    #expect(trimmingTrailingSlashes("/a/b") == "/a/b")
    #expect(trimmingTrailingSlashes("/") == "/")
    #expect(isPath("/a/b/c", under: "/a/b/"))
    #expect(pathRange(under: "/a/b//") == "/a/b/"..<"/a/b0")
}
