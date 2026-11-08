import Foundation

@testable import Discogs
@testable import Metadata
@testable import Settings

// Albums for the mapping's tests: a release, its files' current tags, and a match of one file
// per track in order.

func audio(_ codec: TrackAudio.Codec) -> TrackAudio {
    TrackAudio(
        codec: codec, sampleRateHz: 44_100, bitsPerSample: 16, channels: 2,
        lengthFrames: 44_100 * 200)
}

/// A file with `tags`, of `codec`, as the window reads it.
func albumFile(_ id: Int64, _ codec: TrackAudio.Codec, _ tags: TrackTags) -> AlbumFile {
    AlbumFile(
        id: id, path: "/tmp/album/\(id).file",
        metadata: TrackMetadata(tags: tags, audio: audio(codec), art: nil))
}

/// `release` matched to files 1, 2, … in track order, its tracks as files hold them.
func match(_ release: CatalogRelease, files: Int? = nil) -> AlbumMatch {
    let tracks = ReleaseTracklist.flattenings(release.tracks)[0]
    let count = files ?? tracks.count
    return AlbumMatch(
        albumID: 1, tier: .exact, release: release, tracks: tracks,
        mapping: Dictionary(
            uniqueKeysWithValues: (0..<min(count, tracks.count)).map { (Int64($0 + 1), $0) }),
        candidates: [])
}

func tags(_ change: (inout TrackTags) -> Void) -> TrackTags {
    var tags = TrackTags()
    change(&tags)
    return tags
}

func artist(
    _ id: Int?, _ name: String, anv: String? = nil, join: String? = nil
) -> CatalogArtistCredit {
    CatalogArtistCredit(id: id, name: name, nameVariation: anv, join: join)
}

func label(_ id: Int?, _ name: String, _ catalogNumber: String?) -> CatalogRelease.Label {
    CatalogRelease.Label(id: id, name: name, catalogNumber: catalogNumber)
}

func format(_ name: String, _ descriptions: [String] = []) -> CatalogRelease.Format {
    CatalogRelease.Format(name: name, quantity: 1, text: nil, descriptions: descriptions)
}

func song(_ position: String?, _ title: String, credits: [CatalogCredit] = []) -> CatalogTrack {
    CatalogTrack(kind: .track, position: position, title: title, credits: credits)
}
