import Foundation
import Settings
import Testing

@testable import Library

@Test func theTimelinePagesEveryPlayNewestFirstAndStaysStableAsPlaysArrive() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    // Each of three tracks played 3 times, in turn: a track repeats on the timeline.
    for play in 0..<9 { try index.recordPlay(rows[play % 3].path, at: Double(1000 + play)) }

    let first = try index.timeline(before: nil, limit: 4)
    #expect(first.map(\.playedSeconds) == [1008, 1007, 1006, 1005])
    #expect(first.map(\.trackID) == [rows[2].id, rows[1].id, rows[0].id, rows[2].id])
    let played = try index.playedTracks(ids: first.map(\.trackID))
    #expect(first.map { played[$0.trackID]?.track?.path } == first.map { played[$0.trackID]?.path })

    // New plays don't shift the next page.
    try index.recordPlay(rows[0].path, at: 2000)
    try index.recordPlay(rows[1].path, at: 2001)
    let second = try index.timeline(before: first.last?.id, limit: 4)
    #expect(second.map(\.playedSeconds) == [1004, 1003, 1002, 1001])
    let last = try index.timeline(before: second.last?.id, limit: 4)
    #expect(last.map(\.playedSeconds) == [1000])

    let newer = try index.timeline(after: try #require(first.first?.id), limit: 10)
    #expect(newer.map(\.playedSeconds) == [2001, 2000])
    #expect(try index.timeline(after: try #require(first.first?.id), limit: 1).count == 1)
    #expect(try index.loggedPlayCount() == 11)
    #expect(Set((first + second + last + newer).map(\.id)).count == 11)
}

@Test func playsOfFilesNoLongerIndexedShowAsMissing() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    try index.recordPlay(rows[0].path, at: 1)
    try index.recordPlay("/elsewhere/never-indexed.flac", at: 2)
    try index.recordPlay(rows[1].path, at: 3)
    try FileManager.default.removeItem(atPath: rows[1].path)
    _ = try library.scan()

    let page = try index.timeline(before: nil, limit: 200)
    let played = try index.playedTracks(ids: page.map(\.trackID))
    #expect(
        page.map { played[$0.trackID]?.path }
            == [rows[1].path, "/elsewhere/never-indexed.flac", rows[0].path])
    #expect(page.map { played[$0.trackID]?.track != nil } == [false, false, true])
    #expect(
        page.map { played[$0.trackID]?.title } == [
            displayName(rows[1].path), "never-indexed", rows[0].title,
        ])
    #expect(page[0].trackID == rows[1].id)
}

@Test func rowsAndPlayedTracksReadMoreIDsThanSQLiteTakesInOneList() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let ids = try index.trackIDs(sortedBy: .path)
    // Far past SQLite's 32,766 parameters, mostly IDs with no track, and repeats.
    let asked = Array(1...40_000).map(Int64.init) + ids + ids
    #expect(Set(try index.rows(ids: asked).map(\.id)) == Set(ids))
    // Every file the scan saw has a path, and those it could read have a track.
    let played = try index.playedTracks(ids: asked)
    #expect(played.count == library.manifest.files.count)
    #expect(Set(played.filter { $0.value.track != nil }.keys) == Set(ids))
}

@Test func playedAtIsInWholeSeconds() throws {
    let index = try TestLibrary().index()
    try index.recordPlay("/a.flac", at: 1234.9)
    #expect(try index.timeline(before: nil, limit: 1).map(\.playedSeconds) == [1234])
}

@Test func historyLeavesOutATrackOnlySkipped() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    try index.recordSkip(rows[0].path)
    try index.recordPlay(rows[1].path, at: 10)
    #expect(
        try index.trackIDs(TrackFilter(source: .history), sortedBy: .lastPlayed) == [rows[1].id])
}

@Test func theTimelineHasNoTrackList() throws {
    let index = try TestLibrary().index()
    #expect(throws: LibraryError.playsNotTracks) {
        try index.trackIDs(TrackFilter(source: .timeline), sortedBy: .title)
    }
}

@Test func lastPlayedTiesBreakOnTheIDAlone() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let ids = try index.trackIDs(sortedBy: .path)
    // Picked so their artist and album order isn't their ID order.
    let picked = try index.rows(ids: try index.trackIDs(sortedBy: .artist, ascending: false))
        .prefix(5)
    for row in picked { try index.recordPlay(row.path, at: 100) }
    let history = TrackFilter(source: .history)
    #expect(
        try index.trackIDs(history, sortedBy: .lastPlayed, ascending: false)
            == picked.map(\.id).sorted(by: >))
    #expect(
        try index.trackIDs(history, sortedBy: .lastPlayed) == picked.map(\.id).sorted())
    // Outside History, the tracks never played tie too, and come in ID order.
    let unplayed = Set(ids).subtracting(picked.map(\.id))
    #expect(
        Array(try index.trackIDs(sortedBy: .lastPlayed).prefix(unplayed.count))
            == unplayed.sorted())
}
