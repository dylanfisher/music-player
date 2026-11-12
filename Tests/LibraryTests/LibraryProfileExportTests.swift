import Foundation
import Testing

@testable import Library
@testable import Metadata
@testable import Recommender

@Test func anAlbumsProfileSumsItsTracksInDiscAndTrackOrder() throws {
    let index = try craftedIndex([
        Crafted(
            path: "/m/a/3.flac", album: "A", albumArtist: "Band", disc: 2, number: 1,
            seconds: 30.6, custom: [DiscogsKey.releaseID: "42"], catalogNumber: "SK 032"
        ).scanned,
        Crafted(
            path: "/m/a/1.flac", album: "A", albumArtist: "Band", disc: 1, number: 1,
            seconds: 10.4, custom: [DiscogsKey.releaseID: "42"], catalogNumber: "SK 032",
            barcode: "0 1234"
        ).scanned,
        Crafted(
            path: "/m/a/2.flac", album: "A", albumArtist: "Band", disc: 1, number: 2,
            seconds: 245, rateHz: 48000, custom: [DiscogsKey.releaseID: "42"],
            catalogNumber: "SK 032B"
        ).scanned,
        Crafted(path: "/m/b/1.flac", album: "B").scanned,
        Crafted(path: "/m/loose.flac").scanned,
    ])
    try index.recordPlay("/m/a/1.flac", at: 1)
    try index.recordPlay("/m/a/1.flac", at: 2)
    try index.recordPlay("/m/a/3.flac", at: 3)
    try index.recordSkip("/m/a/2.flac")
    try index.recordSkip("/m/a/2.flac")
    try index.recordSkip("/m/a/3.flac")
    try index.toggle(.liked, trackIDs: ids(index, ["/m/a/2.flac", "/m/a/3.flac"]))
    try index.setRating(5, trackIDs: ids(index, ["/m/a/1.flac"]))

    let profile = try index.libraryProfile()
    #expect(
        profile.albums == [
            LibraryProfile.Album(
                key: try albumKey(index, "/m/a/1.flac"), artist: "Band", title: "A",
                durations: [10, 245, 31], catalogNumbers: ["SK 032", "SK 032B"],
                barcodes: ["0 1234"], discogsReleaseID: 42, plays: 3, loved: 2, lastPlayed: 3,
                skips: 3),
            LibraryProfile.Album(
                key: try albumKey(index, "/m/b/1.flac"), artist: "Artist", title: "B",
                durations: [200], catalogNumbers: [], barcodes: [], discogsReleaseID: nil,
                plays: 0, loved: 0, lastPlayed: nil, skips: 0),
        ])
}

/// The profile's key of the album of the track at `path`.
private func albumKey(_ index: LibraryIndex, _ path: String) throws -> String {
    let id = try #require(try index.rows(ids: ids(index, [path])).first?.albumID)
    return profileKey(albumID: id)
}

@Test func anAlbumsKeyNamesItsAlbumAndReadsBack() {
    #expect(profileKey(albumID: 812) == "a812")
    #expect(albumID(profileKey: "a812") == 812)
    for other in ["812", "a", "a-1", "a0x1", "r4242", "a 1", "a01", "a+5"] {
        #expect(albumID(profileKey: other) == nil, "\(other)")
    }
}

@Test func anImportedLastPlayedIsNotSentButTheNewestPlayHereIs() throws {
    let index = try craftedIndex([
        Crafted(path: "/m/a/1.flac", album: "A", number: 1).scanned,
        Crafted(path: "/m/a/2.flac", album: "A", number: 2).scanned,
        Crafted(path: "/m/b/1.flac", album: "B").scanned,
    ])
    var swinsian = PlayerLibrary(player: .swinsian, source: "/swinsian/Library.sqlite")
    for path in ["/m/a/1.flac", "/m/b/1.flac"] {
        var track = PlayerTrack(path: path)
        track.plays = 4
        track.lastPlayedSeconds = 2_000
        _ = swinsian.add(track)
    }
    _ = try index.applyImport(swinsian, prefix: nil)
    try index.recordPlay("/m/a/2.flac", at: 500)
    try index.recordPlay("/m/a/2.flac", at: 1_000)
    let lastPlayed = Dictionary(
        uniqueKeysWithValues: try index.libraryProfile().albums.map { ($0.title, $0.lastPlayed) })
    // B's only date is Swinsian's, and A's newest play here is older than Swinsian's.
    let expected: [String: Int?] = ["A": 1_000, "B": nil]
    #expect(lastPlayed == expected)
}

@Test func anAlbumHasAReleaseIDOnlyWhenEveryTrackCarriesOnePositiveNumber() throws {
    func album(_ name: String, _ releases: [String?]) -> [ScannedFile] {
        releases.enumerated().map { number, release in
            var custom: [String: String] = [:]
            custom[DiscogsKey.releaseID] = release
            return Crafted(
                path: "/m/\(name)/\(number).flac", album: name, number: number + 1,
                custom: custom
            ).scanned
        }
    }
    let index = try craftedIndex(
        album("Matched", ["7", "7"]) + album("Mixed", ["7", "8"])
            + album("Partial", ["7", nil]) + album("Text", ["r7", "r7"])
            + album("Zero", ["0", "0"]))
    let releases = Dictionary(
        uniqueKeysWithValues: try index.libraryProfile().albums.map {
            ($0.title, $0.discogsReleaseID)
        })
    #expect(
        releases == [
            "Matched": 7, "Mixed": nil, "Partial": nil, "Text": nil, "Zero": nil,
        ])
}

@Test func aCompilationWithoutAnAlbumArtistIsVariousArtists() throws {
    let index = try craftedIndex([
        Crafted(
            path: "/m/c/1.flac", artist: "One", album: "Mix", number: 1, compilation: true
        ).scanned,
        Crafted(
            path: "/m/c/2.flac", artist: "Two", album: "Mix", number: 2, compilation: true
        ).scanned,
    ])
    #expect(try index.libraryProfile().albums.map(\.artist) == [variousArtists])
}

@Test func theProfileIsWrittenWhereAskedInPlaceOfAFileThere() throws {
    let index = try craftedIndex([Crafted(path: "/m/b/1.flac", album: "B").scanned])
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("profile-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("old".utf8).write(to: url)
    #expect(try index.writeLibraryProfile(to: url) == 1)
    #expect(try Data(contentsOf: url) == index.libraryProfile().json())
}

// What the export holds and where it may write (ADR 0198; ADR 0025, row 76).

@Test func eachAlbumHoldsTheContractsTwelveKeysAndNoPathOrRating() throws {
    let index = try craftedIndex([
        Crafted(path: "/m/a/1.flac", album: "A", custom: [DiscogsKey.releaseID: "42"]).scanned
    ])
    try index.setRating(5, trackIDs: ids(index, ["/m/a/1.flac"]))
    let root = try #require(
        try JSONSerialization.jsonObject(with: index.libraryProfile().json()) as? [String: Any])
    #expect(Set(root.keys) == ["albums"])
    let albums = try #require(root["albums"] as? [[String: Any]])
    #expect(albums.count == 1)
    #expect(
        Set(albums[0].keys) == [
            "artist", "title", "track_count", "durations", "catalog_numbers", "barcodes",
            "discogs_release_id", "plays", "loved", "key", "last_played", "skips",
        ])
    let text = String(decoding: try index.libraryProfile().json(), as: UTF8.self)
    #expect(!text.contains("/m/"), "no path")
    #expect(!text.contains("rating"))
}

@Test func aHostileTitleStaysOneJSONString() throws {
    let hostile =
        #"A", "plays": 999, "x": {"#
        + "\u{1B}[31m\u{202E}\\ \n</script>"
    let index = try craftedIndex([
        Crafted(path: "/m/a/1.flac", album: hostile, albumArtist: hostile).scanned
    ])
    let root = try #require(
        try JSONSerialization.jsonObject(with: index.libraryProfile().json()) as? [String: Any])
    let album = try #require((root["albums"] as? [[String: Any]])?.first)
    #expect(album["title"] as? String == hostile)
    #expect(album["artist"] as? String == hostile)
    #expect(album["plays"] as? Int == 0)
    #expect(album.count == 12)
}

@Test func theProfileIsNeverWrittenOverAFileOfTheLibraryOrALink() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("profile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let music = folder.appendingPathComponent("1.flac")
    let bytes = Data("flac".utf8)
    try bytes.write(to: music)
    let index = try craftedIndex([Crafted(path: music.path, album: "B").scanned])
    #expect(throws: ProfileDestinationRefusal.indexed(music.path)) {
        try index.writeLibraryProfile(to: music)
    }
    #expect(try Data(contentsOf: music) == bytes)
    // The same file by a folder that links to its own.
    let linked = folder.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: folder)
    let real = try #require(resolved(folder.path)) + "/1.flac"
    try index.store([Crafted(path: real, album: "B").scanned])
    #expect(throws: ProfileDestinationRefusal.indexed(real)) {
        try index.writeLibraryProfile(to: linked.appendingPathComponent("1.flac"))
    }
    let link = folder.appendingPathComponent("profile.json")
    let target = folder.appendingPathComponent("target.txt")
    try Data("keep".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: ProfileDestinationRefusal.link(link.path)) {
        try index.writeLibraryProfile(to: link)
    }
    #expect(try Data(contentsOf: target) == Data("keep".utf8))
    #expect(try Data(contentsOf: music) == bytes)
}

@Test func aSeedNamesItsAlbumsArtistAndReleaseAsTheProfileDoes() throws {
    let index = try craftedIndex([
        Crafted(
            path: "/m/a/1.flac", artist: "Guest", album: "A", albumArtist: "Band", number: 1,
            custom: [DiscogsKey.releaseID: "42"]
        ).scanned,
        Crafted(
            path: "/m/a/2.flac", album: "A", albumArtist: "Band", number: 2,
            custom: [DiscogsKey.releaseID: "42"]
        ).scanned,
        Crafted(
            path: "/m/c/1.flac", artist: "One", album: "Mix", number: 1,
            custom: [DiscogsKey.releaseID: "7"], compilation: true
        ).scanned,
        Crafted(
            path: "/m/c/2.flac", artist: "Two", album: "Mix", number: 2, compilation: true
        ).scanned,
    ])
    let seeds = try index.recommendationSeeds(
        trackIDs: ids(index, ["/m/c/2.flac", "/m/a/1.flac", "/m/a/2.flac"]))
    #expect(seeds.map { $0.title } == ["A", "Mix"])
    #expect(seeds.map { $0.artist } == ["Band", variousArtists])
    #expect(seeds.map { $0.releaseID } == [42, nil])
    let profile = try index.libraryProfile().albums
    for seed in seeds {
        let album = try #require(profile.first { $0.title == seed.title })
        #expect(album.artist == seed.artist)
        #expect(album.discogsReleaseID == seed.releaseID)
    }
}
