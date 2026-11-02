import Foundation
import Testing

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
    // The owner's Swinsian import missed a DSF file in a watched folder: the scanner never
    // reads one, so no prefix or folder could match it.
    let dsf = library.root + "/dsd/01-When It's Sleepy Time Down South.dsf"
    let gone = library.root + "/gone.flac"
    let plan = try index.importPlan(player([track(dsf), track(gone)]), prefix: nil)
    #expect(plan.unmatched == [gone] && plan.unreadFormat == [dsf])
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
