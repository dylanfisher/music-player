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
    try index.toggle(.liked, trackIDs: ids(index, ["/m/a/2.flac", "/m/a/3.flac"]))
    try index.setRating(5, trackIDs: ids(index, ["/m/a/1.flac"]))

    let profile = try index.libraryProfile()
    #expect(
        profile.albums == [
            LibraryProfile.Album(
                artist: "Band", title: "A", durations: [10, 245, 31],
                catalogNumbers: ["SK 032", "SK 032B"], barcodes: ["0 1234"],
                discogsReleaseID: 42, plays: 3, loved: 2),
            LibraryProfile.Album(
                artist: "Artist", title: "B", durations: [200], catalogNumbers: [],
                barcodes: [], discogsReleaseID: nil, plays: 0, loved: 0),
        ])
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
