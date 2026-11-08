import Foundation
import Testing

@testable import Library
@testable import Metadata

private func track(_ path: String, album: String, release: String?, master: String? = nil)
    -> ScannedFile
{
    var custom: [String: String] = [:]
    custom[DiscogsKey.releaseID] = release
    custom[DiscogsKey.masterID] = master
    custom["DISCOGS_CATALOG_NUMBER"] = "Label: CAT-1"
    return Crafted(path: path, album: album, custom: custom).scanned
}

@Test func theReleaseAndMasterIDsAreStoredAndTheRestIsNot() throws {
    let index = try craftedIndex([track("/m/a/1.flac", album: "A", release: "42", master: "m7")])
    let row = try index.database.prepare(
        "SELECT discogs_release_id, discogs_master_id FROM tracks"
    ).map { ($0.optionalText(0), $0.optionalText(1)) }
    #expect(row.count == 1)
    #expect(row.first?.0 == "42")
    #expect(row.first?.1 == "m7")
}

@Test func anAlbumIsMatchedOnlyWhenEveryTrackHasOneReleaseID() throws {
    let index = try craftedIndex([
        track("/m/a/1.flac", album: "Matched", release: "1"),
        track("/m/a/2.flac", album: "Matched", release: "1"),
        track("/m/b/1.flac", album: "Mixed", release: "1"),
        track("/m/b/2.flac", album: "Mixed", release: "2"),
        track("/m/c/1.flac", album: "Partial", release: "3"),
        track("/m/c/2.flac", album: "Partial", release: nil),
        track("/m/d/1.flac", album: "None", release: nil),
    ])
    let albums = Dictionary(
        uniqueKeysWithValues: try index.database.prepare("SELECT title, id FROM albums").map {
            (try $0.text(0), try $0.int64(1))
        })
    let matches = try index.discogsMatches()
    #expect(matches.count == 4)
    #expect(matches[albums["Matched"]!] == .matched(releaseID: "1"))
    #expect(matches[albums["Mixed"]!] == .incomplete)
    #expect(matches[albums["Partial"]!] == .incomplete)
    #expect(matches[albums["None"]!] == .unmatched)
}

@Test func anAlbumForTheMatcherComesFromTheIndexInDiscAndTrackOrder() throws {
    let index = try craftedIndex([
        Crafted(
            path: "/m/a/3.flac", title: "Three", album: "A", albumArtist: "Band", disc: 2,
            number: 1, seconds: 30, custom: [DiscogsKey.releaseID: "42"]
        ).scanned,
        Crafted(
            path: "/m/a/1.flac", title: "One", album: "A", albumArtist: "Band", disc: 1,
            number: 1, seconds: 10, label: nil
        ).scanned,
        Crafted(
            path: "/m/a/2.flac", title: "Two", album: "A", albumArtist: "Band", disc: 1,
            number: 2, rateHz: 48000,
            custom: ["COUNTRY": "US", "DISCOGS_ALBUM_RELEASECOUNTRY": "UK"], label: "Svek & Other",
            catalogNumber: "SK 032", barcode: "0 1234", date: "1999-03-00",
            media: "Vinyl (LP,Album)"
        ).scanned,
        Crafted(path: "/m/b/1.flac", title: "Solo", album: "B").scanned,
    ])
    let albums = try index.discogsAlbums()
    #expect(albums.map(\.title) == ["A", "B"])
    let album = try #require(albums.first)
    #expect(album.artist == "Band")
    #expect(album.label == "Svek & Other")
    #expect(album.catalogNumber == "SK 032")
    #expect(album.barcode == "0 1234")
    #expect(album.date == "1999-03-00")
    #expect(album.media == "Vinyl (LP,Album)")
    // YATE's own key before the COUNTRY beside it.
    #expect(album.country == "UK")
    #expect(album.tracks.map(\.title) == ["One", "Two", "Three"])
    #expect(album.tracks.map(\.seconds) == [10, 200, 30])
    #expect(album.tracks.map(\.discNumber) == [1, 1, 2])
    #expect(album.tracks.map(\.releaseID) == [nil, nil, "42"])
    #expect(albums[1].artist == "Artist")
    #expect(albums[1].label == nil)
}
