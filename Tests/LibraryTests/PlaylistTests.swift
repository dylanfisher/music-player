import Foundation
import Settings
import Testing

@testable import Library
@testable import SQLite

/// A scanned test library, its index, and its track IDs and paths in path order.
private func scanned() throws -> (TestLibrary, LibraryIndex, [Int64], [String]) {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let ids = try index.trackIDs(sortedBy: .path)
    return (library, index, ids, try index.rows(ids: ids).map(\.path))
}

private func shownPaths(_ index: LibraryIndex, _ source: BrowserSource, by column: TrackColumn)
    throws -> [String]
{
    let ids = try index.trackIDs(TrackFilter(source: source), sortedBy: column)
    return try index.rows(ids: ids).map(\.path)
}

@Test func aManualPlaylistKeepsItsOrderAndEachTrackOnce() throws {
    let (_, index, ids, paths) = try scanned()
    let id = try index.createPlaylist(named: "Mix")
    #expect(try index.addToPlaylist(id, trackIDs: [ids[3], ids[1], ids[3]]) == 2)
    #expect(try index.addToPlaylist(id, trackIDs: [ids[1], ids[0]]) == 1)
    #expect(try index.playlistTrackIDs(id) == [ids[3], ids[1], ids[0]])
    #expect(
        try shownPaths(index, .playlist(id), by: .playlistOrder) == [paths[3], paths[1], paths[0]])
    #expect(try shownPaths(index, .playlist(id), by: .path) == [paths[0], paths[1], paths[3]])

    try index.movePlaylistEntries(id, trackIDs: [ids[0], ids[3]], before: ids[1])
    #expect(try index.playlistTrackIDs(id) == [ids[3], ids[0], ids[1]])
    try index.movePlaylistEntries(id, trackIDs: [ids[3]], before: nil)
    #expect(try index.playlistTrackIDs(id) == [ids[0], ids[1], ids[3]])

    try index.removeFromPlaylist(id, trackIDs: [ids[1]])
    #expect(try index.playlistTrackIDs(id) == [ids[0], ids[3]])
    #expect(try index.trackCount() == paths.count)
}

@Test func playlistsAreListedByNameAndRenamedAndDeleted() throws {
    let (_, index, ids, _) = try scanned()
    let b = try index.createPlaylist(named: "b")
    let a = try index.createPlaylist(
        named: "A", rules: SmartRules(match: .all, rules: [.init(.title, .contains, .text("x"))]))
    #expect(try index.playlists().map(\.id) == [a, b])
    try index.renamePlaylist(b, to: "0")
    #expect(try index.playlists().map(\.name) == ["0", "A"])
    _ = try index.addToPlaylist(b, trackIDs: [ids[0]])
    try index.deletePlaylist(b)
    #expect(try index.playlists().map(\.id) == [a])
    #expect(
        try index.database.prepare("SELECT count(*) FROM playlist_entries").map { try $0.int(0) }
            == [0])
    #expect(throws: LibraryError.unknownPlaylist(b)) { try index.renamePlaylist(b, to: "x") }
    #expect(throws: LibraryError.unknownPlaylist(b)) {
        try index.trackIDs(TrackFilter(source: .playlist(b)), sortedBy: .title)
    }
}

@Test func aSmartPlaylistTakesNoTracksByHandAndAManualOneNoRules() throws {
    let (_, index, ids, _) = try scanned()
    let rules = SmartRules(match: .all, rules: [])
    let smart = try index.createPlaylist(named: "Smart", rules: rules)
    let manual = try index.createPlaylist(named: "Manual")
    #expect(throws: LibraryError.smartPlaylist("Smart")) {
        try index.addToPlaylist(smart, trackIDs: [ids[0]])
    }
    #expect(throws: LibraryError.unknownPlaylist(manual)) { try index.setRules(rules, of: manual) }
    #expect(throws: LibraryError.invalidRule("title can't be compared with greaterThan")) {
        try index.setRules(
            SmartRules(match: .all, rules: [.init(.title, .greaterThan, .text("a"))]), of: smart)
    }
    let limited = SmartRules(match: .all, rules: [], limit: SmartLimit(count: 3, order: .title))
    try index.setRules(limited, of: smart)
    #expect(try index.playlist(smart).kind == .smart(limited))
    #expect(try shownPaths(index, .playlist(smart), by: .title).count == 3)
}

@Test func unreadableRulesAreListedAndFailWhenShown() throws {
    let (_, index, _, _) = try scanned()
    let id = try index.createPlaylist(named: "Old", rules: SmartRules(match: .all, rules: []))
    try index.database.prepare("UPDATE playlists SET rules = ? WHERE id = ?").run(
        #"{"match": "all", "rules": [], "shuffle": true}"#, id)
    guard case .unreadable = try index.playlist(id).kind else {
        Issue.record("expected unreadable rules")
        return
    }
    #expect(throws: LibraryError.self) {
        try index.trackIDs(TrackFilter(source: .playlist(id)), sortedBy: .title)
    }
    // New rules replace the ones that can't be read.
    try index.setRules(SmartRules(match: .any, rules: []), of: id)
    #expect(try index.playlist(id).kind == .smart(SmartRules(match: .any, rules: [])))
}

@Test func aDuplicateCopiesTheEntriesInOrderOrTheRules() throws {
    let (_, index, ids, _) = try scanned()
    let manual = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(manual, trackIDs: [ids[2], ids[0], ids[1]])
    let copy = try index.duplicatePlaylist(manual, named: "Mix copy")
    #expect(try index.playlist(copy).name == "Mix copy")
    #expect(try index.playlistTrackIDs(copy) == [ids[2], ids[0], ids[1]])
    // The copy is a playlist of its own.
    try index.removeFromPlaylist(copy, trackIDs: [ids[0]])
    #expect(try index.playlistTrackIDs(manual) == [ids[2], ids[0], ids[1]])

    let rules = SmartRules(match: .any, rules: [.init(.title, .contains, .text("x"))])
    let smart = try index.createPlaylist(named: "Smart", rules: rules)
    let smartCopy = try index.duplicatePlaylist(smart, named: "Smart copy")
    #expect(try index.playlist(smartCopy).kind == .smart(rules))

    try index.database.prepare("UPDATE playlists SET rules = ? WHERE id = ?").run(
        #"{"match": "all", "rules": [], "shuffle": true}"#, smart)
    let count = try index.playlists().count
    #expect(throws: LibraryError.self) { try index.duplicatePlaylist(smart, named: "x") }
    #expect(try index.playlists().count == count)
    #expect(throws: LibraryError.unknownPlaylist(-1)) {
        try index.duplicatePlaylist(-1, named: "x")
    }
}

@Test func statsAndPlaylistsSurviveAnIndexRebuild() throws {
    let (library, index, ids, paths) = try scanned()
    let id = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(id, trackIDs: [ids[2], ids[0]])
    try index.recordPlay(paths[2], at: 1000)
    try index.recordSkip(paths[0])
    try index.setRating(3, trackIDs: [ids[0]])
    try index.database.execute("UPDATE schema_identity SET sql = 'older' WHERE part = 'index'")

    let rebuilt = try library.index()
    #expect(try rebuilt.trackCount() == 0)
    _ = try library.scan()
    #expect(try shownPaths(rebuilt, .playlist(id), by: .playlistOrder) == [paths[2], paths[0]])
    let rows = try rebuilt.rows(
        ids: try rebuilt.trackIDs(TrackFilter(source: .playlist(id)), sortedBy: .playlistOrder))
    #expect(rows.map(\.playCount) == [1, 0])
    #expect(rows.map(\.skipCount) == [0, 1])
    #expect(rows.map(\.lastPlayedSeconds) == [1000, nil])
    #expect(rows.map(\.rating) == [0, 3])
}

@Test func playsCountUpAndHistoryListsWhatWasPlayed() throws {
    let (_, index, ids, paths) = try scanned()
    #expect(try shownPaths(index, .history, by: .lastPlayed).isEmpty)
    try index.recordPlay(paths[1], at: 100)
    try index.recordPlay(paths[0], at: 200)
    try index.recordPlay(paths[1], at: 300)
    let played = try index.rows(
        ids: try index.trackIDs(
            TrackFilter(source: .history), sortedBy: .lastPlayed, ascending: false))
    #expect(played.map(\.path) == [paths[1], paths[0]])
    #expect(played.map(\.playCount) == [2, 1])
    #expect(played.map(\.lastPlayedSeconds) == [300, 200])
    #expect(try index.database.prepare("SELECT count(*) FROM history").map { try $0.int(0) } == [3])

    try index.setRating(5, trackIDs: [ids[0], ids[1]])
    try index.setRating(0, trackIDs: [ids[1]])
    #expect(
        try index.rows(ids: try index.trackIDs(TrackFilter(source: .history), sortedBy: .rating))
            .map(\.rating) == [0, 5])
}

@Test func playlistOrderOutsideAPlaylistLeavesTheAlbumOrder() throws {
    let (_, index, _, _) = try scanned()
    #expect(
        try index.trackIDs(sortedBy: .playlistOrder)
            == (try index.trackIDs(sortedBy: .playlistOrder, ascending: false)))
}

@Test func rowsDroppedOnTheirOwnBlockStayPut() throws {
    let (_, index, ids, _) = try scanned()
    let id = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(id, trackIDs: Array(ids[0..<6]))
    // Rows 3 to 5 dropped above row 4, which is one of them.
    try index.movePlaylistEntries(id, trackIDs: Array(ids[2..<5]), before: ids[3])
    #expect(try index.playlistTrackIDs(id) == Array(ids[0..<6]))
    // Dropped above the first of them, they gather before the next row that isn't moving.
    try index.movePlaylistEntries(id, trackIDs: [ids[2], ids[4]], before: ids[2])
    #expect(try index.playlistTrackIDs(id) == [ids[0], ids[1], ids[2], ids[4], ids[3], ids[5]])
}

@Test func aDeletedPlaylistsIDIsNeverReused() throws {
    let (_, index, _, _) = try scanned()
    _ = try index.createPlaylist(named: "a")
    let last = try index.createPlaylist(named: "b")
    try index.deletePlaylist(last)
    #expect(try index.createPlaylist(named: "c") != last)
}

@Test func aLimitOfNoTracksIsRefusedWhenWritten() throws {
    let (_, index, _, _) = try scanned()
    let rules = SmartRules(match: .all, rules: [], limit: SmartLimit(count: 0, order: .title))
    #expect(throws: LibraryError.invalidRule("a limit needs at least 1 track")) {
        try index.createPlaylist(named: "x", rules: rules)
    }
}

@Test func entriesWhoseFileLeftTheIndexAreCounted() throws {
    let (library, index, ids, paths) = try scanned()
    let id = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(id, trackIDs: Array(ids[0..<3]))
    for path in paths[1..<3] { try FileManager.default.removeItem(atPath: path) }
    _ = try library.scan()
    #expect(try index.missingEntryCount(id) == 2)
    #expect(try shownPaths(index, .playlist(id), by: .playlistOrder) == [paths[0]])
    // The entries stay, so a file that comes back is listed again.
    #expect(try index.playlistTrackIDs(id) == Array(ids[0..<3]))
}
