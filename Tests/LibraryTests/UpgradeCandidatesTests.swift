import Foundation
import Testing

@testable import Library
@testable import Metadata

private let share = "smb://HAL9000/music"
private let root = "/Volumes/music/library"

/// A track of `album` at `path` under the library folder, `seconds` long, at `kbps` with its
/// 10 bytes of art.
private func track(
    _ path: String, album: String, codec: TrackAudio.Codec = .mp3, release: String? = "42",
    number: Int, kbps: Int = 320, under folder: String = root
) -> ScannedFile {
    var crafted = Crafted(
        path: folder + "/" + path, title: "Song \(number)", album: album,
        albumArtist: "Made-Up Artist", number: number, codec: codec,
        custom: release.map { [DiscogsKey.releaseID: $0] } ?? [:])
    crafted.sizeBytes = kbps * 1000 / 8 * Int(crafted.seconds) + 10
    return crafted.scanned
}

/// An index holding `files`, with the library folder found at `root` on `share`.
private func index(_ files: [ScannedFile]) throws -> LibraryIndex {
    let index = try craftedIndex(files)
    try index.relocate(share: share, path: "library", to: root)
    return index
}

@Test func aLossyAlbumOfOneReleaseIsAnUpgradeWithItsSharePathsAndQuality() throws {
    let index = try index([
        track("Made-Up Artist/Made-Up Album/02 Two.mp3", album: "Made-Up Album", number: 2),
        track("Made-Up Artist/Made-Up Album/01 One.mp3", album: "Made-Up Album", number: 1),
        track("Made-Up Artist/Other/01 One.m4a", album: "Other", codec: .aac, number: 1, kbps: 256),
    ])
    let candidates = try index.upgradeCandidates(onShare: share)
    #expect(candidates.map(\.title) == ["Made-Up Album", "Other"])
    let album = try #require(candidates.first)
    #expect(album.artist == "Made-Up Artist")
    #expect(album.releaseID == 42)
    #expect(
        album.sharePaths == [
            "library/Made-Up Artist/Made-Up Album/01 One.mp3",
            "library/Made-Up Artist/Made-Up Album/02 Two.mp3",
        ])
    #expect(album.quality == "MP3 320 kbps")
    #expect(candidates.last?.quality == "AAC 256 kbps")
}

@Test func anAlbumIsNoUpgradeUnlessEveryTrackIsLossyOnTheShareAndOfOneRelease() throws {
    let index = try index([
        track("A/Lossless/1.flac", album: "Lossless", codec: .flac, number: 1),
        track("A/Mixed/1.mp3", album: "Mixed", number: 1),
        track("A/Mixed/2.flac", album: "Mixed", codec: .flac, number: 2),
        track("A/Partial/1.mp3", album: "Partial", number: 1),
        track("A/Partial/2.mp3", album: "Partial", release: nil, number: 2),
        track("A/Two Releases/1.mp3", album: "Two Releases", number: 1),
        track("A/Two Releases/2.mp3", album: "Two Releases", release: "43", number: 2),
        track("A/Junk/1.mp3", album: "Junk", release: "r42", number: 1),
        track("A/Elsewhere/1.mp3", album: "Elsewhere", number: 1, under: "/Users/me/Music"),
        track("A/Kept/1.mp3", album: "Kept", number: 1),
    ])
    #expect(try index.upgradeCandidates(onShare: share).map(\.title) == ["Kept"])
    #expect(try index.upgradeCandidates(onShare: "smb://HAL9000/other").isEmpty)
}
