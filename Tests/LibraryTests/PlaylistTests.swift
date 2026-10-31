import Foundation
import Settings
import Testing

@testable import Library
@testable import SQLite

/// A scanned test library, its index, and its track paths in path order.
private func scanned() throws -> (TestLibrary, LibraryIndex, [String]) {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let paths = try index.rows(ids: try index.trackIDs(sortedBy: .path)).map(\.path)
    return (library, index, paths)
}

private func shownPaths(_ index: LibraryIndex, _ source: BrowserSource, by column: TrackColumn)
    throws -> [String]
{
    let ids = try index.trackIDs(TrackFilter(source: source), sortedBy: column)
    return try index.rows(ids: ids).map(\.path)
}

@Test func aManualPlaylistKeepsItsOrderAndEachTrackOnce() throws {
    let (_, index, paths) = try scanned()
    let id = try index.createPlaylist(named: "Mix")
    #expect(try index.addToPlaylist(id, paths: [paths[3], paths[1], paths[3]]) == 2)
    #expect(try index.addToPlaylist(id, paths: [paths[1], paths[0]]) == 1)
    #expect(try index.playlistPaths(id) == [paths[3], paths[1], paths[0]])
    #expect(
        try shownPaths(index, .playlist(id), by: .playlistOrder) == [paths[3], paths[1], paths[0]])
    #expect(try shownPaths(index, .playlist(id), by: .path) == [paths[0], paths[1], paths[3]])

    try index.movePlaylistEntries(id, paths: [paths[0], paths[3]], before: paths[1])
    #expect(try index.playlistPaths(id) == [paths[3], paths[0], paths[1]])
    try index.movePlaylistEntries(id, paths: [paths[3]], before: nil)
    #expect(try index.playlistPaths(id) == [paths[0], paths[1], paths[3]])

    try index.removeFromPlaylist(id, paths: [paths[1]])
    #expect(try index.playlistPaths(id) == [paths[0], paths[3]])
    #expect(try index.trackCount() == paths.count)
}

@Test func playlistsAreListedByNameAndRenamedAndDeleted() throws {
    let (_, index, paths) = try scanned()
    let b = try index.createPlaylist(named: "b")
    let a = try index.createPlaylist(
        named: "A", rules: SmartRules(match: .all, rules: [.init(.title, .contains, .text("x"))]))
    #expect(try index.playlists().map(\.id) == [a, b])
    try index.renamePlaylist(b, to: "0")
    #expect(try index.playlists().map(\.name) == ["0", "A"])
    _ = try index.addToPlaylist(b, paths: [paths[0]])
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
    let (_, index, paths) = try scanned()
    let rules = SmartRules(match: .all, rules: [])
    let smart = try index.createPlaylist(named: "Smart", rules: rules)
    let manual = try index.createPlaylist(named: "Manual")
    #expect(throws: LibraryError.smartPlaylist("Smart")) {
        try index.addToPlaylist(smart, paths: [paths[0]])
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
    let (_, index, _) = try scanned()
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

@Test func statsAndPlaylistsSurviveAnIndexRebuild() throws {
    let (library, index, paths) = try scanned()
    let id = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(id, paths: [paths[2], paths[0]])
    try index.recordPlay(paths[2], at: 1000)
    try index.recordSkip(paths[0])
    try index.setRating(3, paths: [paths[0]])
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
    let (_, index, paths) = try scanned()
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

    try index.setRating(5, paths: [paths[0], paths[1]])
    try index.setRating(0, paths: [paths[1]])
    #expect(
        try index.rows(ids: try index.trackIDs(TrackFilter(source: .history), sortedBy: .rating))
            .map(\.rating) == [0, 5])
}

@Test func playlistOrderOutsideAPlaylistLeavesTheAlbumOrder() throws {
    let (_, index, _) = try scanned()
    #expect(
        try index.trackIDs(sortedBy: .playlistOrder)
            == (try index.trackIDs(sortedBy: .playlistOrder, ascending: false)))
}
