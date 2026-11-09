import Library
import Testing

@testable import Discogs

// Which library album a download queued as a new album replaces (ADR 0169).

private func album(
    _ id: Int64, _ artist: String?, _ title: String, releases: [String?] = [nil, nil]
) -> DiscogsAlbum {
    DiscogsAlbum(
        id: id, title: title, artist: artist,
        tracks: releases.enumerated().map { offset, release in
            DiscogsAlbum.Track(
                fileID: id * 10 + Int64(offset), title: "Track \(offset)", seconds: 200,
                trackNumber: offset + 1, releaseID: release)
        })
}

@Test func theAlbumTaggedWithTheReleaseIsReplacedBeforeOneNamedLikeIt() {
    let tagged = album(1, "Someone Else", "Other", releases: ["42", "42"])
    let named = album(2, "Daft Punk", "Random Access Memories")
    #expect(
        libraryAlbum(
            replacedBy: 42, artist: "Daft Punk", title: "Random Access Memories",
            among: [named, tagged]) == .album(tagged, byName: false))
}

@Test func withNoAlbumOfTheReleaseOneNamedLikeItIsReplaced() {
    // A track tagged with another release, or with none, keeps an album off the release.
    let mixed = album(1, "Daft Punk", "Random Access Memories", releases: ["42", "7"])
    let other = album(3, "Daft Punk", "Discovery")
    #expect(
        libraryAlbum(
            replacedBy: 42, artist: "Daft Punk (2)",
            title: "random access memories", among: [mixed, other])
            == .album(mixed, byName: true))
    #expect(
        libraryAlbum(replacedBy: 42, artist: "Daft Punk", title: "Homework", among: [other])
            == .none)
    // A compilation without an album artist is never one by name.
    #expect(
        libraryAlbum(
            replacedBy: 42, artist: "Various", title: "Hits", among: [album(4, nil, "Hits")])
            == .none)
}

@Test func twoAlbumsOfTheReleaseReplaceNeither() {
    let one = album(1, "A", "B", releases: ["42"])
    let two = album(2, "A", "B", releases: ["42", "42"])
    #expect(
        libraryAlbum(replacedBy: 42, artist: "A", title: "B", among: [one, two])
            == .several(count: 2, byName: false))
    let three = album(3, "The A", "B")
    let four = album(4, "a", "b")
    #expect(
        libraryAlbum(replacedBy: 42, artist: "A", title: "B", among: [three, four])
            == .several(count: 2, byName: true))
}

@Test func anEditionOfTheAlbumIsNotTheAlbum() {
    let deluxe = album(1, "Daft Punk", "Random Access Memories (Deluxe Edition)")
    let plain = album(2, "Daft Punk", "Random Access Memories")
    #expect(
        libraryAlbum(
            replacedBy: 42, artist: "Daft Punk", title: "Random Access Memories",
            among: [deluxe]) == .none)
    #expect(
        libraryAlbum(
            replacedBy: 42, artist: "Daft Punk", title: "Random Access Memories (Deluxe Edition)",
            among: [plain]) == .none)
    #expect(
        libraryAlbum(
            replacedBy: 42, artist: "Daft Punk", title: "Random Access Memories",
            among: [deluxe, plain]) == .album(plain, byName: true))
}
