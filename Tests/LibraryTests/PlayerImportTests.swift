import Foundation
import Testing

@testable import Fixtures
@testable import Library

/// A scanned test library, its index, and its tracks' rows sorted by path.
private func scanned() throws -> (TestLibrary, LibraryIndex, [TrackRow]) {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    return (library, index, try index.rows(ids: try index.trackIDs(sortedBy: .path)))
}

private func player(_ tracks: [PlayerTrack], playlists: [PlayerPlaylist] = []) -> PlayerLibrary {
    var library = PlayerLibrary(player: .swinsian, source: "/swinsian/Library.sqlite")
    for track in tracks { _ = library.add(track) }
    library.playlists = playlists
    return library
}

private func track(
    _ path: String, plays: Int = 0, skips: Int = 0, played: Double? = nil, added: Double? = nil,
    rating: Int? = nil, loved: Bool = false
) -> PlayerTrack {
    var track = PlayerTrack(path: path)
    track.plays = plays
    track.skips = skips
    track.lastPlayedSeconds = played
    track.addedSeconds = added
    track.rating = rating
    track.loved = loved
    return track
}

@Test func thePreviewCountsEachFieldAndWritesNothing() throws {
    let (_, index, rows) = try scanned()
    try index.setRating(2, trackIDs: [rows[1].id])
    try index.recordPlay(rows[0].path, at: 3_000)
    let gone = "/Elsewhere/gone.flac"
    let library = player([
        track(rows[0].path, plays: 5, skips: 1, played: 2_000, added: 10, rating: 4, loved: true),
        track(rows[1].path, plays: 2, played: 9_000, rating: 5),
        track(gone, plays: 9),
    ])
    let plan = try index.importPlan(library, prefix: nil)
    #expect(plan.matched == 2 && plan.unmatched == [gone])
    #expect(plan.playsAdded == 7 && plan.tracksGainingPlays == 2)
    #expect(plan.skipsAdded == 1 && plan.tracksGainingSkips == 1)
    // Ours was played later for the first, theirs later for the second.
    #expect(plan.lastPlayed == 1)
    #expect(plan.dateAdded == 1)
    #expect(plan.ratings == 1 && plan.ratingsKept == 1)
    #expect(plan.loved == 1)
    let after = try index.rows(ids: [rows[0].id, rows[1].id])
    #expect(after.map(\.playCount) == [1, 0])
    #expect(after.map(\.rating) == [0, 2])
}

@Test func applyingMergesEachFieldByItsRuleAndAddsNoHistory() throws {
    let (_, index, rows) = try scanned()
    try index.setRating(2, trackIDs: [rows[1].id])
    try index.recordPlay(rows[0].path, at: 3_000)
    let library = player([
        track(rows[0].path, plays: 5, skips: 1, played: 2_000, added: 10, rating: 4, loved: true),
        track(rows[1].path, plays: 2, played: 9_000, rating: 5),
    ])
    _ = try index.applyImport(library, prefix: nil)
    let after = try index.rows(ids: [rows[0].id, rows[1].id])
    #expect(after.map(\.playCount) == [6, 2])
    #expect(after.map(\.skipCount) == [1, 0])
    #expect(after.map(\.lastPlayedSeconds) == [3_000, 9_000])
    #expect(after[0].addedSeconds == 10 && after[1].addedSeconds == rows[1].addedSeconds)
    #expect(after.map(\.rating) == [4, 2])
    #expect(after.map(\.loved) == [true, false])
    #expect(try index.loggedPlayCount() == 1)
}

@Test func rebuildingTheImportCountsTakesTheirPlaysOutAndTheNextImportPutsThemBack() throws {
    let (testLibrary, index, rows) = try scanned()
    try index.recordPlay(rows[0].path, at: 3_000)
    let library = player([track(rows[0].path, plays: 5), track(rows[1].path, plays: 2)])
    _ = try index.applyImport(library, prefix: nil)
    // Counts doubled by an earlier build, where the recorded totals no longer say how.
    try index.database.execute("UPDATE plays SET play_count = play_count + 7")
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'imports'")
    let rebuilt = try testLibrary.index()
    let ids = [rows[0].id, rows[1].id]
    #expect(try rebuilt.rows(ids: ids).map(\.playCount) == [1, 0])
    #expect(try rebuilt.discards().first?.text.hasSuffix("(rows: imported_plays 2)") == true)
    _ = try rebuilt.applyImport(library, prefix: nil)
    #expect(try rebuilt.rows(ids: ids).map(\.playCount) == [6, 2])
    #expect(try rebuilt.loggedPlayCount() == 1)
}

@Test func rebuildingTheImportCountsTakesTheirSkipsOutAndKeepsTheOnesRecordedHere() throws {
    let (testLibrary, index, rows) = try scanned()
    try index.recordSkip(rows[0].path)
    let library = player([track(rows[0].path, plays: 1, skips: 5)])
    _ = try index.applyImport(library, prefix: nil)
    #expect(try index.rows(ids: [rows[0].id]).first?.skipCount == 6)
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'imports'")
    let rebuilt = try testLibrary.index()
    #expect(try rebuilt.rows(ids: [rows[0].id]).first?.skipCount == 1)
    _ = try rebuilt.applyImport(library, prefix: nil)
    #expect(try rebuilt.rows(ids: [rows[0].id]).first?.skipCount == 6)
}

@Test func historyListsOnlyTracksWithARecordedPlay() throws {
    let (_, index, rows) = try scanned()
    _ = try index.applyImport(
        player([track(rows[0].path, plays: 5, played: 2_000), track(rows[1].path, plays: 1)]),
        prefix: nil)
    let history = TrackFilter(source: .history)
    #expect(try index.trackIDs(history, sortedBy: .lastPlayed, ascending: false).isEmpty)
    #expect(try index.artists(history).isEmpty)
    try index.recordPlay(rows[0].path, at: 3_000)
    try index.recordPlay(rows[2].path, at: 4_000)
    #expect(
        try index.trackIDs(history, sortedBy: .lastPlayed, ascending: false)
            == [rows[2].id, rows[0].id])
    #expect(!(try index.artists(history).isEmpty))
}

@Test func anImportedLoveLeavesADislikedTrackDisliked() throws {
    let (_, index, rows) = try scanned()
    try index.toggle(.disliked, trackIDs: [rows[0].id])
    let plan = try index.applyImport(player([track(rows[0].path, loved: true)]), prefix: nil)
    #expect(plan.loved == 0)
    #expect(try index.opinion(of: rows[0].id) == .disliked)
}

@Test func aSecondImportAddsOnlyWhatGrew() throws {
    let (_, index, rows) = try scanned()
    let first = player(
        [track(rows[0].path, plays: 5, skips: 2, played: 100, rating: 3, loved: true)],
        playlists: [PlayerPlaylist(name: "Mix", kind: .manual, paths: [rows[0].path])])
    _ = try index.applyImport(first, prefix: nil)
    let again = try index.importPlan(first, prefix: nil)
    #expect(!again.changesSomething)
    #expect(again.playsAdded == 0 && again.lastPlayed == 0 && again.loved == 0)
    #expect(again.existingPlaylists == ["Mix"])
    _ = try index.applyImport(first, prefix: nil)
    #expect(try index.rows(ids: [rows[0].id])[0].playCount == 5)
    #expect(try index.playlists().count == 1)
    // A newer copy of the same library, played three more times since.
    let later = player([track(rows[0].path, plays: 8, skips: 2, played: 200)])
    let plan = try index.applyImport(later, prefix: nil)
    #expect(plan.playsAdded == 3 && plan.skipsAdded == 0)
    #expect(try index.rows(ids: [rows[0].id])[0].playCount == 8)
}

/// The last plays the imports recorded, by path ID, as `player` and seconds.
private func lastPlays(_ index: LibraryIndex) throws -> [Int64: [String: Int64]] {
    var plays: [Int64: [String: Int64]] = [:]
    try index.database.prepare(
        "SELECT path_id, player, played_at FROM \(importedLastPlaysTable)"
    ).query { plays[try $0.int64(0), default: [:]][try $0.text(1)] = try $0.int64(2) }
    return plays
}

@Test func anImportKeepsItsOwnLastPlayApartFromLastPlayed() throws {
    let (_, index, rows) = try scanned()
    // Played here after the other player last played it: Last Played is ours.
    try index.recordPlay(rows[0].path, at: 3_000)
    let library = player([
        track(rows[0].path, plays: 5, played: 2_000.7),
        track(rows[1].path, plays: 2, played: 9_000),
        // A date with no play counted isn't one of its plays.
        track(rows[2].path, played: 9_500),
    ])
    let plan = try index.applyImport(library, prefix: nil)
    #expect(plan.datedLastPlays == 2)
    #expect(
        try lastPlays(index) == [
            rows[0].id: ["swinsian": 2_000], rows[1].id: ["swinsian": 9_000],
        ])
    #expect(try index.rows(ids: [rows[0].id])[0].lastPlayedSeconds == 3_000)
    // The same library again changes nothing; a newer copy moves the last play later.
    #expect(!(try index.importPlan(library, prefix: nil).changesSomething))
    let later = try index.applyImport(
        player([track(rows[0].path, plays: 6, played: 4_000)]), prefix: nil)
    #expect(later.datedLastPlays == 1)
    #expect(try lastPlays(index)[rows[0].id] == ["swinsian": 4_000])
}

@Test func theLastPlaysTableFillsFromLastPlayedWhereNoRealPlayIsAtOrAfterIt() throws {
    let (library, index, rows) = try scanned()
    _ = try index.applyImport(
        player([
            track(rows[0].path, plays: 5, played: 2_000),
            track(rows[1].path, plays: 2, played: 9_000),
            track(rows[2].path, plays: 1, played: 7_000),
        ]), prefix: nil)
    var itunes = PlayerLibrary(player: .iTunes, source: "/music/Library.xml")
    _ = itunes.add(track(rows[2].path, plays: 1, played: 6_000))
    _ = try index.applyImport(itunes, prefix: nil)
    // Played here after the import, so Last Played is that real play's.
    try index.recordPlay(rows[1].path, at: 9_500)
    // A database from before the table, which knew only the counts and Last Played.
    try index.database.execute(
        """
        DROP TABLE \(importedLastPlaysTable);
        DELETE FROM schema_identity WHERE part = '\(SchemaPart.importedLastPlays.rawValue)'
        """)
    let reopened = try library.index()
    // rows[2]'s Last Played could be either player's, so it's left without a date.
    #expect(try lastPlays(reopened) == [rows[0].id: ["swinsian": 2_000]])
    #expect(try reopened.rows(ids: [rows[0].id])[0].playCount == 5)
    #expect(try reopened.discards().isEmpty)
    // The counts were kept, so an import of the same library adds no play, only the dates.
    let again = try reopened.applyImport(
        player([
            track(rows[0].path, plays: 5, played: 2_000),
            track(rows[1].path, plays: 2, played: 9_000),
        ]), prefix: nil)
    #expect(again.playsAdded == 0 && again.datedLastPlays == 1)
    #expect(try lastPlays(reopened)[rows[1].id] == ["swinsian": 9_000])
}

@Test func aPrefixAndNFCMatchTracksFromAnotherMount() throws {
    let (library, index, rows) = try scanned()
    let moved = { (path: String) in
        "/Volumes/old" + path.dropFirst(library.root.count)
    }
    let source = player([
        track(moved(rows[0].path).precomposedStringWithCanonicalMapping, plays: 1),
        track(moved(rows[1].path), plays: 1),
    ])
    #expect(try index.importPlan(source, prefix: nil).matched == 0)
    let prefix = PathPrefix(from: "/Volumes/old/", to: library.root)
    let plan = try index.importPlan(source, prefix: prefix)
    #expect(plan.matched == 2 && plan.unmatched.isEmpty)
}

@Test func aMissInAFormatTheScannerSkipsIsListedApart() throws {
    let (library, index, _) = try scanned()
    // The scanner never reads an Ogg file, so no prefix or folder could match it.
    let ogg = library.root + "/ogg/01-When It's Sleepy Time Down South.ogg"
    let gone = library.root + "/gone.flac"
    let plan = try index.importPlan(player([track(ogg), track(gone)]), prefix: nil)
    #expect(plan.unmatched == [gone] && plan.unreadFormat == [ogg])
}

/// The owner's watched `dsd` folder: a DSD128 DSF and a DSD64 DSDIFF, written under `root`.
private func dsdAlbum(under root: String) throws -> [String] {
    let folder = root + "/dsd/Armstrong, Louis - 1952 - Mack The Knife (2017 DSD 128)"
    try FileManager.default.createDirectory(
        atPath: folder, withIntermediateDirectories: true)
    let files = [
        (folder + "/01 Mack The Knife.dsf", 5_644_800, false),
        (folder + "/02 Back O' Town Blues.dff", 2_822_400, true),
    ]
    for (path, rate, isDFF) in files {
        let channels = (0..<2).map { dsdTone(samples: 8 * 4096, rateHz: rate, channel: $0) }
        try
            (isDFF
            ? dffFile(rateHz: rate, channels: channels) : dsfFile(rateHz: rate, channels: channels))
            .write(to: URL(fileURLWithPath: path, isDirectory: false))
    }
    return files.map(\.0)
}

/// A Swinsian database listing `paths`, each played `plays` times.
private func swinsian(_ paths: [String], plays: Int) throws -> PlayerLibrary {
    let rows = paths.enumerated().map { index, path in
        "(\(index + 1), '\(path.replacingOccurrences(of: "'", with: "''"))', \(plays), NULL, NULL, NULL, 0)"
    }
    return try PlayerLibrary(
        swinsianAt: try swinsianDatabase(rows.map { swinsianRows(0, $0) }.joined()),
        now: 2_000_000_000)
}

@Test func aSwinsianMissInDSDMatchesOnceTheScannerReadsDSD() throws {
    let library = try TestLibrary()
    let paths = try dsdAlbum(under: library.root)
    _ = try library.scan()
    let index = try library.index()
    let plan = try index.applyImport(try swinsian(paths, plays: 3), prefix: nil)
    #expect(plan.matched == 2)
    #expect(plan.unmatched.isEmpty && plan.unreadFormat.isEmpty)
    let rows = try index.rows(ids: try index.trackIDs(atPaths: paths).compactMap { $0 })
    #expect(rows.map(\.sampleRateHz) == [5_644_800, 2_822_400])
    #expect(rows.map(\.codec) == ["dsd", "dsd"])
    #expect(rows.map(\.playCount) == [3, 3])
}

@Test func aDSDMissUnderAnOldMountIsLocatedNotListedAsUnread() throws {
    let library = try TestLibrary()
    let paths = try dsdAlbum(under: library.root)
    _ = try library.scan()
    let index = try library.index()
    let old = paths.map { "/Volumes/music" + $0.dropFirst(library.root.count) }
    let plan = try index.applyImport(try swinsian(old, plays: 2), prefix: nil)
    #expect(plan.unmatched == old && plan.unreadFormat.isEmpty)

    let prefix = PathPrefix(locating: old[0], in: library.root + "/dsd")
    #expect(prefix == PathPrefix(from: "/Volumes/music/dsd", to: library.root + "/dsd"))
    let written = try index.applyImport(plan.misses(under: prefix.from), prefix: prefix)
    #expect(written.matched == 2 && written.unmatched.isEmpty)
    let ids = try index.trackIDs(atPaths: paths).compactMap { $0 }
    #expect(try index.rows(ids: ids).map(\.playCount) == [2, 2])
}

@Test func locatingMapsTheFolderWithThePickedNameOrTheFilesOwn() {
    let miss = "/Volumes/music/dsd/A/01.dsf"
    #expect(
        PathPrefix(locating: miss, in: "/Volumes/music-1/dsd/")
            == PathPrefix(from: "/Volumes/music/dsd", to: "/Volumes/music-1/dsd"))
    #expect(
        PathPrefix(locating: miss, in: "/Volumes/music-1/A")
            == PathPrefix(from: "/Volumes/music/dsd/A", to: "/Volumes/music-1/A"))
    #expect(
        PathPrefix(locating: miss, in: "/Users/me/Renamed")
            == PathPrefix(from: "/Volumes/music/dsd/A", to: "/Users/me/Renamed"))
}

@Test func locatingUnderARenamedFolderAboveMapsTheFolderTheFileIsFoundUnder() {
    let miss = "/Volumes/music/dsd/A/01.dsf"
    let found = "/Volumes/music-1/dsd/A/01.dsf"
    #expect(
        PathPrefix(locating: miss, in: "/Volumes/music-1", fileExists: { $0 == found })
            == PathPrefix(from: "/Volumes/music", to: "/Volumes/music-1"))
    // Found beats the name: a folder above named like the pick isn't the one replaced.
    #expect(
        PathPrefix(
            locating: "/Volumes/A/dsd/A/01.dsf", in: "/Volumes/new/A",
            fileExists: { $0 == "/Volumes/new/A/dsd/A/01.dsf" })
            == PathPrefix(from: "/Volumes/A", to: "/Volumes/new/A"))
}

@Test func locatedMissesMatchAgainUnderTheFolderPicked() throws {
    let (library, index, rows) = try scanned()
    let old = { (path: String) in "/Volumes/old" + path.dropFirst(library.root.count) }
    let source = player(
        [track(old(rows[0].path), plays: 2), track(old(rows[1].path), plays: 3)],
        playlists: [PlayerPlaylist(name: "Mix", kind: .manual, paths: [old(rows[0].path)])])
    let plan = try index.applyImport(source, prefix: nil)
    #expect(plan.unmatched.count == 2)

    let prefix = PathPrefix(
        locating: old(rows[0].path), in: (rows[0].path as NSString).deletingLastPathComponent)
    let misses = plan.misses(under: prefix.from)
    #expect(misses.playlists.isEmpty)
    #expect(misses.tracks.map(\.path).contains(old(rows[0].path)))
    let written = try index.applyImport(misses, prefix: prefix)
    #expect(!written.unmatched.contains(prefix.apply(old(rows[0].path))))
    #expect(try index.rows(ids: [rows[0].id])[0].playCount == 2)
}

@Test func playlistsComeAcrossInOrderAndExistingNamesAreSkipped() throws {
    let (_, index, rows) = try scanned()
    _ = try index.createPlaylist(named: "Old")
    let rules = SmartRules(match: .any, rules: [SmartRule(.playCount, .greaterThan, .number(3))])
    let library = player(
        [track(rows[0].path), track(rows[1].path)],
        playlists: [
            PlayerPlaylist(
                name: "Mix", kind: .manual,
                paths: [rows[1].path, rows[0].path, rows[1].path, "/gone.flac"],
                entriesWithoutFiles: 1),
            PlayerPlaylist(name: "old", kind: .manual, paths: [rows[0].path]),
            PlayerPlaylist(name: "Played", kind: .smart(rules)),
            PlayerPlaylist(name: "Odd", kind: .unmapped(["x"])),
            PlayerPlaylist(name: "Recent", kind: .smartAsManual, paths: [rows[0].path]),
        ])
    let plan = try index.applyImport(library, prefix: nil)
    #expect(plan.existingPlaylists == ["old"])
    #expect(plan.playlists.map(\.name) == ["Mix", "Played", "Recent"])
    #expect(plan.playlists[0].missing == 2 && plan.playlists[0].repeated == 1)
    #expect(plan.playlists[2].wasSmart)
    let made = Dictionary(uniqueKeysWithValues: try index.playlists().map { ($0.name, $0) })
    #expect(try index.playlistTrackIDs(made["Mix"]!.id) == [rows[1].id, rows[0].id])
    #expect(made["Played"]?.kind == .smart(rules))
    #expect(try index.playlistTrackIDs(made["Recent"]!.id) == [rows[0].id])
    #expect(made["Odd"] == nil)
}

@Test func aSwinsianDatabaseImportsEndToEnd() throws {
    let (_, index, rows) = try scanned()
    let path = { (row: TrackRow) in row.path.replacingOccurrences(of: "'", with: "''") }
    let url = try swinsianDatabase(
        swinsianRows(
            0, "(1, '\(path(rows[0]))', 3, NULL, NULL, 4, 1)",
            "(2, '\(path(rows[0]))', 2, NULL, NULL, 4.5, 0)")
            + swinsianRows(1, "(1, 'Mix', 0, NULL, NULL, NULL)") + swinsianRows(2, "(1, 2, 1)"))
    let library = try PlayerLibrary(swinsianAt: url)
    let plan = try index.applyImport(library, prefix: nil)
    #expect(plan.mergedRows == 1 && plan.playsAdded == 5 && plan.ratings == 1)
    #expect(plan.roundedRatings == 1)
    let row = try index.rows(ids: [rows[0].id])[0]
    #expect(row.playCount == 5 && row.rating == 5 && row.loved)
}
