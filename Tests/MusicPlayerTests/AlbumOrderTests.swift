import Foundation
import Testing

@testable import Metadata
@testable import MusicPlayer

private func file(_ name: String, disc: Int? = nil, track: Int? = nil) -> (URL, TrackMetadata?) {
    var tags = TrackTags()
    tags.discNumber = disc
    tags.trackNumber = track
    let audio = TrackAudio(
        codec: .flac, sampleRateHz: 44_100, bitsPerSample: 16, channels: 2, lengthFrames: 1)
    return (
        URL(fileURLWithPath: "/album/\(name)"),
        TrackMetadata(tags: tags, audio: audio, art: nil)
    )
}

@Test func untaggedFilesFollowTheNumberedOnes() {
    let files = [
        file("b.flac"), file("2-1.flac", disc: 2, track: 1), file("1.flac", track: 1),
        file("a.flac"), file("1-2.flac", disc: 1, track: 2),
        (URL(fileURLWithPath: "/album/unreadable.flac"), nil),
    ]
    #expect(
        files.sorted(by: albumOrder).map(\.0.lastPathComponent) == [
            "1.flac", "1-2.flac", "2-1.flac", "a.flac", "b.flac", "unreadable.flac",
        ])
}
