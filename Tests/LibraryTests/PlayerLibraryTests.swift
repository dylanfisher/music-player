import Darwin
import Fixtures
import Foundation
import SQLite
import Testing

@testable import Library

private let now = 2_000_000_000.0
/// Seconds from 1970 to 2001, which Swinsian's dates count from.
private let epoch2001 = Date.timeIntervalBetween1970AndReferenceDate

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("player-library-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// INSERTs of `rows` into the columns the reader reads of `swinsianSchema[table]`: 0 for
/// tracks, 1 for playlists, 2 for their entries.
func swinsianRows(_ table: Int, _ rows: String...) -> String {
    let read = swinsianSchema[table]
    return rows.map {
        "INSERT INTO \(read.name) (\(read.columns.joined(separator: ", "))) VALUES \($0);\n"
    }.joined()
}

/// A generated Swinsian database at a new path, of the real schema with `sql` run after it.
func swinsianDatabase(_ sql: String) throws -> URL {
    let url = try temporaryFolder().appendingPathComponent("Library.sqlite")
    let database = try Database(at: url)
    try database.execute(swinsianSchemaSQL + sql)
    try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    return url
}

/// `bytes` as an SQL blob literal.
func blobSQL(_ bytes: [UInt8]) -> String {
    "X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'"
}

@Test func readsSwinsianTracksMergingRowsForOnePath() throws {
    let url = try swinsianDatabase(
        swinsianRows(
            0, "(1, '/Music/a.flac', 3, 100.5, 50, 2, 0)",
            "(2, '/Music/b.flac', NULL, 0, NULL, NULL, 1)",
            // The same file again: plays add, the latest play and the highest rating win.
            "(3, '/Music/a.flac', 4, 200, 10, 4, NULL)",
            "(4, '/Music/Cafe\u{301}.flac', 1, 0.0, NULL, 5, 0)",
            "(5, '/Music/Café.flac', 2, NULL, NULL, 1, 0)"))
    let library = try PlayerLibrary(swinsianAt: url, now: now)
    #expect(library.problems.isEmpty)
    #expect(library.mergedRows == 2)
    #expect(library.tracks.count == 3)
    var a = PlayerTrack(path: "/Music/a.flac")
    a.plays = 7
    a.lastPlayedSeconds = 200 + epoch2001
    a.addedSeconds = 10 + epoch2001
    a.rating = 4
    #expect(library.tracks[0] == a)
    // A last played of 0 is never.
    var b = PlayerTrack(path: "/Music/b.flac")
    b.loved = true
    #expect(library.tracks[1] == b)
    #expect(library.tracks[2].path == "/Music/Cafe\u{301}.flac")
    #expect(library.tracks[2].plays == 3)
    #expect(library.tracks[2].rating == 5)
    #expect(library.tracks[2].lastPlayedSeconds == nil)
}

@Test func theOwners32ExtraRowsForOnePathMergeAndAreCounted() throws {
    let rows = (1...40).map {
        "(\($0), '/Music/\($0 <= 8 ? $0 : $0 % 8 + 1).flac', 1, NULL, NULL, NULL, NULL)"
    }
    let url = try swinsianDatabase(rows.map { swinsianRows(0, $0) }.joined())
    let library = try PlayerLibrary(swinsianAt: url, now: now)
    #expect(library.tracks.count == 8)
    #expect(library.mergedRows == 32)
    #expect(library.tracks.map(\.plays).reduce(0, +) == 40)
}

@Test func halfStarsRoundUpAndAreMarked() throws {
    // Swinsian stores a rating as REAL in an INTEGER column, so a whole one reads as an integer.
    let url = try swinsianDatabase(
        swinsianRows(
            0, "(1, '/a', 0, NULL, NULL, 0.5, NULL)", "(2, '/b', 0, NULL, NULL, 3.0, NULL)",
            "(3, '/c', 0, NULL, NULL, 4.5, NULL)", "(4, '/d', 0, NULL, NULL, NULL, NULL)",
            "(5, '/e', 0, NULL, NULL, 0, NULL)", "(6, '/f', 0, NULL, NULL, 2.25, NULL)",
            "(7, '/g', 0, NULL, NULL, 5.5, NULL)", "(8, '/h', 0, NULL, NULL, 'x', NULL)",
            // A whole 4 beats a rounded 3.5, and is whole.
            "(9, '/i', 0, NULL, NULL, 3.5, NULL)", "(10, '/i', 0, NULL, NULL, 4, NULL)",
            "(11, '/j', 0, NULL, NULL, 1.5, NULL)", "(12, '/j', 0, NULL, NULL, 1, NULL)"))
    let library = try PlayerLibrary(swinsianAt: url, now: now)
    #expect(library.tracks.map(\.rating) == [1, 3, 5, nil, nil, nil, nil, nil, 4, 2])
    #expect(
        library.tracks.map(\.ratingRounded)
            == [true, false, true, false, false, false, false, false, false, true])
    #expect(
        library.problems.map(\.description) == [
            "track 6: rating 2.25 is out of range", "track 7: rating 5.5 is out of range",
            "track 8: rating isn't a number",
        ])
}

@Test func readsSwinsianPlaylistsInOrderSkippingFoldersAndLimits() throws {
    let rules = try swinsianPredicateArchive(#"genre CONTAINS[c] "Rock""#)
    let url = try swinsianDatabase(
        swinsianRows(
            0, "(1, '/Music/a.flac', 0, NULL, NULL, 0, 0)",
            "(2, '/Music/b.flac', 0, NULL, NULL, 0, 0)")
            + swinsianRows(
                1, "(10, 'Mix', 0, NULL, NULL, NULL)",
                "(11, 'Loud', 1, \(blobSQL(rules)), NULL, 0)",
                "(12, 'Folder', 0, NULL, 1, NULL)", "(13, 'Top', 1, \(blobSQL(rules)), 0, 1)",
                "(14, 'Empty', 1, NULL, NULL, NULL)")
            + swinsianRows(2, "(10, 2, 1)", "(10, 1, 2)", "(10, 99, 3)"))
    let library = try PlayerLibrary(swinsianAt: url, now: now)
    #expect(library.playlists.map(\.name) == ["Mix", "Loud", "Top", "Empty"])
    #expect(library.builtInPlaylists == 1)
    #expect(library.playlists[0].kind == .manual)
    #expect(library.playlists[0].paths == ["/Music/b.flac", "/Music/a.flac"])
    #expect(library.problems == [PlayerLibraryProblem("playlist “Mix”", .unknownTrack(99))])
    #expect(
        library.playlists[1].kind
            == .smart(SmartRules(match: .all, rules: [SmartRule(.genre, .contains, .text("Rock"))]))
    )
    #expect(
        library.playlists[2].kind
            == .unmapped(["it's limited to some of its tracks, which isn't read"]))
    #expect(
        library.playlists[3].kind
            == .unmapped([SwinsianPredicate.Archive.notAnArchive.description]))
}

@Test func eachOfTheOwnersRuleShapesMaps() throws {
    func genre(_ comparison: SmartComparison, _ text: String) -> SmartRule {
        SmartRule(.genre, comparison, .text(text))
    }
    func all(_ rules: SmartRule...) -> PlayerPlaylist.Kind {
        .smart(SmartRules(match: .all, rules: rules))
    }
    let expected: [PlayerPlaylist.Kind] = [
        all(SmartRule(.dateAdded, .inLast, .number(1))),
        all(SmartRule(.dateAdded, .inLast, .number(7))),
        all(SmartRule(.dateAdded, .inLast, .number(30))),
        all(SmartRule(.bitRate, .greaterThan, .number(1000))),
        all(SmartRule(.lastPlayed, .inLast, .number(7))),
        all(genre(.startsWith, "Genre A - ")), all(genre(.startsWith, "Genre B - ")),
        all(genre(.startsWith, "Genre C - ")), all(genre(.startsWith, "Genre D - ")),
        all(genre(.startsWith, "Genre E - ")),
        all(
            genre(.startsWith, "Genre E - "), genre(.contains, "Style F"),
            genre(.doesNotContain, "Style G"), genre(.doesNotContain, "Style H")),
        .smart(
            SmartRules(
                match: .any,
                rules: [
                    SmartRule(.fileType, .is, .text("dsf")),
                    SmartRule(.fileType, .is, .text("dsd")),
                ])),
        all(SmartRule(.sampleRate, .greaterThan, .number(44100))),
        all(genre(.startsWith, "Genre F - ")),
        all(SmartRule(.grouping, .isNot, .text(""))),
        all(genre(.startsWith, "Genre A - "), genre(.contains, "Style I")),
        all(genre(.startsWith, "Genre A - "), genre(.contains, "Style J")),
        all(genre(.startsWith, "Genre A - "), genre(.contains, "Style J K")),
    ]
    #expect(swinsianPredicateShapes.count == 18)
    for (format, kind) in zip(swinsianPredicateShapes, expected) {
        #expect(SwinsianPredicate.kind(try swinsianPredicateArchive(format)) == kind, "\(format)")
    }
}

@Test func predicatesOurRulesCantSayAreListedWithWhy() throws {
    let cases: [(String, String)] = [
        (
            #"genre BEGINSWITH "Rock""#,
            "compares with case or other options that have no match here"
        ),
        (#"genre ENDSWITH[c] "Rock""#, "the comparison has no match here"),
        (#"title CONTAINS[c] "Love""#, "the field “title” has no match here"),
        (
            #"dateAdded > CAST(700000000, "NSDate")"#,
            "only a date within the last so many days has a match here"
        ),
        (
            #"dateAdded > CAST(CAST(now(), "NSNumber") - 3600, "NSDate")"#,
            "the time isn't a whole number of days"
        ),
        (#"groupingLength > 2"#, "only a grouping longer than 0 has a match here"),
        (#"sampleRate > "fast""#, "the value isn't what the field takes"),
        (#"ANY genre CONTAINS[c] "Rock""#, "not a key compared with a value"),
    ]
    for (format, reason) in cases {
        let predicate = NSPredicate(format: format)
        let kind = SwinsianPredicate.kind(try swinsianPredicateArchive(format))
        #expect(kind == .unmapped(["“\(predicate.predicateFormat)”: \(reason)"]), "\(format)")
    }
    #expect(
        SwinsianPredicate.kind(try swinsianPredicateArchive(#"NOT genre BEGINSWITH[c] "Rock""#))
            == .unmapped([
                #"“genre BEGINSWITH[c] "Rock"”: the comparison's negation has no match here"#
            ]))
    #expect(
        SwinsianPredicate.kind(try swinsianPredicateArchive("TRUEPREDICATE"))
            == .unmapped(["“TRUEPREDICATE” isn't a comparison or AND, OR or NOT"]))
    // All of an any can't be one list of rules; NOT (a AND b) is NOT a OR NOT b, which can.
    let mixed = #"genre CONTAINS[c] "a" AND (genre CONTAINS[c] "b" OR genre CONTAINS[c] "c")"#
    #expect(
        SwinsianPredicate.kind(try swinsianPredicateArchive(mixed))
            == .unmapped([
                #"“genre CONTAINS[c] "b" OR genre CONTAINS[c] "c"”: all and any mixed in one playlist"#
            ]))
    let negated = #"NOT (genre CONTAINS[c] "a" AND fileType ==[c] "mp3")"#
    #expect(
        SwinsianPredicate.kind(try swinsianPredicateArchive(negated))
            == .smart(
                SmartRules(
                    match: .any,
                    rules: [
                        SmartRule(.genre, .doesNotContain, .text("a")),
                        SmartRule(.fileType, .isNot, .text("mp3")),
                    ])))
}

@Test func aHostilePredicateArchiveIsRefusedBeforeItsDecoded() throws {
    func reason(_ archive: Archive) -> PlayerPlaylist.Kind { .unmapped([archive.description]) }
    typealias Archive = SwinsianPredicate.Archive
    #expect(
        SwinsianPredicate.kind([UInt8](repeating: 0, count: SwinsianPredicate.maximumBytes + 1))
            == reason(.tooLarge))
    #expect(SwinsianPredicate.kind(Array("bplist00junk".utf8)) == reason(.notAnArchive))
    // An archive of a class off the list: a URL.
    let url = [UInt8](
        try NSKeyedArchiver.archivedData(
            withRootObject: NSURL(fileURLWithPath: "/"), requiringSecureCoding: true))
    guard case .unmapped(let refused) = SwinsianPredicate.kind(url) else {
        Issue.record("a URL mapped")
        return
    }
    #expect(refused.first?.hasPrefix("its rules couldn't be read: ") == true, "\(refused)")
    var deep: NSPredicate = NSPredicate(format: #"genre CONTAINS[c] "a""#)
    for _ in 0..<SwinsianPredicate.maximumDepth {
        deep = NSCompoundPredicate(notPredicateWithSubpredicate: deep)
    }
    #expect(
        SwinsianPredicate.kind(
            [UInt8](
                try NSKeyedArchiver.archivedData(withRootObject: deep, requiringSecureCoding: true))
        )
            == reason(.tooDeep))
    // Written as XML, where a reference is a CF$UID dictionary.
    func archive(_ objects: String, count: Int = 0) -> [UInt8] {
        let filler = String(repeating: "<string>x</string>", count: count)
        return Array(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>$archiver</key><string>NSKeyedArchiver</string>
            <key>$version</key><integer>100000</integer>
            <key>$top</key><dict><key>root</key><dict><key>CF$UID</key><integer>1</integer></dict></dict>
            <key>$objects</key><array><string>$null</string>\(objects)\(filler)</array>
            </dict></plist>
            """.utf8)
    }
    let cycle =
        "<dict><key>NSSubpredicates</key><dict><key>CF$UID</key><integer>1</integer></dict></dict>"
    #expect(SwinsianPredicate.kind(archive(cycle)) == reason(.cycle))
    #expect(
        SwinsianPredicate.kind(
            archive("<string>x</string>", count: SwinsianPredicate.maximumObjects))
            == reason(.tooManyObjects))
    let dangling = "<dict><key>a</key><dict><key>CF$UID</key><integer>9</integer></dict></dict>"
    #expect(SwinsianPredicate.kind(archive(dangling)) == reason(.notAnArchive))
}

@Test func aMissingTableOrColumnIsNamedAndNothingIsGuessed() throws {
    let url = try swinsianDatabase(
        """
        DROP TABLE playlisttrack;
        ALTER TABLE track DROP COLUMN favourite;
        ALTER TABLE playlist DROP COLUMN smartpredicate;
        """)
    let error = #expect(throws: PlayerImportError.self) {
        try PlayerLibrary(swinsianAt: url, now: now)
    }
    #expect(
        error
            == .missingSchema([
                "column track.favourite", "column playlist.smartpredicate", "table playlisttrack",
            ]))
}

@Test func swinsianValuesOfTheWrongTypeOrRangeAreProblemsNotZeros() throws {
    let url = try swinsianDatabase(
        swinsianRows(
            0, "(1, '/Music/a.flac', 'many', 'yesterday', 0, 80, 2)",
            // A Unix time read as seconds since 2001 lands in 2056: out of range, not a date.
            "(2, '/Music/b.flac', -1, 1700000000, NULL, 3, 0)",
            "(3, NULL, 1, NULL, NULL, 0, 0)", "(4, 'Music/relative.flac', 1, NULL, NULL, 0, 0)",
            "(5, X'2F61', 1, NULL, NULL, 0, 0)"))
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
            "track 1: rating 80 is out of range", "track 1: favourite isn't true or false",
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
    try writer.execute(swinsianSchemaSQL)
    try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    // Left in the log while the writer stays open, as Swinsian running would leave it.
    try writer.execute(swinsianRows(0, "(1, '/Music/a.flac', 5, NULL, NULL, 0, 0)"))
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
    let predicate = NSPredicate(format: "genre CONTAINS[c] %@", long)
    let rules = [UInt8](
        try NSKeyedArchiver.archivedData(withRootObject: predicate, requiringSecureCoding: true))
    let url = try swinsianDatabase(
        swinsianRows(
            0,
            "(1, '/\(String(repeating: "p", count: PlayerLibrary.maximumPathBytes))', 1, NULL, NULL, 0, 0)"
        )
            + swinsianRows(
                1,
                "(1, '\(String(repeating: "n", count: PlayerLibrary.maximumNameBytes + 1))', 0, NULL, NULL, NULL)",
                "(2, 'Big', 1, \(blobSQL(rules)), NULL, NULL)",
                "(3, 'Huge', 1, zeroblob(\(SwinsianPredicate.maximumBytes + 1)), NULL, NULL)"))
    let library = try PlayerLibrary(swinsianAt: url, now: now)
    #expect(library.tracks.isEmpty)
    #expect(
        library.problems.map(\.description) == [
            "track 1: over \(PlayerLibrary.maximumPathBytes) bytes",
            "playlist 1: over \(PlayerLibrary.maximumNameBytes) bytes",
        ])
    #expect(
        library.playlists.map(\.kind) == [
            .unmapped([
                "“\(predicate.predicateFormat.prefix(SwinsianPredicate.maximumQuotedCharacters))…”: "
                    + SmartRule.textTooLong
            ]),
            .unmapped([SwinsianPredicate.Archive.tooLarge.description]),
        ])
}

@Test func aDatabaseOrLogChangedDuringTheCopyIsRefused() throws {
    for changed in ["", Database.walSuffix] {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("Library.sqlite")
        let writer = try Database(at: url)
        try writer.execute(swinsianSchemaSQL)
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
