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

@Test func aCandidateCarriesItsPlaysLikesAndRatings() throws {
    let index = try index([
        track("A/Played/1.mp3", album: "Played", number: 1, kbps: 128),
        track("A/Played/2.mp3", album: "Played", number: 2, kbps: 128),
        track("A/Liked/1.mp3", album: "Liked", number: 1),
        track("A/Liked/2.mp3", album: "Liked", number: 2),
        track("A/Rated/1.mp3", album: "Rated", number: 1),
        track("A/Rated/2.mp3", album: "Rated", number: 2),
        track("A/Plain/1.mp3", album: "Plain", number: 1),
        track("A/Plain/2.mp3", album: "Plain", number: 2),
    ])
    let ids = { (album: String) in
        try index.trackIDs(atPaths: ["\(root)/A/\(album)/1.mp3", "\(root)/A/\(album)/2.mp3"])
            .map { try #require($0) }
    }
    try index.setPlayCount(5, trackIDs: ids("Played"))
    try index.toggle(.liked, trackIDs: [ids("Liked")[0]])
    try index.setRating(5, trackIDs: [ids("Rated")[0]])
    try index.setRating(3, trackIDs: [ids("Rated")[1]])
    try index.setRating(3, trackIDs: [ids("Plain")[1]])
    let candidates = Dictionary(
        uniqueKeysWithValues: try index.upgradeCandidates(onShare: share).map { ($0.title, $0) })
    #expect(candidates["Played"]?.plays == 10)
    #expect(candidates["Played"]?.kbps == 128)
    #expect(candidates["Played"]?.boosted == false)
    #expect(candidates["Liked"]?.boosted == true, "half its tracks liked")
    #expect(candidates["Rated"]?.boosted == true, "its rated tracks average 4 stars")
    #expect(candidates["Plain"]?.boosted == false, "3 stars doesn't")
}

/// ADR 0200's worked examples, in the order they're queued.
@Test func theScoreQueuesTheMostPlayedLowestQualityFirst() {
    let examples: [(name: String, plays: Int, kbps: Int, boosted: Bool, score: Double)] = [
        ("200 plays at 256", 200, 256, false, 251.25),
        ("50 plays at 128", 50, 128, false, 127.5),
        ("50 plays at 320, liked", 50, 320, true, 102),
        ("50 plays at 320", 50, 320, false, 51),
        ("10 plays at 192, rated", 10, 192, true, 36.67),
        ("never played at 128", 0, 128, false, 2.5),
        ("never played at 320", 0, 320, false, 1),
    ]
    let candidates = examples.enumerated().map { offset, example in
        UpgradeCandidate(
            albumID: Int64(examples.count - offset), title: example.name, artist: nil,
            releaseID: offset, sharePaths: [], quality: "", kbps: example.kbps,
            plays: example.plays, boosted: example.boosted)
    }
    for (candidate, example) in zip(candidates, examples) {
        #expect(abs(candidate.priority - example.score) < 0.01, "\(example.name)")
    }
    #expect(
        candidates.shuffled().sorted { $0.precedes($1) }.map(\.title) == examples.map(\.name))
    var tied = candidates[3]
    tied.albumID = 100
    #expect(candidates[3].precedes(tied), "a tie goes to the lower album id")
}
