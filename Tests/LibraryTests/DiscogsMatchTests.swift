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
