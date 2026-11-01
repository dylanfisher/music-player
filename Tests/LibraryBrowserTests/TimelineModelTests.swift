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
    return (TimelineModel(reader: try LibraryReader(databaseURL: databaseURL)), index, rows)
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
    #expect(model.entries.map { $0.track == nil } == [false, false, true, false])
    #expect(model.entries[2].title == "x")

    #expect(model.trackIDs(ofRows: [0, 1, 2, 3]) == [rows[1].id, rows[0].id])
    #expect(model.trackIDs(ofRows: [2]).isEmpty)
    let a = URL(fileURLWithPath: rows[0].path)
    let b = URL(fileURLWithPath: rows[1].path)
    #expect(model.urls(ofRows: [0, 1, 2, 3]) == [b, a, a])
    #expect(model.playRequest(selected: [], clicked: 1) == PlayRequest(urls: [b, a, a], first: 1))
    // A missing row clicked starts at the next row that plays.
    #expect(model.playRequest(selected: [], clicked: 2) == PlayRequest(urls: [b, a, a], first: 2))
    #expect(model.rows(holding: [model.entries[3].id, 999]) == [3])
}

@MainActor @Test func aLibraryChangeReResolvesOnlyTheLoadedRows() async throws {
    let (model, index, rows) = try timeline()
    try index.recordPlay(rows[0].path, at: 1)
    try index.recordPlay(rows[1].path, at: 2)
    await model.load()
    #expect(model.entries.allSatisfy { $0.track != nil })
    try index.remove([rows[1].id])
    await model.refresh()
    #expect(model.entries.map { $0.track == nil } == [true, false])
    #expect(model.entries.map(\.path) == [rows[1].path, rows[0].path])
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
    #expect(changes == 1)
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
