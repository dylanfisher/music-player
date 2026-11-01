import Foundation
import SQLite
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

/// A model over a copy of the shared browser library, which these tests write playlists and
/// stats to.
@MainActor
private func writableModel(
    _ saved: BrowserState = BrowserState(source: nil, genre: nil, artist: nil, album: nil)
) async throws -> (
    BrowserModel, LibraryIndex
) {
    let source = try browserLibrary.get().databaseURL
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("playlist-browser-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: source.path + suffix) {
        try FileManager.default.copyItem(
            atPath: source.path + suffix, toPath: databaseURL.path + suffix)
    }
    let model = BrowserModel(
        reader: try LibraryReader(databaseURL: databaseURL), sortColumn: .artist, ascending: true)
    await model.load(saved)
    return (model, try LibraryIndex(at: databaseURL))
}

@MainActor @Test func aNewPlaylistHoldsTheSelectionAndOpensInItsOwnOrder() async throws {
    let (model, index) = try await writableModel()
    let rows = IndexSet([5, 2, 9])
    let picked = rows.map { model.trackIDs[$0] }
    try await model.createPlaylist(
        named: "Mix", rules: nil, trackIDs: model.ids(ofRows: rows))
    let playlist = try #require(model.shownPlaylist)
    #expect(playlist.name == "Mix" && playlist.isManual)
    #expect(model.filter.source == .playlist(playlist.id))
    #expect(model.sortColumn == .playlistOrder && model.ascending)
    #expect(model.trackIDs == picked)
    #expect(model.canReorder)
    #expect(try index.playlists().map(\.name) == ["Mix"])
}

@MainActor @Test func rowsMoveAndLeaveWithinTheShownPlaylist() async throws {
    let (model, _) = try await writableModel()
    let picked = Array(model.trackIDs.prefix(4))
    try await model.createPlaylist(
        named: "Mix", rules: nil, trackIDs: model.ids(ofRows: IndexSet(0..<4)))
    #expect(model.trackIDs == picked)
    try await model.move([picked[3], picked[0]], toRow: 1)
    #expect(model.trackIDs == [picked[0], picked[3], picked[1], picked[2]])
    try await model.move([picked[3]], toRow: 4)
    #expect(model.trackIDs == [picked[0], picked[1], picked[2], picked[3]])
    try await model.removeFromShownPlaylist(rows: [1])
    #expect(model.trackIDs == [picked[0], picked[2], picked[3]])

    // Sorted by another column, a drag can't say where a track goes.
    await model.setSort(.title, ascending: true)
    #expect(!model.canReorder)
    let order = model.trackIDs
    try await model.move([order[0]], toRow: 2)
    #expect(model.trackIDs == order)
}

@MainActor @Test func historyOpensWithTheLatestPlayFirstAndFollowsPlays() async throws {
    let (model, _) = try await writableModel()
    let first = model.trackIDs[0]
    let second = model.trackIDs[1]
    let paths = try await model.urls(ofRows: [0, 1]).map(\.path)
    await model.setSource(.history)
    #expect(model.sortColumn == .lastPlayed && !model.ascending)
    #expect(model.trackIDs.isEmpty)
    try await model.recordPlay(paths[0], at: 100)
    try await model.recordPlay(paths[1], at: 200)
    #expect(model.trackIDs == [second, first])
    try await model.recordPlay(paths[0], at: 300)
    #expect(model.trackIDs == [first, second])

    // Leaving History puts back the sort it replaced.
    await model.setSource(.folder("/"))
    #expect(model.sortColumn == .artist && model.ascending)
}

@MainActor @Test func aSmartPlaylistFollowsRatingsAndItsRules() async throws {
    let (model, _) = try await writableModel()
    let rated = model.trackIDs[3]
    try await model.createPlaylist(
        named: "Loved",
        rules: SmartRules(match: .all, rules: [.init(.rating, .greaterThan, .number(3))]))
    let playlist = try #require(model.shownPlaylist)
    #expect(model.sortColumn == .artist)
    #expect(model.trackIDs.isEmpty)

    await model.setSource(nil)
    let row = try #require(model.trackIDs.firstIndex(of: rated))
    try await model.rate([model.trackIDs[row]], stars: 4)
    await model.setSource(.playlist(playlist.id))
    #expect(model.trackIDs == [rated])

    try await model.setRules(
        SmartRules(match: .all, rules: [.init(.rating, .is, .number(5))]), of: playlist.id)
    #expect(model.trackIDs.isEmpty)
}

@MainActor @Test func deletingTheShownPlaylistShowsTheLibrary() async throws {
    let (model, index) = try await writableModel()
    try await model.createPlaylist(
        named: "Gone", rules: nil, trackIDs: model.ids(ofRows: [0]))
    let id = try #require(model.shownPlaylist?.id)
    try await model.deletePlaylist(id)
    #expect(model.filter.source == nil)
    #expect(model.playlists.isEmpty)
    #expect(model.trackIDs.count == (try index.trackCount()))
}

@MainActor @Test func aSavedPlaylistThatsGoneLoadsTheLibrary() async throws {
    let (model, index) = try await writableModel(
        BrowserState(source: .playlist(999), genre: nil, artist: nil, album: nil))
    #expect(model.filter.source == nil)
    #expect(model.trackIDs.count == (try index.trackCount()))
}

@MainActor @Test func leavingAManualPlaylistPutsBackTheSortItReplaced() async throws {
    let (model, _) = try await writableModel()
    await model.setSort(.title, ascending: false)
    try await model.createPlaylist(
        named: "Mix", rules: nil, trackIDs: model.ids(ofRows: [0, 1]))
    let mix = try #require(model.shownPlaylist?.id)
    #expect(model.sortColumn == .playlistOrder)
    await model.setSource(nil)
    #expect(model.sortColumn == .title && !model.ascending)

    // A sort chosen inside the playlist stays when leaving it.
    await model.setSource(.playlist(mix))
    await model.setSort(.year, ascending: true)
    await model.setSource(.folder("/"))
    #expect(model.sortColumn == .year)

    // Deleting the shown playlist leaves no playlist order behind.
    await model.setSource(.playlist(mix))
    try await model.deletePlaylist(mix)
    #expect(model.filter.source == nil)
    #expect(model.sortColumn == .year)
}

@MainActor @Test func aSourceThatFailsIsntVisitedOrShown() async throws {
    let (model, index) = try await writableModel()
    try await model.createPlaylist(named: "Broken", rules: SmartRules(match: .all, rules: []))
    let broken = try #require(model.shownPlaylist?.id)
    await model.setSource(nil)
    try index.database.prepare("UPDATE playlists SET rules = '{}' WHERE id = ?").run(broken)
    try await model.reloadPlaylists()
    var failures: [String] = []
    model.failed = { failures.append($0) }
    let before = model.history
    await model.setSource(.playlist(broken))
    #expect(model.filter.source == nil)
    #expect(model.history == before)
    #expect(failures.count == 1)
}

@MainActor @Test func aDeletedPlaylistLeavesHistory() async throws {
    let (model, _) = try await writableModel()
    try await model.createPlaylist(
        named: "Gone", rules: nil, trackIDs: model.ids(ofRows: [0]))
    let gone = try #require(model.shownPlaylist?.id)
    await model.setSource(.history)
    try await model.deletePlaylist(gone)
    // Back goes past where the playlist was, straight to the library.
    #expect(await model.back())
    #expect(model.filter.source == nil)
    #expect(!model.history.canGoBack)
}

@MainActor @Test func aManualPlaylistCountsTracksNotInTheLibrary() async throws {
    let (model, index) = try await writableModel()
    try await model.createPlaylist(
        named: "Mix", rules: nil, trackIDs: model.ids(ofRows: [0]))
    let mix = try #require(model.shownPlaylist?.id)
    try index.recordSkip("/gone/a.flac")
    _ = try index.addToPlaylist(mix, trackIDs: [try index.pathID("/gone/a.flac", seenAt: 0)])
    await model.refresh()
    #expect(model.missingTracks == 1)
    await model.setSource(nil)
    #expect(model.missingTracks == 0)
}
