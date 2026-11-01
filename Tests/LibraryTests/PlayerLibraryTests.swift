import Darwin
import Foundation
import SQLite
import Testing

@testable import Library

private let now = 2_000_000_000.0
/// Seconds from 1970 to 2001, which Swinsian's dates are assumed to count from.
private let epoch2001 = Date.timeIntervalBetween1970AndReferenceDate

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("player-library-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The schema ADR 0033 assumes, with `leaving` left out: a table name or "table.column".
func swinsianSchemaSQL(leaving omitted: Set<String> = []) -> String {
    swinsianSchema.compactMap { table in
        guard !omitted.contains(table.name) else { return nil }
        let kept = table.columns.filter { !omitted.contains("\(table.name).\($0)") }
        return "CREATE TABLE \(table.name) (\(kept.joined(separator: ", ")));"
    }.joined(separator: "\n")
}

/// A generated Swinsian database at a new path, filled by `sql`.
func swinsianDatabase(_ sql: String, schema: String = swinsianSchemaSQL()) throws -> URL {
    let url = try temporaryFolder().appendingPathComponent("Library.sqlite")
    let database = try Database(at: url)
    try database.execute(schema + sql)
    try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    return url
}

@Test func readsSwinsianTracksMergingRowsForOnePath() throws {
    let url = try swinsianDatabase(
        """
        INSERT INTO track VALUES (1, '/Music/a.flac', 3, 100.5, 50, 2, 0);
        INSERT INTO track VALUES (2, '/Music/b.flac', NULL, NULL, NULL, 0, 1);
        -- The same file again: plays add, the latest play and the highest rating win.
        INSERT INTO track VALUES (3, '/Music/a.flac', 4, 200, 10, 4, 1);
        INSERT INTO track VALUES (4, '/Music/Cafe\u{301}.flac', 1, NULL, NULL, 5, 0);
        INSERT INTO track VALUES (5, '/Music/Café.flac', 2, NULL, NULL, 1, 0);
        """)
    let library = try PlayerLibrary(swinsianAt: url, now: now)
    #expect(library.problems.isEmpty)
    #expect(library.mergedRows == 2)
    #expect(library.tracks.count == 3)
    var a = PlayerTrack(path: "/Music/a.flac")
    a.plays = 7
    a.lastPlayedSeconds = 200 + epoch2001
    a.addedSeconds = 10 + epoch2001
    a.rating = 4
    a.loved = true
    #expect(library.tracks[0] == a)
    var b = PlayerTrack(path: "/Music/b.flac")
    b.loved = true
    #expect(library.tracks[1] == b)
    #expect(library.tracks[2].path == "/Music/Cafe\u{301}.flac")
    #expect(library.tracks[2].plays == 3)
    #expect(library.tracks[2].rating == 5)
}

@Test func readsSwinsianPlaylistsAndMapsTheRulesThatFit() throws {
    let url = try swinsianDatabase(
        """
        INSERT INTO track VALUES (1, '/Music/a.flac', 0, NULL, NULL, 0, 0);
        INSERT INTO track VALUES (2, '/Music/b.flac', 0, NULL, NULL, 0, 0);
        INSERT INTO playlist VALUES (10, 'Mix', 0, NULL);
        INSERT INTO playlisttrack VALUES (10, 2, 1), (10, 1, 2), (10, 99, 3);
        INSERT INTO playlist VALUES (11, 'Loud', 1, 1);
        INSERT INTO smartrule VALUES (11, 1, 'genre', 'contains', 'Rock');
        INSERT INTO smartrule VALUES (11, 2, 'rating', 'greaterthan', 3);
        INSERT INTO smartrule VALUES (11, 3, 'lastplayed', 'inlast', '30');
        INSERT INTO playlist VALUES (12, 'Odd', 1, 0);
        INSERT INTO smartrule VALUES (12, 1, 'kind', 'is', 'MP3');
        INSERT INTO smartrule VALUES (12, 2, 'title', 'matchesregex', 'x');
        INSERT INTO smartrule VALUES (12, 3, 'rating', 'is', 9);
        """)
    let library = try PlayerLibrary(swinsianAt: url, now: now)
    #expect(library.playlists.count == 3)
    #expect(library.playlists[0].kind == .manual)
    #expect(library.playlists[0].paths == ["/Music/b.flac", "/Music/a.flac"])
    #expect(library.problems == [PlayerLibraryProblem("playlist “Mix”", .unknownTrack(99))])
    #expect(
        library.playlists[1].kind
            == .smart(
                SmartRules(
                    match: .all,
                    rules: [
                        SmartRule(.genre, .contains, .text("Rock")),
                        SmartRule(.rating, .greaterThan, .number(3)),
                        SmartRule(.lastPlayed, .inLast, .number(30)),
                    ])))
    guard case .unmapped(let reasons) = library.playlists[2].kind else {
        Issue.record("“Odd” mapped: \(library.playlists[2].kind)")
        return
    }
    #expect(
        reasons == [
            "the field “kind” has no match here", "the comparison “matchesregex” has no match here",
            "a rating is 0 to 5 stars, not 9",
        ])
}

@Test func aMissingTableOrColumnIsNamedAndNothingIsGuessed() throws {
    let url = try swinsianDatabase(
        "", schema: swinsianSchemaSQL(leaving: ["smartrule", "track.loved", "playlist.smart"]))
    let error = #expect(throws: PlayerImportError.self) {
        try PlayerLibrary(swinsianAt: url, now: now)
    }
    #expect(
        error == .missingSchema(["column track.loved", "column playlist.smart", "table smartrule"]))
}

@Test func swinsianValuesOfTheWrongTypeOrRangeAreProblemsNotZeros() throws {
    let url = try swinsianDatabase(
        """
        INSERT INTO track VALUES (1, '/Music/a.flac', 'many', 'yesterday', 0, 80, 2);
        -- A Unix time read as seconds since 2001 lands in 2056: out of range, not a date.
        INSERT INTO track VALUES (2, '/Music/b.flac', -1, 1700000000, NULL, 3, 0);
        INSERT INTO track VALUES (3, NULL, 1, NULL, NULL, 0, 0);
        INSERT INTO track VALUES (4, 'Music/relative.flac', 1, NULL, NULL, 0, 0);
        INSERT INTO track VALUES (5, X'2F61', 1, NULL, NULL, 0, 0);
        """)
    let library = try PlayerLibrary(swinsianAt: url, now: now)
    #expect(library.tracks.map(\.path) == ["/Music/a.flac", "/Music/b.flac"])
    #expect(library.tracks[0].plays == 0)
    #expect(library.tracks[0].rating == nil)
    #expect(library.tracks[0].addedSeconds == epoch2001)
    #expect(library.tracks[1].lastPlayedSeconds == nil)
    #expect(library.tracks[1].rating == 3)
    #expect(
        library.problems.map(\.description) == [
            "track 1: playcount isn't an integer", "track 1: lastplayed isn't a number",
            "track 1: rating 80 is out of range", "track 1: loved isn't true or false",
            "track 2: playcount -1 is out of range",
            "track 2: lastplayed \(1_700_000_000 + epoch2001) is out of range",
            "track 3: has no file path", "track 4: its path isn't absolute",
            "track 5: path isn't a string",
        ])
}

@Test func theLiveDatabaseAndItsLogAreReadOnlyFromACopy() throws {
    let folder = try temporaryFolder()
    let url = folder.appendingPathComponent("Library.sqlite")
    let writer = try Database(at: url)
    try writer.execute(swinsianSchemaSQL())
    try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    // Left in the log while the writer stays open, as Swinsian running would leave it.
    try writer.execute("INSERT INTO track VALUES (1, '/Music/a.flac', 5, NULL, NULL, 0, 0)")
    let before = try [url.path, url.path + Database.walSuffix].map {
        try Data(contentsOf: URL(fileURLWithPath: $0))
    }
    let library = try PlayerLibrary(swinsianAt: url, now: now)
    #expect(library.tracks.map(\.plays) == [5])
    let after = try [url.path, url.path + Database.walSuffix].map {
        try Data(contentsOf: URL(fileURLWithPath: $0))
    }
    #expect(before == after)
}

@Test func aCorruptLinkedOrOversizedDatabaseIsRefused() throws {
    let folder = try temporaryFolder()
    let garbage = folder.appendingPathComponent("garbage.sqlite")
    try Data(repeating: 0x41, count: 8192).write(to: garbage)
    #expect(throws: PlayerImportError.self) { try PlayerLibrary(swinsianAt: garbage, now: now) }
    let link = folder.appendingPathComponent("link.sqlite")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: garbage)
    let linked = #expect(throws: PlayerImportError.self) {
        try PlayerLibrary(swinsianAt: link, now: now)
    }
    #expect(linked.map { "\($0)" }?.contains("can't open") == true)
    // Sparse, so the test writes nothing near the cap.
    let huge = folder.appendingPathComponent("huge.sqlite")
    #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
    #expect(truncate(huge.path, off_t(PlayerLibrary.maximumDatabaseBytes + 1)) == 0)
    let error = #expect(throws: PlayerImportError.self) {
        try PlayerLibrary(swinsianAt: huge, now: now)
    }
    #expect(
        error
            == .tooLarge(
                PlayerLibrary.maximumDatabaseBytes + 1, maximum: PlayerLibrary.maximumDatabaseBytes)
    )
}

// MARK: iTunes

/// A `Library.xml` of `tracks` and `playlists`, as Music writes it.
func iTunesXML(tracks: [[String: Any]], playlists: [[String: Any]] = []) throws -> Data {
    var byID: [String: Any] = [:]
    for track in tracks { byID["\(track["Track ID"] ?? "?")"] = track }
    return try PropertyListSerialization.data(
        fromPropertyList: [
            "Major Version": 1, "Music Folder": "file:///Users/owner/Music/", "Tracks": byID,
            "Playlists": playlists,
        ], format: .xml, options: 0)
}

private func readITunes(_ data: Data) throws -> PlayerLibrary {
    try PlayerLibrary(iTunesXML: data, source: "Library.xml", now: now)
}

@Test func readsITunesTracksAndPlaylists() throws {
    let played = Date(timeIntervalSince1970: 1_600_000_000)
    let data = try iTunesXML(
        tracks: [
            [
                "Track ID": 1, "Name": "A",
                "Location": "file:///Volumes/music/A%20b/Cafe%CC%81.m4a",
                "Play Count": 4, "Skip Count": 2, "Play Date UTC": played,
                "Date Added": Date(timeIntervalSince1970: 1_500_000_000), "Rating": 60,
                "Loved": true,
            ],
            [
                "Track ID": 2, "Location": "file://localhost/Volumes/music/b.mp3", "Rating": 100,
                "Rating Computed": true, "Favorited": true,
            ],
            ["Track ID": 3, "Name": "Streamed", "Track Type": "Remote"],
            ["Track ID": 4, "Location": "http://example.com/c.mp3"],
            ["Track ID": 5, "Location": "file:///Volumes/music/d.mp3", "Play Count": "7"],
        ],
        playlists: [
            ["Name": "Library", "Master": true, "Playlist Items": [["Track ID": 1]]],
            ["Name": "Music", "Distinguished Kind": 4, "Playlist Items": [["Track ID": 1]]],
            ["Name": "Folder", "Folder": true],
            [
                "Name": "Mix",
                "Playlist Items": [
                    ["Track ID": 2], ["Track ID": 1], ["Track ID": 3], ["Track ID": 9],
                ],
            ],
            ["Name": "Recent", "Smart Info": Data([1, 2]), "Playlist Items": [["Track ID": 1]]],
        ])
    let library = try readITunes(data)
    var a = PlayerTrack(path: "/Volumes/music/A b/Cafe\u{301}.m4a")
    a.plays = 4
    a.skips = 2
    a.lastPlayedSeconds = 1_600_000_000
    a.addedSeconds = 1_500_000_000
    a.rating = 3
    a.loved = true
    var b = PlayerTrack(path: "/Volumes/music/b.mp3")
    b.loved = true
    let d = PlayerTrack(path: "/Volumes/music/d.mp3")
    #expect(library.tracks == [a, b, d])
    #expect(library.tracksWithoutFiles == 1)
    #expect(library.builtInPlaylists == 3)
    #expect(library.playlists.map(\.name) == ["Mix", "Recent"])
    #expect(library.playlists[0].paths == [b.path, a.path])
    #expect(library.playlists[0].entriesWithoutFiles == 1)
    #expect(library.playlists[1].kind == .smartAsManual)
    #expect(
        library.problems.map(\.description) == [
            "track 4: its location isn't a file: URL on this Mac",
            "track 5: Play Count isn't an integer",
            "playlist “Mix”: names track 9, which the library doesn't hold",
        ])
}

@Test func aCorruptOrOversizedLibraryXMLIsRefused() throws {
    for bytes in ["<plist><dict><key>Tracks</key>", "<plist><array/></plist>", ""] {
        #expect(throws: PlayerImportError.self) { try readITunes(Data(bytes.utf8)) }
    }
    let noTracks = try PropertyListSerialization.data(
        fromPropertyList: ["Playlists": []], format: .xml, options: 0)
    #expect(throws: PlayerImportError.self) { try readITunes(noTracks) }
    let folder = try temporaryFolder()
    let huge = folder.appendingPathComponent("Library.xml")
    #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
    #expect(truncate(huge.path, off_t(PlayerLibrary.maximumXMLBytes + 1)) == 0)
    let error = #expect(throws: PlayerImportError.self) {
        try PlayerLibrary(iTunesXMLAt: huge, now: now)
    }
    #expect(
        error
            == .tooLarge(PlayerLibrary.maximumXMLBytes + 1, maximum: PlayerLibrary.maximumXMLBytes))
}

@Test func problemsPastTheCapAreCounted() throws {
    let tracks = (1...150).map {
        ["Track ID": $0, "Location": "file:///a/\($0).mp3", "Rating": 300]
    }
    let library = try readITunes(try iTunesXML(tracks: tracks))
    #expect(library.problems.count == PlaylistFile.maximumProblems)
    #expect(library.unlistedProblemCount == 50)
}

@Test func aPrefixReplacesOnlyAWholeFolder() throws {
    let prefix = try #require(PathPrefix(from: "/Volumes/music/", to: "/Volumes/Music"))
    #expect(prefix.apply("/Volumes/music/a.flac") == "/Volumes/Music/a.flac")
    #expect(prefix.apply("/Volumes/music2/a.flac") == "/Volumes/music2/a.flac")
    #expect(prefix.apply("/Volumes/music") == "/Volumes/Music")
    #expect(PathPrefix(from: "", to: "/x") == nil)
}

@Test func anOversizedCellIsRefusedByItsLength() throws {
    let long = String(repeating: "a", count: SmartRule.maximumTextBytes + 1)
    let url = try swinsianDatabase(
        """
        INSERT INTO track VALUES (1, '/\(String(repeating: "p", count: PlayerLibrary.maximumPathBytes))', 1, NULL, NULL, 0, 0);
        INSERT INTO playlist VALUES (1, '\(String(repeating: "n", count: PlayerLibrary.maximumNameBytes + 1))', 0, NULL);
        INSERT INTO playlist VALUES (2, 'Big', 1, 1);
        INSERT INTO smartrule VALUES (2, 1, 'title', 'contains', '\(long)');
        """)
    let library = try PlayerLibrary(swinsianAt: url, now: now)
    #expect(library.tracks.isEmpty)
    #expect(
        library.problems.map(\.description) == [
            "track 1: over \(PlayerLibrary.maximumPathBytes) bytes",
            "playlist 1: over \(PlayerLibrary.maximumNameBytes) bytes",
        ])
    #expect(library.playlists.map(\.kind) == [.unmapped([SmartRule.textTooLong])])
}

@Test func aDatabaseOrLogChangedDuringTheCopyIsRefused() throws {
    for changed in ["", Database.walSuffix] {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("Library.sqlite")
        let writer = try Database(at: url)
        try writer.execute(swinsianSchemaSQL())
        let copy = folder.appendingPathComponent("copy.sqlite").path
        let error = #expect(throws: PlayerImportError.self) {
            try copyAside(url.path, to: copy) { from, to, budget in
                let size = try copyFile(from, to, budget)
                // Swinsian writing between the copy and the check after it.
                let handle = try #require(FileHandle(forWritingAtPath: url.path + changed))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0]))
                try handle.close()
                return size
            }
        }
        #expect(error == .changedWhileCopying(url.path + changed))
    }
}
