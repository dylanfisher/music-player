import Testing

@testable import Discogs
@testable import Library
@testable import TagCorpus

private func tuning(_ id: Int, files: Int = 2) -> TuningAlbum {
    TuningAlbum(
        name: "Album \(id)",
        album: DiscogsAlbum(
            id: Int64(id), title: "Album \(id)", artist: "Artist",
            tracks: (0..<files).map {
                DiscogsAlbum.Track(fileID: Int64($0), title: "T", seconds: 1)
            }),
        releaseID: id, ordinals: [:])
}

private func result(_ tier: MatchTier, chose: Int?, tracks: Int = 2) -> AlbumMatch {
    AlbumMatch(
        albumID: 1, tier: tier,
        release: chose.map { CatalogRelease(id: $0, title: "") },
        tracks: Array(
            repeating: CatalogTrack(kind: .track, position: "1", title: "T"), count: tracks),
        mapping: [:], candidates: [])
}

@Test func theBarCountsTwinsAsTheReleaseAndLeavesOutIncompletesForAnotherCount() {
    let albums = (1...6).map { tuning($0) }
    let matches = [
        result(.exact, chose: 1),  // the tagged release
        result(.exact, chose: 99),  // a twin
        result(.exact, chose: 98),  // neither
        result(.incomplete, chose: 4, tracks: 3),  // another count: left out
        result(.likely, chose: 97),  // a Likely with neither: a miss
        result(.incomplete, chose: 96, tracks: 3),  // another release: counted, a miss
    ]
    let kinships: [Kinship] = [.same, .twin, .other, .same, .other, .other]
    let lines = tuningLines(albums, matches, kinships: kinships, seconds: 1, heading: "h")
    #expect(
        lines.contains(
            "Incomplete for another count, with the tagged release or a twin, left out: 1"))
    #expect(lines.contains("chosen a twin of the tagged release: 1"))
    #expect(lines.contains("Exact or Likely with the tagged release or a twin: 2 of 5 (40.0%)"))
    #expect(lines.contains("Exact with a release neither the tagged one nor a twin: 1"))
    // The raw numbers, as before.
    #expect(lines.contains("Exact or Likely with the tagged release: 1 (16.7%)"))
    #expect(lines.contains("Exact with another release: 2"))
}
