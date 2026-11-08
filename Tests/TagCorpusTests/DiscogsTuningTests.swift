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

@Test func theBarLeavesOutWhatNothingCouldFitAndCountsTwinsAsTheRelease() {
    let albums = (1...9).map { tuning($0) }
    let matches = [
        result(.exact, chose: 1),  // the tagged release
        result(.exact, chose: 99),  // a twin
        result(.exact, chose: 98),  // neither
        result(.incomplete, chose: 4, tracks: 3),  // kept at another count: left out
        result(.likely, chose: 97),  // a Likely with neither: a miss
        result(.exact, chose: 96),  // neither, the tags outdated: a known miss
        result(.exact, chose: 95),  // the tagged release not in the dump: left out
        result(.exact, chose: 94),  // the tagged release another count: left out
        result(.likely, chose: 8),  // the tagged release's titles changed: left out
    ]
    let outcomes = [
        TuningOutcome(kinship: .same, taggedFit: .fits),
        TuningOutcome(kinship: .twin, taggedFit: .fits),
        TuningOutcome(kinship: .other, taggedFit: .fits),
        TuningOutcome(kinship: .same, taggedFit: .fits),
        TuningOutcome(kinship: .other, taggedFit: .fits),
        TuningOutcome(kinship: .other, taggedFit: .fits, tagsOutdated: true),
        TuningOutcome(kinship: .other, taggedFit: nil),
        TuningOutcome(kinship: .other, taggedFit: .otherCount),
        TuningOutcome(kinship: .same, taggedFit: .otherTitles),
    ]
    let lines = tuningLines(albums, matches, outcomes: outcomes, seconds: 1, heading: "h")
    for expected in [
        "left out, the tagged release not in the dump: 1",
        "left out, the tagged release another count than the files: 1",
        "left out, the tagged release's titles not the files': 1",
        "left out, Incomplete with the tagged release or a twin, the files another count: 1",
        "counted: 5", "chosen a twin of the tagged release: 1",
        "Exact or Likely with the tagged release or a twin: 2 of 5 (40.0%)",
        "Exact with a release neither the tagged one nor a twin: 2 of 5 (40.0%)",
        "known misses, the tags' date or MEDIA one the tagged release no longer has: 1",
        // The raw numbers, as before.
        "Exact or Likely with the tagged release: 2 (22.2%)",
        "Exact with another release: 5",
    ] {
        #expect(lines.contains(expected), "\(expected)")
    }
}
