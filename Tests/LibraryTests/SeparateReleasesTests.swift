import Foundation
import Metadata
import Testing

@testable import Library

/// An original and its 2025 remaster, titled and credited alike, each tagged with its own
/// Discogs release, and a copy of the album with no release id.
private let releases = [
    Crafted(
        path: "/m/remaster/1.flac", title: "One", album: "Album", number: 1, custom: release(2),
        date: "2025"),
    Crafted(
        path: "/m/remaster/2.flac", title: "Two", album: "Album", number: 2, custom: release(2),
        date: "2025"),
    Crafted(
        path: "/m/original/1.flac", title: "One", album: "Album", number: 1, custom: release(1),
        date: "1975"),
    Crafted(
        path: "/m/original/2.flac", title: "Two", album: "Album", number: 2,
        custom: release(1, padded: true), date: "1975"),
    Crafted(path: "/m/untagged/1.flac", title: "One", album: "Album", number: 1, date: "1980"),
]

private func release(_ id: Int, padded: Bool = false) -> [String: String] {
    [DiscogsKey.releaseID: padded ? " \(id) " : "\(id)"]
}

private func libraryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("separate-\(UUID().uuidString)/library.sqlite")
}

/// The paths of each album the Album pane lists, in its order.
private func albumPaths(_ index: LibraryIndex) throws -> [[String]] {
    try index.albums().map { album in
        let ids = try index.database.prepare(
            "SELECT file_id FROM tracks WHERE album_id = ? ORDER BY file_id"
        ).map(binding: [album.id]) { row in try row.int64(0) }
        return try index.paths(ids: ids).values.sorted()
    }
}

/// The track table's paths sorted by Album.
private func tablePaths(_ index: LibraryIndex, groupByAlbumArtist: Bool) throws -> [String] {
    var filter = TrackFilter()
    filter.groupByAlbumArtist = groupByAlbumArtist
    let ids = try index.trackIDs(filter, sortedBy: .album)
    let paths = try index.paths(ids: ids)
    return ids.compactMap { paths[$0] }
}

@Test func offMergesReleasesThatShareATitleAndArtist() throws {
    let index = try LibraryIndex(at: libraryURL())
    try index.store(releases.map(\.scanned))
    #expect(!index.separateReleases)
    #expect(try albumPaths(index).map(\.count) == [5])
}

@Test func onMakesAnAlbumOfEachReleaseAndMergesTheUntagged() throws {
    let index = try LibraryIndex(at: libraryURL(), separateReleases: true)
    try index.store(releases.map(\.scanned))
    #expect(index.separateReleases)
    #expect(
        try albumPaths(index) == [
            ["/m/original/1.flac", "/m/original/2.flac"],
            ["/m/untagged/1.flac"],
            ["/m/remaster/1.flac", "/m/remaster/2.flac"],
        ], "by year, the padded id the same release")
    // The table has no year to sort by, so releases come in the order they were added, each
    // whole.
    for groupByAlbumArtist in [false, true] {
        #expect(
            try tablePaths(index, groupByAlbumArtist: groupByAlbumArtist) == [
                "/m/remaster/1.flac", "/m/remaster/2.flac", "/m/original/1.flac",
                "/m/original/2.flac", "/m/untagged/1.flac",
            ])
    }
}

@Test func anOpenThatAsksNothingKeepsTheStoredOption() throws {
    let url = libraryURL()
    try LibraryIndex(at: url, separateReleases: true).store(releases.map(\.scanned))
    var asked = false
    let reopened = try LibraryIndex(
        at: url,
        confirmRescan: { _ in
            asked = true
            return false
        })
    #expect(!asked)
    #expect(reopened.separateReleases)
    #expect(!reopened.rebuiltIndex)
    #expect(try reopened.trackCount() == releases.count)
    // A scan through it keeps the releases apart.
    try reopened.store([
        Crafted(path: "/m/original/3.flac", album: "Album", custom: release(1)).scanned
    ])
    #expect(try albumPaths(reopened).map(\.count) == [3, 1, 2])
}

@Test func changingTheOptionAsksOnceAndRebuildsOnlyTheIndex() throws {
    let url = libraryURL()
    let off = try LibraryIndex(at: url)
    try off.store(releases.map(\.scanned))
    try off.setRating(4, trackIDs: try ids(off, ["/m/original/1.flac"]))
    try off.database.execute("INSERT INTO loved (path_id) SELECT id FROM paths LIMIT 1")
    let measured = try off.database.prepare("SELECT part, sql FROM schema_identity")
        .map { (try $0.text(0), try $0.text(1)) }

    var asked: [RescanNotice] = []
    let on = try LibraryIndex(
        at: url,
        confirmRescan: {
            asked.append($0)
            return true
        }, separateReleases: true)
    #expect(asked.map(\.separateReleases) == [true])
    #expect(asked.map(\.parts) == [[]], "the option alone, not a new shape")
    #expect(on.rebuiltIndex)
    #expect(on.separateReleases)
    #expect(try on.trackCount() == 0)
    #expect(
        try on.database.prepare("SELECT count(*) FROM ratings").map { try $0.int(0) } == [1])
    #expect(try on.database.prepare("SELECT count(*) FROM loved").map { try $0.int(0) } == [1])
    #expect(try on.discards().isEmpty)
    let rebuilt = Dictionary(
        uniqueKeysWithValues: try on.database.prepare("SELECT part, sql FROM schema_identity")
            .map { (try $0.text(0), try $0.text(1)) })
    #expect(measured.filter { rebuilt[$0.0] != $0.1 }.map(\.0) == ["index"])

    // And back off, which says so.
    asked = []
    _ = try LibraryIndex(
        at: url,
        confirmRescan: {
            asked.append($0)
            return true
        }, separateReleases: false)
    #expect(asked.map(\.separateReleases) == [false])
}

@Test func decliningTheChangeLeavesTheFileAsItWas() throws {
    let url = libraryURL()
    try LibraryIndex(at: url).store(releases.map(\.scanned))
    let before = try Data(contentsOf: url)
    #expect(throws: LibraryError.rescanDeclined) {
        _ = try LibraryIndex(at: url, confirmRescan: { _ in false }, separateReleases: true)
    }
    #expect(try Data(contentsOf: url) == before)
    let reopened = try LibraryIndex(at: url)
    #expect(!reopened.separateReleases)
    #expect(try reopened.trackCount() == releases.count)
}

@Test func aNewShapeAndTheOptionSayBoth() throws {
    let url = libraryURL()
    try LibraryIndex(at: url).database.execute(
        """
        UPDATE schema_identity SET sql = '-- separate releases: off' || char(10) || 'older'
        WHERE part = 'index'
        """)
    var asked: [RescanNotice] = []
    #expect(throws: LibraryError.rescanDeclined) {
        _ = try LibraryIndex(
            at: url,
            confirmRescan: {
                asked.append($0)
                return false
            }, separateReleases: true)
    }
    #expect(asked.map(\.parts) == [[.index]])
    #expect(asked.map(\.separateReleases) == [true])
    #expect(asked.map { $0.onlySeparatesReleases(true) } == [false], "a relaunch's flag asks")
}

@Test func theNoticeSaysWhichWayAlbumsAreMade() throws {
    let on = RescanNotice(separatingReleases: true).text
    let off = RescanNotice(separatingReleases: false).text
    #expect(on.hasPrefix("Albums are made of each Discogs release"))
    #expect(off.hasPrefix("Albums are made of title and artist again"))
    let why = try #require(SchemaPart.index.rescanWhy)
    #expect(!on.contains(why) && !off.contains(why))
    for text in [on, off] {
        #expect(text.hasSuffix("Every file is read again. Plays, ratings and playlists stay."))
    }
    let both = try #require(RescanNotice(parts: [.index], separateReleases: true)).text
    #expect(both.hasPrefix("Albums are made of each Discogs release"))
    #expect(both.contains(why))
    #expect(RescanNotice(parts: [], separateReleases: nil) == nil)
}

@Test func onlyTheOptionsOwnChangeToTheConfirmedValueIsWaived() throws {
    #expect(RescanNotice(separatingReleases: true).onlySeparatesReleases(true))
    #expect(RescanNotice(separatingReleases: false).onlySeparatesReleases(false))
    #expect(!RescanNotice(separatingReleases: true).onlySeparatesReleases(false))
    let shape = try #require(RescanNotice(parts: [.index]))
    #expect(!shape.onlySeparatesReleases(true) && !shape.onlySeparatesReleases(false))
    let both = try #require(RescanNotice(parts: [.index], separateReleases: true))
    #expect(!both.onlySeparatesReleases(true))

    // As an open asks it: a change of the option alone, to the value confirmed.
    let url = libraryURL()
    try LibraryIndex(at: url).store(releases.map(\.scanned))
    var waived: [Bool] = []
    _ = try LibraryIndex(
        at: url,
        confirmRescan: {
            waived.append($0.onlySeparatesReleases(true))
            return true
        }, separateReleases: true)
    #expect(waived == [true])
}
