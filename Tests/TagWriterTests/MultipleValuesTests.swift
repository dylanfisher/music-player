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

@Test func singleValuesAreNotFlagged() throws {
    #expect(try multiValuedFields(at: Sample.mp4.copy()) == [])
    #expect(try multiValuedFields(at: Sample.mp3v24.copy()) == [])
}
