import Foundation
import Testing

@testable import Downloads
@testable import Library
@testable import Recommender

// The queue sheets' rules: a pasted release, the albums of a selection, and the orders made.

@Test(arguments: [
    ("1234567", 1_234_567 as Int?),
    ("  r42\n", 42),
    ("https://www.discogs.com/release/1234567-Made-Up-Artist-Made-Up-Album", 1_234_567),
    ("https://discogs.com/release/99", 99),
    ("https://www.discogs.com/fr/release/99-Album", 99),
    ("https://www.discogs.com/master/99-Album", nil),
    ("https://example.com/release/99", nil),
    ("0", nil),
    ("Made-Up Album", nil),
])
func aPastedReleaseIsAnIdOrADiscogsReleaseURL(text: String, id: Int?) {
    #expect(QueueChoice.pastedReleaseID(text) == id)
}

private func album(_ id: Int64, _ releases: [String?]) -> DiscogsAlbum {
    DiscogsAlbum(
        id: id, title: "Album \(id)", artist: "Made-Up Artist",
        tracks: releases.enumerated().map { offset, release in
            DiscogsAlbum.Track(
                fileID: id * 10 + Int64(offset), title: nil, seconds: 60, releaseID: release)
        })
}

@Test func theSelectionQueuesItsAlbumsOfOneReleaseAndSaysToTagTheRest() {
    let albums = [
        album(1, ["4242", "4242"]), album(2, ["4242", nil]), album(3, ["7", "7"]),
        album(4, ["x", "x"]),
    ]
    let choices = QueueChoice.selection([10, 11, 20, 40], albums: albums)
    #expect(choices.map(\.title) == ["Made-Up Artist - Album 1", "Made-Up Artist - Album 2", "Made-Up Artist - Album 4"])
    #expect(choices.map(\.releaseID) == [4242, nil, nil])
    #expect(choices[0].refusal == nil)
    #expect(choices[1].refusal?.hasPrefix("Tag first") == true)
    #expect(choices[2].refusal?.hasPrefix("Tag first") == true, "a release id that isn't a number")
}

@Test func anUpgradeOrdersOnlyALosslessPolicy() {
    let candidate = UpgradeCandidate(
        albumID: 1, title: "Made-Up Album", artist: "Made-Up Artist", releaseID: 4242,
        sharePaths: ["library/a.mp3"], quality: "MP3 320 kbps")
    let upgrade = QueueChoice.upgrades([candidate])[0]
    #expect(upgrade.detail == "MP3 320 kbps, release 4242")
    let replaced = DownloadJob.Upgrade(currentQuality: "MP3 320 kbps", oldPaths: ["library/a.mp3"])
    #expect(upgrade.order(.lossless) == .upgrade(replaced, .lossless))
    #expect(upgrade.order(.mp3320) == nil)
    #expect(upgrade.order(.any) == nil)
    let manual = QueueChoice(
        title: "Release 7", detail: "", releaseID: 7, upgrade: nil, refusal: nil)
    #expect(manual.order(.mp3320) == .manual(.mp3320))
}
