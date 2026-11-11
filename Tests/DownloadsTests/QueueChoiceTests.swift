import Foundation
import Testing

@testable import Downloads
@testable import Library
@testable import Recommender

// The queue sheets' rules: the albums of a selection, and the orders made.

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
    #expect(
        choices.map(\.title) == [
            "Made-Up Artist - Album 1", "Made-Up Artist - Album 2", "Made-Up Artist - Album 4",
        ])
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

@Test func upgradesNameAMarkedAlbumAndNotFoundListsTheSetAside() {
    let candidates = [1, 2, 3].map {
        UpgradeCandidate(
            albumID: Int64($0), title: "Album \($0)", artist: "Made-Up Artist", releaseID: $0,
            sharePaths: ["library/\($0).mp3"], quality: "MP3 320 kbps")
    }
    #expect(
        QueueChoice.upgrades(candidates, never: [2]).map(\.detail) == [
            "MP3 320 kbps, release 1", "MP3 320 kbps, release 2, Never Upgrade",
            "MP3 320 kbps, release 3",
        ])
    let setAside = QueueChoice.setAside(
        candidates,
        misses: [
            1: UpgradeMiss(misses: 4, retryAt: nil), 2: UpgradeMiss(misses: 2, retryAt: 5),
        ])
    #expect(setAside.map(\.releaseID) == [1])
    #expect(setAside.first?.detail == "4 searches found no clean copy, release 1")
    #expect(setAside.first?.upgrade == nil, "queuing again only clears the misses")
}
