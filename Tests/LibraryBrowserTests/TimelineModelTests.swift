import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

/// A timeline model over a copy of the shared browser library, the index to write plays with,
/// and the library's tracks in path order.
@MainActor
private func timeline() throws -> (TimelineModel, LibraryIndex, [TrackRow]) {
    let source = try browserLibrary.get().databaseURL
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("timeline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: source.path + suffix) {
        try FileManager.default.copyItem(
            atPath: source.path + suffix, toPath: databaseURL.path + suffix)
    }
    let index = try LibraryIndex(at: databaseURL)
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    let model = TimelineModel(reader: try LibraryReader(databaseURL: databaseURL)) { ids in
        try index.playedTracks(ids: ids)
    }
    return (model, index, rows)
}

/// Logs `count` plays, cycling through `rows`, a second apart from `start`.
private func play(_ count: Int, of rows: [TrackRow], from start: Int, _ index: LibraryIndex)
    throws
{
    for play in 0..<count {
        try index.recordPlay(rows[play % rows.count].path, at: Double(start + play))
    }
}

@MainActor @Test func pagesStayWholeWhilePlaysArrive() async throws {
    let (model, index, rows) = try timeline()
    let pageSize = TimelineModel.pageSize
    try play(pageSize * 2 + 50, of: rows, from: 0, index)
    await model.load()
    #expect(model.entries.count == pageSize)
    #expect(model.entries.first?.playedSeconds == pageSize * 2 + 49)
    #expect(model.playCount == pageSize * 2 + 50)

    try play(3, of: rows, from: 10_000, index)
    await model.addNewPlays()
    #expect(model.entries.prefix(3).map(\.playedSeconds) == [10_002, 10_001, 10_000])
    await model.loadMore()
    await model.loadMore()
    #expect(model.reachedEnd)
    let seconds = model.entries.map(\.playedSeconds)
    #expect(seconds == [10_002, 10_001, 10_000] + Array((0..<(pageSize * 2 + 50)).reversed()))
    #expect(Set(model.entries.map(\.id)).count == model.entries.count)

    // Asking again changes nothing: the oldest play is loaded and nothing new was played.
    await model.loadMore()
    await model.addNewPlays()
    #expect(model.entries.map(\.playedSeconds) == seconds)
}

@MainActor @Test func moreThanAPageOfNewPlaysReloads() async throws {
    let (model, index, rows) = try timeline()
    try play(5, of: rows, from: 0, index)
    await model.load()
    try play(TimelineModel.pageSize, of: rows, from: 1000, index)
    await model.addNewPlays()
    #expect(model.entries.count == TimelineModel.pageSize)
    #expect(model.entries.first?.playedSeconds == 1000 + TimelineModel.pageSize - 1)
    #expect(!model.reachedEnd)
}

@MainActor @Test func aSelectionActsOnEachTrackOnceButPlaysEveryRow() async throws {
    let (model, index, rows) = try timeline()
    // Newest first: b, a, gone, a.
    try index.recordPlay(rows[0].path, at: 1)
    try index.recordPlay("/gone/x.flac", at: 2)
    try index.recordPlay(rows[0].path, at: 3)
    try index.recordPlay(rows[1].path, at: 4)
    await model.load()
    #expect(
        try model.entries.indices.map { try model.played(at: $0)?.track == nil } == [
            false, false, true, false,
        ])
    #expect(try model.played(at: 2)?.title == "x")

    #expect(try model.trackIDs(ofRows: [0, 1, 2, 3]) == [rows[1].id, rows[0].id])
    #expect(try model.trackIDs(ofRows: [2]).isEmpty)
    let a = URL(fileURLWithPath: rows[0].path)
    let b = URL(fileURLWithPath: rows[1].path)
    #expect(try model.urls(ofRows: [0, 1, 2, 3]) == [b, a, a])
    #expect(
        try model.playRequest(selected: [], clicked: 1) == PlayRequest(urls: [b, a, a], first: 1))
    // A missing row clicked starts at the next row that plays.
    #expect(
        try model.playRequest(selected: [], clicked: 2) == PlayRequest(urls: [b, a, a], first: 2))
    #expect(model.rows(holding: [model.entries[3].id, 999]) == [3])
}

@MainActor @Test func aLibraryChangeReadsTheRowsAgain() async throws {
    let (model, index, rows) = try timeline()
    try index.recordPlay(rows[0].path, at: 1)
    try index.recordPlay(rows[1].path, at: 2)
    await model.load()
    #expect(try model.played(at: 0)?.track != nil)
    try index.remove([rows[1].id])
    var changes = 0
    model.changed = { _ in changes += 1 }
    model.refresh()
    #expect(changes == 1)
    #expect(try model.played(at: 0)?.track == nil)
    #expect(try model.played(at: 0)?.path == rows[1].path)
    #expect(try model.played(at: 1)?.track != nil)
}

@MainActor @Test func scrollingTwentyThousandPlaysKeepsTheCacheBounded() async throws {
    let (model, index, rows) = try timeline()
    let count = 20_000
    try index.database.transaction {
        let insert = try index.database.prepare(
            "INSERT INTO history (path_id, played_at) VALUES (?, ?)")
        for play in 0..<count { try insert.run(rows[play % rows.count].id, play) }
    }
    await model.load()
    while !model.reachedEnd { await model.loadMore() }
    #expect(model.entries.count == count)
    var most = 0
    for row in model.entries.indices {
        _ = try model.played(at: row)
        most = max(most, model.cachedPageCount)
    }
    #expect(most == TimelineModel.cachePages)
    // A loaded play is three numbers; what it shows lives only in the cache.
    #expect(MemoryLayout<PlayEntry>.size == 24)
}

@MainActor @Test func aRequestThatChangesNothingDoesntReload() async throws {
    let (model, index, rows) = try timeline()
    try index.recordPlay(rows[0].path, at: 1)
    await model.load()
    var changes = 0
    model.changed = { _ in changes += 1 }
    await model.addNewPlays()
    await model.loadMore()
    #expect(changes == 0)
}

@MainActor @Test func aLoadOverTakenByClearIsDropped() async throws {
    let (model, index, rows) = try timeline()
    try index.recordPlay(rows[0].path, at: 1)
    var changes = 0
    model.changed = { _ in changes += 1 }
    let load = Task { await model.load() }
    // The load is waiting on the reader when the timeline stops showing.
    await Task.yield()
    model.clear()
    await load.value
    #expect(model.entries.isEmpty)
    // Neither the dropped load nor clearing rows that never showed reloads the table.
    #expect(changes == 0)
    await model.load()
    #expect(model.entries.count == 1)
}

@MainActor @Test func theBrowserListsTheTimelinesPlaysForGoToItem() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("timeline-browser-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let copy = directory.appendingPathComponent("library.sqlite")
    for suffix in ["", "-wal"]
    where FileManager.default.fileExists(atPath: databaseURL.path + suffix) {
        try FileManager.default.copyItem(
            atPath: databaseURL.path + suffix, toPath: copy.path + suffix)
    }
    let index = try LibraryIndex(at: copy)
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    try index.recordPlay(rows[0].path, at: 1)
    try index.recordPlay(rows[0].path, at: 2)
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: copy), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, folders: [])
    await browser.load(BrowserState(source: .timeline, genre: nil, artist: nil, album: nil))
    #expect(browser.showsTimeline)
    let deadline = Date().addingTimeInterval(10)
    while browser.rowID(at: 1) == nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let names = try await browser.trackNames()
    // One track played twice is two rows, each named by its play.
    #expect(names.map(\.title) == [rows[0].title, rows[0].title])
    #expect(names.map(\.id) == [browser.rowID(at: 0), browser.rowID(at: 1)])
    #expect(Set(names.map(\.id)).count == 2)
    #expect(!browser.hasSelectedTracks)
    // The log is append-only, so ⌘⌫ has nothing to remove there.
    #expect(!browser.canRemoveFromPlaylist)
}

/// A browser over a copy of the shared browser library, and the index to write plays with.
@MainActor
private func timelineBrowser() throws -> (LibraryBrowser, LibraryIndex, [TrackRow]) {
    let source = try browserLibrary.get().databaseURL
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("timeline-browser-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: source.path + suffix) {
        try FileManager.default.copyItem(
            atPath: source.path + suffix, toPath: databaseURL.path + suffix)
    }
    let index = try LibraryIndex(at: databaseURL)
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, folders: [])
    return (browser, index, rows)
}

private let showingTimeline = BrowserState(source: .timeline, genre: nil, artist: nil, album: nil)

/// Waits up to 10 seconds for `condition`.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
}

@MainActor @Test func theTimelineSaysItsFirstRowsDrewOnlyOnceItHasThem() async throws {
    let (browser, index, rows) = try timelineBrowser()
    try index.recordPlay(rows[0].path, at: 1)
    var drawn = 0
    browser.firstRowsDrawn = { drawn += 1 }
    await browser.load(showingTimeline)
    // The track table is empty on the timeline, but that isn't the first frame.
    #expect(drawn == 0)

    let (empty, _, _) = try timelineBrowser()
    var emptyDrawn = 0
    empty.firstRowsDrawn = { emptyDrawn += 1 }
    await empty.load(showingTimeline)
    try await waitUntil { emptyDrawn > 0 }
    #expect(emptyDrawn == 1)
}

@MainActor @Test func aLibraryChangeWhileTheTimelineShowsReadsItsRowsAgain() async throws {
    let (browser, index, rows) = try timelineBrowser()
    try index.recordPlay(rows[0].path, at: 1)
    await browser.load(showingTimeline)
    try await waitUntil { browser.timelineModel.isLoaded }
    #expect(try browser.timelineModel.played(at: 0)?.track != nil)
    try index.remove([rows[0].id])
    browser.watcherEvents(.removed(count: 1))
    try await waitUntil { (try? browser.timelineModel.played(at: 0)?.track) == nil }
    #expect(try browser.timelineModel.played(at: 0)?.track == nil)
}

@MainActor @Test func aPlayWhileTheTimelineShowsGoesOnTop() async throws {
    let (browser, index, rows) = try timelineBrowser()
    try index.recordPlay(rows[0].path, at: 1)
    await browser.load(showingTimeline)
    try await waitUntil { browser.timelineModel.isLoaded }
    browser.recordPlay(rows[1].path, at: 2)
    try await waitUntil { browser.timelineModel.entries.count == 2 }
    #expect(browser.timelineModel.entries.map(\.trackID) == [rows[1].id, rows[0].id])
}

@MainActor @Test func leavingTheTimelineClearsItAndShowingItAgainReloads() async throws {
    let (browser, index, rows) = try timelineBrowser()
    try index.recordPlay(rows[0].path, at: 1)
    await browser.load(showingTimeline)
    try await waitUntil { browser.timelineModel.isLoaded }
    #expect(!browser.canSort)
    browser.show(nil)
    try await waitUntil { !browser.showsTimeline }
    #expect(browser.timelineModel.entries.isEmpty)
    #expect(browser.canSort)
    // Played while another source showed, so only a reload finds it.
    try index.recordPlay(rows[1].path, at: 2)
    browser.show(.timeline)
    try await waitUntil { browser.timelineModel.entries.count == 2 }
    #expect(browser.timelineModel.entries.first?.trackID == rows[1].id)
}

@MainActor @Test func aTimelineSelectionActsOnEachTrackOnce() async throws {
    let (browser, index, rows) = try timelineBrowser()
    // Newest first: b, a, a.
    for (seconds, row) in [rows[0], rows[0], rows[1]].enumerated() {
        try index.recordPlay(row.path, at: Double(seconds))
    }
    await browser.load(showingTimeline)
    try await waitUntil { browser.timelineModel.entries.count == 3 }
    browser.selectAllTracks()
    #expect(browser.hasSelectedTracks)
    #expect(try await browser.selectedPaths() == [rows[1].path, rows[0].path])

    browser.rateSelection(4)
    try await waitUntil { (try? index.rows(ids: [rows[0].id]).first?.rating) == 4 }
    #expect(try index.rows(ids: [rows[0].id, rows[1].id]).map(\.rating) == [4, 4])

    let mix = try index.createPlaylist(named: "Mix")
    browser.addSelection(to: mix)
    try await waitUntil { (try? index.playlistTrackIDs(mix).count) == 2 }
    #expect(try index.playlistTrackIDs(mix) == [rows[1].id, rows[0].id])
}
