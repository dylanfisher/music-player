import Foundation
import Testing

@testable import Fixtures
@testable import Metadata

private let tags = FixtureTags(
    title: "Mack The Knife", artist: "Louis Armstrong", compilation: false)
private let style = ID3Style(
    version: .v23, preferUTF16: false, genreAsReference: false, paddingBytes: 0)

private func tone(_ rate: Int, bytes: Int = 9000) -> [Data] {
    (0..<2).map { dsdTone(samples: bytes * 8, rateHz: rate, channel: $0) }
}

@Test(arguments: [2_822_400, 5_644_800, 11_289_600])
func aDSFReadsItsRateLengthAndTheTagAtItsMetadataPointer(rate: Int) throws {
    let parsed = try parse(
        dsfFile(
            rateHz: rate, channels: tone(rate), samplesPerChannel: 71_999,
            tag: id3Tag(tags, art: nil, style: style)))
    #expect(parsed.warnings.isEmpty)
    #expect(
        parsed.metadata.audio
            == TrackAudio(
                codec: .dsd, sampleRateHz: rate, bitsPerSample: 1, channels: 2, lengthFrames: 71_999
            ))
    #expect(parsed.metadata.tags.title == "Mack The Knife")
    #expect(parsed.metadata.tags.artist == "Louis Armstrong")
}

@Test func aDSFWithoutATagReadsWithNoTags() throws {
    let parsed = try parse(dsfFile(rateHz: 2_822_400, channels: tone(2_822_400)))
    #expect(parsed.metadata.tags == TrackTags())
    #expect(parsed.metadata.audio.lengthFrames == 9000 * 8)
}

@Test func aDSDIFFReadsPROPAndAnID3ChunkIfItHasOne() throws {
    let tagged = try parse(
        dffFile(
            rateHz: 5_644_800, channels: tone(5_644_800, bytes: 1001),
            tag: id3Tag(tags, art: nil, style: style)))
    #expect(
        tagged.metadata.audio
            == TrackAudio(
                codec: .dsd, sampleRateHz: 5_644_800, bitsPerSample: 1, channels: 2,
                lengthFrames: 1001 * 8))
    #expect(tagged.metadata.tags.title == "Mack The Knife")
    let untagged = try parse(dffFile(rateHz: 2_822_400, channels: tone(2_822_400, bytes: 10)))
    #expect(untagged.metadata.tags == TrackTags())
}

@Test func theStreamSaysWhereTheBitsAreAndInWhichOrder() throws {
    let dsf = try dsdStream(
        ByteReader(MemorySource(dsfFile(rateHz: 2_822_400, channels: tone(2_822_400)))))
    #expect(dsf.dataStart == 92 && dsf.interleave == .blocks(blockBytes: 4096) && dsf.lsbFirst)
    #expect(dsf.bytesPerChannel == 9000)
    let dff = try dsdStream(
        ByteReader(MemorySource(dffFile(rateHz: 2_822_400, channels: tone(2_822_400, bytes: 10)))))
    #expect(dff.interleave == .bytes && !dff.lsbFirst && dff.bytesPerChannel == 10)
    #expect(throws: ParseFailure.self) {
        try dsdStream(ByteReader(MemorySource(dffFile(rateHz: 2_822_400, channels: []))))
    }
}

@Test func dstCompressionIsUnsupportedNotDropped() {
    let file = dffFile(rateHz: 2_822_400, channels: tone(2_822_400, bytes: 10), compression: "DST ")
    #expect(failure(file)?.kind == .unsupported)
    #expect(failure(file)?.detail == "DST-compressed DSDIFF")
}

@Test func aCutShortDSFReadsTheBlocksPresentAndWarns() throws {
    let file = dsfFile(
        rateHz: 2_822_400, channels: tone(2_822_400), tag: id3Tag(tags, art: nil, style: style))
    // Halfway into the third group of blocks: the left channel's block is there, the right's isn't.
    let cut = try parse(file.prefix(92 + 2 * 8192 + 4096))
    #expect(cut.warnings.map(\.kind) == [.truncated])
    #expect(cut.metadata.audio.lengthFrames == 2 * 4096 * 8)
    #expect(cut.metadata.tags == TrackTags())
}

@Test(arguments: [
    (2_822_400, "DSD64"), (5_644_800, "DSD128"), (11_289_600, "DSD256"), (3_072_000, "DSD64"),
    (96_000, "96 kHz"), (44_100, "44.1 kHz"), (705_600, "705.6 kHz"),
])
func aDSDRateIsNamedByItsMultiple(rate: Int, text: String) {
    #expect(sampleRateText(rate) == text)
}
