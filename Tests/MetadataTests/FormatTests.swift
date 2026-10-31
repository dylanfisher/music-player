import Foundation
import Testing

@testable import Fixtures
@testable import Metadata

@Test func flacReadsComposerTotalsAndTheFrontCover() throws {
    let file = flac([
        (0, streamInfo(rate: 192_000, channels: 6, bits: 24, total: 1_234_567)),
        (6, flacPicture(type: 4, mime: "image/jpeg", image: Data(repeating: 1, count: 10))),
        (
            4,
            vorbisComment([
                "title=Song", "Composer=Someone", "TRACKNUMBER=03", "TOTALTRACKS=9",
                "DISCNUMBER=1/2",
                "ARTIST=First", "ARTIST=Second", "COMMENT=", "MOOD=calm",
            ])
        ),
        (6, flacPicture(type: 3, mime: "image/png", image: Data(repeating: 2, count: 20))),
    ])
    let metadata = try parse(file).metadata
    #expect(
        metadata.audio
            == TrackAudio(
                codec: .flac, sampleRateHz: 192_000, bitsPerSample: 24, channels: 6,
                lengthFrames: 1_234_567))
    #expect(metadata.tags.title == "Song")
    #expect(metadata.tags.composer == "Someone")
    #expect(metadata.tags.artist == "First")
    #expect(metadata.tags.trackNumber == 3)
    #expect(metadata.tags.trackTotal == 9)
    #expect(metadata.tags.discNumber == 1)
    #expect(metadata.tags.discTotal == 2)
    #expect(metadata.tags.comment == nil)
    let art = try #require(metadata.art)
    #expect(art.mimeType == "image/png")
    #expect(art.byteCount == 20)
    #expect(Array(file[art.offset..<art.offset + art.byteCount]) == Array(repeating: 2, count: 20))
}

@Test func flacSkipsALargePictureWithoutReadingIt() throws {
    let file = flac([
        (0, streamInfo()),
        (6, flacPicture(image: Data(count: 4 << 20))),
        (4, vorbisComment(["TITLE=After the picture"])),
    ])
    let source = MemorySource(file)
    let parsed = try parse(ByteReader(source))
    #expect(parsed.metadata.tags.title == "After the picture")
    #expect(parsed.bytesRead < 3 * ByteReader.minimumReadBytes)
    #expect(parsed.readCount == source.reads.count)
}

@Test func mp4ReadsALACAboveTheSampleEntrysRateLimit() throws {
    let items =
        ilstItem("\u{A9}wrt", code: 1, ascii("Composer"))
        + ilstItem("gnre", code: 0, Data([0, 18]))
        + ilstItem("disk", code: 0, Data([0, 0, 0, 2, 0, 3]))
        + ilstItem("cpil", code: 21, Data([1]))
        + ilstItem("covr", code: 14, Data(repeating: 7, count: 33))
        + ilstItem("\u{A9}nam", code: 2, Data([0x00, 0x48, 0x00, 0x69]))
    let file = mp4File(
        moov(
            entry: alacEntry(rate: 192_000, channels: 2, bits: 24), timescale: 192_000,
            duration: 384_000, items: items))
    let metadata = try parse(file).metadata
    #expect(
        metadata.audio
            == TrackAudio(
                codec: .alac, sampleRateHz: 192_000, bitsPerSample: 24, channels: 2,
                lengthFrames: 384_000))
    #expect(metadata.tags.composer == "Composer")
    #expect(metadata.tags.genre == "Rock")
    #expect(metadata.tags.discNumber == 2)
    #expect(metadata.tags.discTotal == 3)
    #expect(metadata.tags.compilation)
    #expect(metadata.tags.title == "Hi")
    let art = try #require(metadata.art)
    #expect(art.mimeType == "image/png")
    #expect(Array(file[art.offset..<art.offset + art.byteCount]) == Array(repeating: 7, count: 33))
}

@Test func mp4FindsMoovAfterALargeMdatWithFewReads() throws {
    let file = mp4File(
        moov(
            entry: alacEntry(rate: 44_100, channels: 2, bits: 16), timescale: 44_100,
            duration: 4410, items: ilstItem("\u{A9}nam", code: 1, ascii("At the end"))),
        mdatBytes: 8 << 20, moovFirst: false)
    let parsed = try parse(file)
    #expect(parsed.metadata.tags.title == "At the end")
    #expect(parsed.bytesRead < 2 * ByteReader.minimumReadBytes)
    #expect(parsed.readCount == 2)
}

@Test func mp4ReadsAACFromItsAudioSpecificConfig() throws {
    // AAC LC (2), 48 kHz (index 3), stereo (2): 00010 0011 0010 000.
    let entry = mp4aEntry(audioSpecificConfig: [0x11, 0x90])
    let metadata = try parse(
        mp4File(moov(entry: entry, timescale: 48_000, duration: 96_000, items: nil))
    ).metadata
    #expect(
        metadata.audio
            == TrackAudio(
                codec: .aac, sampleRateHz: 48_000, bitsPerSample: nil, channels: 2,
                lengthFrames: 96_000))
    #expect(metadata.tags == TrackTags())
}

@Test func mp4ReadsAQuickTimeMetaWithoutVersionBytes() throws {
    let file = mp4File(
        moov(
            entry: alacEntry(rate: 44_100, channels: 2, bits: 16), timescale: 44_100,
            duration: 4410, items: ilstItem("aART", code: 1, ascii("Band")), fullBoxMeta: false))
    #expect(try parse(file).metadata.tags.albumArtist == "Band")
}

@Test func mp3ReadsTheXingFrameCount() throws {
    var first =
        Data(mpeg1Header) + Data(count: 32) + ascii("Xing") + bigEndian32(1)
        + bigEndian32(1000)
    first.append(Data(count: 417 - first.count))
    let metadata = try parse(first + mpegFrames(3)).metadata
    #expect(metadata.audio.lengthFrames == 1000 * 1152)
}

@Test func mp3ReadsTheVBRIFrameCount() throws {
    var first =
        Data(mpeg1Header) + Data(count: 32) + ascii("VBRI") + Data(count: 10)
        + bigEndian32(77)
    first.append(Data(count: 417 - first.count))
    #expect(try parse(first + mpegFrames(3)).metadata.audio.lengthFrames == 77 * 1152)
}

@Test func mp3ReadsMPEG2FramesAfterJunk() throws {
    let file =
        id3Tag([id3Frame("TIT2", id3Text("Two"))]) + Data(count: 5)
        + mpegFrames(20, header: mpeg2Header, length: 208)
    let metadata = try parse(file).metadata
    #expect(
        metadata.audio
            == TrackAudio(
                codec: .mp3, sampleRateHz: 22_050, bitsPerSample: nil, channels: 1,
                lengthFrames: 20 * 576))
    #expect(metadata.tags.title == "Two")
}

@Test func wavReadsExtensibleFormatAndLatin1Info() throws {
    var format = wavFormat(tag: 0xFFFE, channels: 2, rate: 96_000, bits: 32)
    format.appendLittleEndian(UInt16(22))
    format.appendLittleEndian(UInt16(24))
    format.appendLittleEndian(UInt32(3))
    format.appendLittleEndian(UInt16(1))
    format.append(Data(count: 14))
    let info = riffChunk(
        "LIST", ascii("INFO") + riffChunk("INAM", Data([0x43, 0x61, 0x66, 0xE9, 0]), .little),
        .little)
    let file = riffForm(
        "WAVE",
        chunks: riffChunk("fmt ", format, .little) + riffChunk("data", Data(count: 800), .little)
            + info, .little)
    let metadata = try parse(file).metadata
    #expect(
        metadata.audio
            == TrackAudio(
                codec: .pcm, sampleRateHz: 96_000, bitsPerSample: 24, channels: 2,
                lengthFrames: 100))
    #expect(metadata.tags.title == "Café")
}

@Test func wavPrefersID3OverInfo() throws {
    let info = riffChunk(
        "LIST",
        ascii("INFO") + riffChunk("INAM", ascii("Info title\0"), .little)
            + riffChunk("IART", ascii("Info artist\0"), .little), .little)
    let id3 = riffChunk("id3 ", id3Tag([id3Frame("TIT2", id3Text("ID3 title"))]), .little)
    let file = riffForm(
        "WAVE",
        chunks: riffChunk("fmt ", wavFormat(), .little) + riffChunk("data", Data(count: 4), .little)
            + info + id3, .little)
    let tags = try parse(file).metadata.tags
    #expect(tags.title == "ID3 title")
    #expect(tags.artist == "Info artist")
}

@Test func aifcReadsLittleEndianPCMAndRejectsCompression() throws {
    func aifc(_ compression: String) -> Data {
        riffForm(
            "AIFC",
            chunks: riffChunk(
                "COMM", aiffCommon(frames: 100, rate: 22_050) + ascii(compression) + Data([0, 0]),
                .big) + riffChunk("SSND", Data(count: 8), .big), .big)
    }
    let audio = try parse(aifc("sowt")).metadata.audio
    #expect(
        audio
            == TrackAudio(
                codec: .pcm, sampleRateHz: 22_050, bitsPerSample: 16, channels: 2,
                lengthFrames: 100))
    #expect(failure(aifc("ima4"))?.kind == .unsupported)
}

@Test func errorsNameThePathAndOffset() throws {
    let error = try withFile(flac([(0, streamInfo()), (4, Data(count: 3))])) { url in
        #expect(throws: MetadataError.self) { try readMetadata(at: url) }
    }
    #expect(error?.kind == .malformed)
    #expect(error?.offset == 42 + 4)
    #expect(error.map { "\($0)" }?.contains("at byte 46") == true)
    #expect(error.map { "\($0)" }?.hasPrefix(FileManager.default.temporaryDirectory.path) == true)
}

@Test func aMissingFileIsUnreadable() {
    let error = #expect(throws: MetadataError.self) {
        try readMetadata(at: URL(fileURLWithPath: "/nonexistent/song.flac"))
    }
    #expect(error?.kind == .unreadable)
}
