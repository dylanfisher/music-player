import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

@Test func anID3v24FrameWithSeveralValuesIsFound() throws {
    let url = try mp3(
        withTag: id3Tag(
            [
                try ID3Frame(id: "TPE1", body: [0] + Array("One\u{0}Two".utf8), version: 4).raw,
                id3TextFrame("TIT2", "Single", version: 4),
            ], version: 4))
    #expect(try multiValuedFields(at: url) == [.artist])
    #expect(try tags(url).artist == "One")
}

@Test func aRepeatedVorbisKeyIsFound() throws {
    let url = try flac(comments: ["ARTIST=One", "artist=Two", "TITLE=Single"], padding: 64)
    #expect(try multiValuedFields(at: url) == [.artist])
}

/// The tags, the art and the fields holding several values read through one open, the parse's
/// reader shared, read as three opens of the file do.
@Test func oneOpenReadsWhatThreeDo() throws {
    let urls =
        try [
            flac(comments: ["ARTIST=One", "artist=Two", "TITLE=Single"], padding: 64),
            mp3(
                withTag: id3Tag(
                    [
                        try ID3Frame(id: "TPE1", body: [0] + Array("One\u{0}Two".utf8), version: 4)
                            .raw
                    ], version: 4)),
        ] + [Sample.flacWithArt, .mp4WithArt, .mp3v24WithArt, .aiffWithArt].map { try $0.copy() }
    for url in urls {
        let source = try FileSource(path: url.path)
        let reader = ByteReader(source)
        let parsed = try parse(reader)
        let shared = try parsed.metadata.art.map { art throws(ParseFailure) in
            try readArt(art, from: source)
        }
        #expect(try multiValuedFields(in: reader) == multiValuedFields(at: url), "\(url)")
        #expect(parsed.metadata.tags == (try tags(url)), "\(url)")
        #expect(shared == (try art(url)), "\(url)")
    }
}

@Test func singleValuesAreNotFlagged() throws {
    #expect(try multiValuedFields(at: Sample.mp4.copy()) == [])
    #expect(try multiValuedFields(at: Sample.mp3v24.copy()) == [])
}
