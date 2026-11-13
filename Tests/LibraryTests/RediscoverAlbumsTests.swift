import Foundation
import Settings
import Testing

@testable import Library

/// The album id of the track at `path`.
private func album(_ index: LibraryIndex, _ path: String) throws -> Int64 {
    try #require(try index.track(path: path)?.albumID)
}

/// The paths the source lists, in its own order or in `column`'s.
private func listed(_ index: LibraryIndex, by column: TrackColumn = .playlistOrder) throws
    -> [String]
{
    let ids = try index.trackIDs(TrackFilter(source: .rediscover), sortedBy: column)
    return try index.rows(ids: ids).map(\.path)
}

@Test func rediscoverListsItsAlbumsInTheirOrderEachInDiscAndTrackOrder() throws {
    let index = try craftedIndex([
        Crafted(path: "/m/a/1.flac", album: "A", number: 1).scanned,
        Crafted(path: "/m/a/2.flac", album: "A", number: 2).scanned,
        // A compilation's track artists don't break up its track order.
        Crafted(
            path: "/m/c/1.flac", artist: "Zed", album: "Mix", disc: 1, number: 1, compilation: true
        ).scanned,
        Crafted(
            path: "/m/c/3.flac", artist: "Abe", album: "Mix", disc: 2, number: 1, compilation: true
        ).scanned,
        Crafted(
            path: "/m/c/2.flac", artist: "Abe", album: "Mix", disc: 1, number: 2, compilation: true
        ).scanned,
        Crafted(path: "/m/b/1.flac", album: "B").scanned,
    ])
    #expect(try listed(index).isEmpty, "nothing before a day is shown")
    let mix = try album(index, "/m/c/1.flac")
    let a = try album(index, "/m/a/1.flac")
    let b = try album(index, "/m/b/1.flac")
    let gone: Int64 = 999_999
    // Another Mac's keys: an id the index doesn't have, or has for another album.
    #expect(
        try index.showRediscover([(mix, "Mix"), (gone, "Gone"), (a, "A"), (b, "Not B")])
            == [gone, b])
    #expect(
        try listed(index) == [
            "/m/c/1.flac", "/m/c/2.flac", "/m/c/3.flac", "/m/a/1.flac", "/m/a/2.flac",
        ])
    // Sorted by another column, it lists the same tracks.
    #expect(Set(try listed(index, by: .title)) == Set(try listed(index)))
    _ = try index.showRediscover([])
    #expect(try listed(index).isEmpty)
}

@Test func theReaderListsRediscoverOnItsRefreshConnectionToo() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rediscover-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("library.sqlite", isDirectory: false)
    let index = try LibraryIndex(at: url)
    try index.store([Crafted(path: "/m/a/1.flac", album: "A").scanned])
    let reader = try LibraryReader(databaseURL: url)
    let a = try album(index, "/m/a/1.flac")
    #expect(try await reader.showRediscover([(a, "A")]).isEmpty)
    for connection in [reader, reader.refreshes] {
        let ids = try await connection.trackIDs(
            TrackFilter(source: .rediscover), sortedBy: .playlistOrder, ascending: true)
        #expect(ids.count == 1)
    }
}
