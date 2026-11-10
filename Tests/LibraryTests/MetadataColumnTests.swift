import Fixtures
import Foundation
import Metadata
import Settings
import TagWriter
import Testing

@testable import Library

/// A scanned library of one FLAC file per entry of `files`, named by its key and tagged with its
/// value, with a cover in each file `covered` names; and each file's row by name.
private func taggedLibrary(
    _ files: [String: [String: String]], covered: Set<String> = []
) throws -> (index: LibraryIndex, rows: [String: TrackRow], root: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("columns-\(UUID().uuidString)")
    let root = directory.appendingPathComponent("Music")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (name, tags) in files {
        let cover = covered.contains(name) ? Data(repeating: 7, count: 300) : nil
        try taggedFLAC(tags: tags, cover: cover).write(
            to: root.appendingPathComponent("\(name).flac"))
    }
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    let summary = try LibraryScanner(databaseURL: databaseURL).scan(
        WatchedFolder(path: root.path, kind: .local))
    #expect(summary.read == files.count && summary.failed == 0)
    let index = try LibraryIndex(at: databaseURL)
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    return (index, Dictionary(uniqueKeysWithValues: rows.map { ($0.fileName, $0) }), root)
}

/// The file names in the order `column` sorts them.
private func names(
    _ index: LibraryIndex, _ column: TrackColumn, ascending: Bool = true,
    _ filter: TrackFilter = TrackFilter()
) throws -> [String] {
    try index.rows(ids: try index.trackIDs(filter, sortedBy: column, ascending: ascending))
        .map { ($0.fileName as NSString).deletingPathExtension }
}

@Test func theOwnersNewColumnsHoldTheirValuesAndSortByThem() throws {
    let (index, rows, root) = try taggedLibrary(
        [
            "a": ["GROUPING": "Strings", "CATALOGNUMBER": "CAT-2", "TRACKNUMBER": "2/9"],
            "b": ["GROUPING": "brass", "CATALOGNUMBER": "cat-3", "TRACKNUMBER": "1/9"],
            "c": ["CATALOGNUMBER": "CAT-1", "TRACKNUMBER": "3", "COMMENT": "a longer file"],
        ], covered: ["b"])
    let a = try #require(rows["a.flac"])
    #expect(a.grouping == "Strings")
    #expect(a.catalogNumber == "CAT-2")
    #expect(a.trackNumber == 2 && a.trackTotal == 9)
    #expect(a.fileType == "FLAC")
    let path = root.appendingPathComponent("a.flac").path
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect(a.sizeBytes == (attributes[.size] as? Int))
    #expect(
        a.modifiedSeconds == (attributes[.modificationDate] as? Date)?.timeIntervalSince1970)
    #expect(
        a.createdSeconds == (attributes[.creationDate] as? Date)?.timeIntervalSince1970)
    #expect(a.createdSeconds != nil)
    // 4410 frames at 44.1 kHz is 0.1 s; the art doesn't count.
    let b = try #require(rows["b.flac"])
    #expect(b.art?.byteCount == 300)
    #expect(b.bitRateKbps == Double(b.sizeBytes - 300) * 8 / 0.1 / 1000)
    #expect(a.bitRateKbps == Double(a.sizeBytes) * 8 / 0.1 / 1000)

    // Case doesn't change the order of text the tags hold as written; a missing value is first.
    #expect(try names(index, .grouping) == ["c", "b", "a"])
    #expect(try names(index, .catalogNumber) == ["c", "a", "b"])
    #expect(try names(index, .catalogNumber, ascending: false) == ["b", "a", "c"])
    #expect(try names(index, .trackOfTotal) == ["b", "a", "c"])
    #expect(try names(index, .trackOfTotal) == (try names(index, .trackNumber)))
    #expect(try names(index, .art) == ["a", "c", "b"])
    #expect(try names(index, .size) == (try names(index, .bitRate)))
    #expect(try names(index, .size).last == "b")
    #expect(try names(index, .fileName, ascending: false) == ["c", "b", "a"])
}

/// Each added column, the Vorbis key that sets it, and three values in ascending order.
private let addedColumns: [(TrackColumn, String, [String])] = [
    (.composer, "COMPOSER", ["Bach", "liszt", "Mozart"]),
    (.conductor, "CONDUCTOR", ["Abbado", "Karajan", "solti"]),
    (.lyricist, "LYRICIST", ["A", "B", "C"]),
    (.work, "WORK", ["Mass", "Requiem", "Symphony"]),
    (.movementNumber, "MOVEMENT", ["1", "2", "10"]),
    (.movementName, "MOVEMENTNAME", ["Adagio", "allegro", "Presto"]),
    (.originalDate, "ORIGINALDATE", ["1959", "1969-09-26", "1971"]),
    (.trackTotal, "TRACKTOTAL", ["5", "9", "12"]),
    (.discTotal, "DISCTOTAL", ["1", "2", "3"]),
    (.discOfTotal, "DISCNUMBER", ["1", "2", "3"]),
    (.discSubtitle, "DISCSUBTITLE", ["Live", "Remixes", "Studio"]),
    (.bpm, "BPM", ["90", "120", "174"]),
    (.key, "KEY", ["A", "Cm", "F#"]),
    (.publisher, "LABEL", ["Blue Note", "ECM", "Impulse"]),
    (.mood, "MOOD", ["Ambient", "dub Techno", "House, Techno"]),
    (.barcode, "BARCODE", ["1", "2", "3"]),
    // As numbers: as text, 10 would come before 9.
    (.discogsReleaseID, "DISCOGS_RELEASE_ID", ["9", "10", "1234"]),
    (.discogsMasterID, "DISCOGS_MASTER_ID", ["m9", "m10", "m1234"]),
    (.copyright, "COPYRIGHT", ["A", "B", "C"]),
    (.encoder, "ENCODEDBY", ["A", "B", "C"]),
    (.comment, "COMMENT", ["A", "B", "C"]),
    (.description, "DESCRIPTION", ["A", "B", "C"]),
]

@Test func everyAddedColumnSortsByItsValue() throws {
    // The files' names sort in another order than the values, so a tie break can't pass.
    let order = ["z", "x", "y"]
    for (column, key, values) in addedColumns {
        let files = Dictionary(
            uniqueKeysWithValues: zip(order, values).map { ($0, [key: $1]) })
        let (index, _, _) = try taggedLibrary(files)
        #expect(try names(index, column) == order, "\(column)")
        #expect(try names(index, column, ascending: false) == order.reversed(), "\(column)")
    }
}

@Test func flagsAndFileColumnsSort() throws {
    let (index, rows, _) = try taggedLibrary(
        ["one": ["COMPILATION": "1"], "two": [:], "three": [:]])
    #expect(rows["one.flac"]?.compilation == true)
    #expect(try names(index, .compilation).last == "one")
    #expect(try names(index, .channels).count == 3)
    #expect(try names(index, .fileType).count == 3)
    #expect(try names(index, .dateCreated).count == 3)
    #expect(try names(index, .dateModified).count == 3)
    let id = try #require(rows["two.flac"]).id
    try index.toggle(.liked, trackIDs: [id])
    #expect(try names(index, .loved).last == "two")
    #expect(try index.rows(ids: [id]).first?.loved == true)
}

@Test func lovingTogglesAndUnlovesOnlyWhenAllAreLoved() throws {
    let (index, rows, _) = try taggedLibrary(["a": [:], "b": [:]])
    let a = try #require(rows["a.flac"]).id
    let b = try #require(rows["b.flac"]).id
    func loved() throws -> [Bool] { try index.rows(ids: [a, b]).map(\.loved) }
    try index.toggle(.liked, trackIDs: [a])
    #expect(try loved() == [true, false])
    try index.toggle(.liked, trackIDs: [a, b])
    #expect(try loved() == [true, true])
    try index.toggle(.liked, trackIDs: [a, b])
    #expect(try loved() == [false, false])
}

@Test func aLikeAndADislikeReplaceEachOtherAndToggleOff() throws {
    let (index, rows, _) = try taggedLibrary(["a": [:], "b": [:]])
    let a = try #require(rows["a.flac"]).id
    let b = try #require(rows["b.flac"]).id
    func opinions() throws -> [TrackOpinion?] { try [a, b].map(index.opinion(of:)) }
    try index.toggle(.disliked, trackIDs: [a])
    #expect(try opinions() == [.disliked, nil])
    try index.toggle(.liked, trackIDs: [a, b])
    #expect(try opinions() == [.liked, .liked])
    #expect(try index.rows(ids: [a, b]).map(\.loved) == [true, true])
    try index.toggle(.disliked, trackIDs: [a])
    #expect(try opinions() == [.disliked, .liked])
    #expect(try index.rows(ids: [a]).first?.loved == false)
    try index.toggle(.disliked, trackIDs: [a])
    #expect(try opinions() == [nil, .liked])
}

@Test func dislikedHasItsOwnRebuildThatKeepsTheLovedTracks() throws {
    let (index, rows, root) = try taggedLibrary(["a": [:], "b": [:]])
    let databaseURL = root.deletingLastPathComponent().appendingPathComponent("library.sqlite")
    let a = try #require(rows["a.flac"]).id
    let b = try #require(rows["b.flac"]).id
    try index.toggle(.liked, trackIDs: [a])
    try index.toggle(.disliked, trackIDs: [b])
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'disliked'")
    let rebuilt = try LibraryIndex(at: databaseURL)
    #expect(try rebuilt.opinion(of: a) == .liked)
    #expect(try rebuilt.opinion(of: b) == nil)
    #expect(try rebuilt.discards().first?.text.hasSuffix("(rows: disliked 1)") == true)
}

@Test func lovedSurvivesAnIndexRebuildAndItsOwnRebuildKeepsTheOtherStats() throws {
    let (index, rows, root) = try taggedLibrary(["a": [:]])
    let databaseURL = root.deletingLastPathComponent().appendingPathComponent("library.sqlite")
    let id = try #require(rows["a.flac"]).id
    try index.toggle(.liked, trackIDs: [id])
    try index.setRating(3, trackIDs: [id])
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'index'")

    var rebuilt = try LibraryIndex(at: databaseURL)
    #expect(try rebuilt.trackCount() == 0)
    _ = try LibraryScanner(databaseURL: databaseURL).scan(
        WatchedFolder(path: root.path, kind: .local))
    #expect(try rebuilt.rows(ids: [id]).first?.loved == true)

    try rebuilt.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'loved'")
    rebuilt = try LibraryIndex(at: databaseURL)
    let row = try #require(try rebuilt.rows(ids: [id]).first)
    #expect(!row.loved)
    #expect(row.rating == 3)
    #expect(try rebuilt.discards().first?.text.hasSuffix("(rows: loved 1)") == true)
}

@Test func theAddedRuleFieldsMatch() throws {
    let (index, rows, _) = try taggedLibrary(
        [
            "fast": ["GROUPING": "Dance", "BPM": "174"],
            "slow": ["GROUPING": "Ambient", "BPM": "70"],
        ])
    try index.toggle(.liked, trackIDs: [try #require(rows["slow.flac"]).id])
    func matching(_ rule: SmartRule) throws -> [String] {
        let id = try index.createPlaylist(
            named: "rule", rules: SmartRules(match: .all, rules: [rule]))
        let found = try names(index, .path, TrackFilter(source: .playlist(id)))
        try index.deletePlaylist(id)
        return found
    }
    #expect(try matching(SmartRule(.grouping, .contains, .text("danc"))) == ["fast"])
    #expect(try matching(SmartRule(.bpm, .greaterThan, .number(100))) == ["fast"])
    #expect(try matching(SmartRule(.loved, .is, .number(1))) == ["slow"])
    #expect(try matching(SmartRule(.size, .lessThan, .number(1))) == ["fast", "slow"])
    #expect(try matching(SmartRule(.dateModified, .inLast, .number(1))) == ["fast", "slow"])
    #expect(try matching(SmartRule(.fileType, .is, .text("flac"))) == ["fast", "slow"])
    #expect(SmartRule(.loved, .is, .number(2)).problem != nil)
}

@Test func aRuleOnTheDiscogsIDsPicksTheTracksWithOrWithoutOne() throws {
    let (index, rows, _) = try taggedLibrary(
        [
            "tagged": ["DISCOGS_RELEASE_ID": "1234", "DISCOGS_MASTER_ID": "m56"],
            "untagged": [:],
        ])
    #expect(rows["tagged.flac"]?.discogsReleaseID == "1234")
    #expect(rows["tagged.flac"]?.discogsMasterID == "m56")
    #expect(rows["untagged.flac"]?.discogsReleaseID == nil)
    func matching(_ rule: SmartRule) throws -> [String] {
        let id = try index.createPlaylist(
            named: "rule", rules: SmartRules(match: .all, rules: [rule]))
        let found = try names(index, .path, TrackFilter(source: .playlist(id)))
        try index.deletePlaylist(id)
        return found
    }
    #expect(try matching(SmartRule(.discogsReleaseID, .is, .text(""))) == ["untagged"])
    #expect(try matching(SmartRule(.discogsReleaseID, .isNot, .text(""))) == ["tagged"])
    #expect(try matching(SmartRule(.discogsMasterID, .is, .text("m56"))) == ["tagged"])
    #expect(try matching(SmartRule(.discogsReleaseID, .startsWith, .text("12"))) == ["tagged"])
}

// MARK: Grouping by album artist

/// A compilation without an album artist, an album whose guest is the track artist, and an
/// album of the same title by an artist with no album artist tag.
private func groupedLibrary() throws -> (index: LibraryIndex, rows: [String: TrackRow]) {
    let (index, rows, _) = try taggedLibrary([
        "comp1": ["ALBUM": "Hits", "ARTIST": "Xavier", "COMPILATION": "1", "TRACKNUMBER": "2"],
        "comp2": ["ALBUM": "Hits", "ARTIST": "Yvonne", "COMPILATION": "1", "TRACKNUMBER": "1"],
        "band1": [
            "ALBUM": "Live", "ARTIST": "Singer and Guest", "ALBUMARTIST": "Band",
            "TRACKNUMBER": "2",
        ],
        "band2": ["ALBUM": "Live", "ARTIST": "Band", "ALBUMARTIST": "Band", "TRACKNUMBER": "1"],
        "solo": ["ALBUM": "Live", "ARTIST": "Solo"],
    ])
    return (index, rows)
}

private let grouped = TrackFilter(groupByAlbumArtist: true)

@Test func theArtistPaneListsAlbumArtistsWhenGroupedAndTrackArtistsWhenNot() throws {
    let (index, _) = try groupedLibrary()
    #expect(try index.artists(grouped).map(\.name) == ["Band", "Solo", variousArtists])
    #expect(
        try index.artists().map(\.name) == ["Band", "Singer and Guest", "Solo", "Xavier", "Yvonne"])
    let band = try #require(try index.artists(grouped).first)
    var filter = grouped
    filter.artist = band.id
    #expect(try names(index, .trackNumber, filter) == ["band2", "band1"])
    filter.groupByAlbumArtist = false
    #expect(try names(index, .trackNumber, filter) == ["band2"])
    let various = try #require(try index.artists(grouped).last)
    filter = grouped
    filter.artist = various.id
    #expect(try index.albums(filter).map(\.name) == ["Hits"])
}

@Test func aCompilationTaggedVariousArtistsListsWithThoseWithout() throws {
    let (index, _, _) = try taggedLibrary([
        "tagged": ["ALBUM": "One", "ARTIST": "A", "ALBUMARTIST": variousArtists],
        "untagged": ["ALBUM": "Two", "ARTIST": "B", "COMPILATION": "1"],
    ])
    let artists = try index.artists(grouped)
    #expect(artists.map(\.name) == [variousArtists])
    var filter = grouped
    filter.artist = artists[0].id
    #expect(try index.albums(filter).map(\.name) == ["One", "Two"])
}

@Test func theAlbumPaneNamesTheArtistOfAlbumsWhoseTitlesRepeat() throws {
    let (index, _) = try groupedLibrary()
    // The two albums called Live tie on their title, so their order is the scan's.
    #expect(
        Set(albumTitles(try index.albums()))
            == ["Hits", "Live \u{2014} Band", "Live \u{2014} Solo"])
    let repeated = [
        BrowserEntry(id: 1, name: "Hits", artist: nil, isCompilation: true),
        BrowserEntry(id: 2, name: "Hits", artist: "Band"),
        BrowserEntry(id: 3, name: "Hits", artist: nil),
    ]
    #expect(
        albumTitles(repeated) == ["Hits \u{2014} \(variousArtists)", "Hits \u{2014} Band", "Hits"])
}

@Test func onlyACompilationWithoutAnArtistIsVariousArtistsInTheAlbumPane() throws {
    let (index, _, _) = try taggedLibrary([
        "comp": ["ALBUM": "Hits", "ARTIST": "A", "COMPILATION": "1"],
        "nobody": ["ALBUM": "Mix"],
        "band": ["ALBUM": "Hits", "ARTIST": "Band"],
        "other": ["ALBUM": "Mix", "ARTIST": "Band"],
    ])
    let albums = try index.albums()
    #expect(albums.filter(\.isCompilation).map(\.name) == ["Hits"])
    #expect(
        Set(albumTitles(albums))
            == [
                "Hits \u{2014} \(variousArtists)", "Hits \u{2014} Band", "Mix", "Mix \u{2014} Band",
            ])
}

@Test func groupedSortsKeepEachAlbumTogetherInTrackOrder() throws {
    let (index, _) = try groupedLibrary()
    #expect(
        try names(index, .artist, grouped) == ["band2", "band1", "solo", "comp2", "comp1"])
    #expect(
        try names(index, .album, grouped) == ["comp2", "comp1", "band2", "band1", "solo"])
    #expect(
        try names(index, .artist, ascending: false, grouped)
            == ["comp2", "comp1", "solo", "band2", "band1"])
    // Ungrouped, Artist is the track artist, which splits the albums.
    #expect(try names(index, .artist) == ["band2", "band1", "solo", "comp1", "comp2"])
}

@Test func trackNamesCarryTheArtistTheSortUses() throws {
    let (index, _) = try groupedLibrary()
    func sortArtists(_ filter: TrackFilter) throws -> [String?] {
        try index.trackNames(filter, sortedBy: .artist).map(\.sortArtist)
    }
    #expect(
        try sortArtists(grouped) == ["Band", "Band", "Solo", variousArtists, variousArtists])
    #expect(
        try sortArtists(TrackFilter())
            == ["Band", "Singer and Guest", "Solo", "Xavier", "Yvonne"])
}

/// Measures as analysis stores them, with these four values.
private func measured(
    cutoffHz: Double?, effectiveBits: Int?, dynamicRange: Int?, truePeak: Double?
) -> FileMeasures {
    FileMeasures(
        formatID: "flac", sampleRateHz: 44_100, storedBits: 16, channels: 2, isFloat: false,
        durationSeconds: 0.1, cutoffHz: cutoffHz,
        cutoffSteepnessDBPerKHz: cutoffHz.map { _ in 150 }, effectiveBits: effectiveBits,
        identicalChannels: false, peakDBFS: -1, truePeakDBTP: truePeak, clippedRuns: 0,
        dynamicRange: dynamicRange)
}

@Test func theMeasureColumnsAndFieldsReadWhatAnalysisStoredForTheFileAsItIs() throws {
    let (index, rows, _) = try taggedLibrary(["a": [:], "b": [:], "c": [:], "d": [:]])
    func row(_ name: String) throws -> TrackRow { try #require(rows["\(name).flac"]) }
    func stamp(_ name: String) throws -> FileStamp {
        let row = try row(name)
        return FileStamp(sizeBytes: row.sizeBytes, modifiedSeconds: row.modifiedSeconds)
    }
    try index.storeMeasures(
        measured(cutoffHz: 16_015.6, effectiveBits: 16, dynamicRange: 12, truePeak: -0.3),
        path: try row("a").path, stamp: try stamp("a"))
    try index.storeMeasures(
        measured(cutoffHz: nil, effectiveBits: 14, dynamicRange: 5, truePeak: 0.4),
        path: try row("b").path, stamp: try stamp("b"))
    // Made from the file before it changed: the index's stamp no longer matches.
    var older = try stamp("d")
    older.modifiedSeconds -= 1
    try index.storeMeasures(
        measured(cutoffHz: 15_000, effectiveBits: 8, dynamicRange: 3, truePeak: 1),
        path: try row("d").path, stamp: older)

    let read = Dictionary(
        uniqueKeysWithValues: try index.rows(ids: try index.trackIDs(sortedBy: .path)).map {
            (($0.fileName as NSString).deletingPathExtension, $0)
        })
    let a = try #require(read["a"])
    #expect(a.cutoffHz == 16_015.6 && a.effectiveBits == 16)
    #expect(a.dynamicRange == 12 && a.truePeakDBTP == -0.3)
    let b = try #require(read["b"])
    #expect(b.cutoffHz == nil && b.effectiveBits == 14 && b.truePeakDBTP == 0.4)
    for name in ["c", "d"] {
        let unmeasured = try #require(read[name])
        #expect(unmeasured.cutoffHz == nil && unmeasured.effectiveBits == nil, "\(name)")
        #expect(unmeasured.dynamicRange == nil && unmeasured.truePeakDBTP == nil, "\(name)")
    }

    // Not analyzed sorts first, as a missing value does.
    #expect(try names(index, .effectiveBits) == ["c", "d", "b", "a"])
    #expect(try names(index, .dynamicRange, ascending: false) == ["a", "b", "c", "d"])
    #expect(try names(index, .truePeak, ascending: false) == ["b", "a", "c", "d"])
    #expect(try names(index, .cutoff).last == "a")

    func smart(_ rule: SmartRule) throws -> [String] {
        let id = try index.createPlaylist(
            named: "\(rule.field)", rules: SmartRules(match: .all, rules: [rule]))
        return try names(index, .path, TrackFilter(source: .playlist(id)))
    }
    #expect(try smart(SmartRule(.cutoff, .lessThan, .number(17_000))) == ["a"])
    #expect(try smart(SmartRule(.cutoff, .is, .number(16_015))) == ["a"])
    #expect(try smart(SmartRule(.effectiveBits, .lessThan, .number(16))) == ["b"])
    #expect(try smart(SmartRule(.dynamicRange, .greaterThan, .number(6))) == ["a"])
    // A true peak compares as measured, and may be negative.
    #expect(try smart(SmartRule(.truePeak, .greaterThan, .number(0))) == ["b"])
    #expect(try smart(SmartRule(.truePeak, .lessThan, .number(0))) == ["a"])
    #expect(try smart(SmartRule(.truePeak, .greaterThan, .number(-1))) == ["a", "b"])
    #expect(SmartRule(.dynamicRange, .greaterThan, .number(-1)).problem != nil)
}

/// A fixture library of its own, big enough to hold clean MP4 and MP3 files, which the shared
/// one of 40 doesn't.
private let everyFormatLibrary = Result { () throws -> (URL, FixtureManifest) in
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/library-every-format-tests")
    _ = try generateFixtures(count: 100, in: root)
    return (root, try loadManifest(in: root))
}

@Test func moodIsReadIntoTheIndexFromEveryTagFormat() throws {
    let (source, manifest) = try everyFormatLibrary.get()
    // A clean file of each kind of tag block, copied and given a mood by the tag writer.
    let kinds: [(FixtureFile.Container, FixtureFile.TagFormat)] = [
        (.flac, .vorbisComment), (.mp4, .mp4), (.mp3, .id3v24),
    ]
    let files = try kinds.map { container, format in
        try #require(
            manifest.files.first {
                $0.container == container && $0.malformation == nil && $0.tagFormats == [format]
            }, Comment(rawValue: format.rawValue))
    }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mood-\(UUID().uuidString)")
    let root = directory.appendingPathComponent("Music")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var edits: [(path: String, edit: TagEdit)] = []
    for (number, file) in files.enumerated() {
        let copy = root.appendingPathComponent(
            "\(number).\((file.path as NSString).pathExtension)")
        try FileManager.default.copyItem(at: source.appendingPathComponent(file.path), to: copy)
        var edit = TagEdit()
        edit.values[.mood] = "Dub Techno, House \(number)"
        edits.append((copy.path, edit))
    }
    let journal = TagUndoJournal(dataDirectory: directory.appendingPathComponent("journal"))
    let report = TagWriter(journal: journal).write(edits)
    #expect(report.failures.isEmpty && report.changed.count == files.count)
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    _ = try LibraryScanner(databaseURL: databaseURL).scan(
        WatchedFolder(path: root.path, kind: .local))
    let index = try LibraryIndex(at: databaseURL)
    for (number, edit) in edits.enumerated() {
        let row = try #require(try index.track(path: edit.path))
        #expect(row.mood == "Dub Techno, House \(number)", Comment(rawValue: files[number].path))
    }
}
