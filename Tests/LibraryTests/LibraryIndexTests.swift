import Foundation
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
    let discards = try rebuilt.takeDiscards()
    #expect(discards.count == 1)
    #expect(
        discards.first?.hasSuffix(
            "(rows: history 1, paths 1, plays 1, ratings 1)") == true, "\(discards)")
    #expect(try rebuilt.takeDiscards().isEmpty)
    // Empty stats lose nothing, so nothing is recorded.
    try rebuilt.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'stats'")
    #expect(try library.index().takeDiscards().isEmpty)
}

@Test func aRecordedDiscardSurvivesAnotherRebuild() throws {
    let library = try TestLibrary()
    let index = try library.index()
    try index.recordSkip("/x.flac")
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'stats'")
    let rebuilt = try library.index()
    try rebuilt.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'index'")
    #expect(try library.index().takeDiscards().count == 1)
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
    try database.execute(SchemaPart.stats.sql)
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
    for column in TrackColumn.allCases {
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
