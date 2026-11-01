import Foundation
import Testing

@testable import Fixtures
@testable import Metadata

/// An MP3 with `tag` in front of a few frames.
private func mp3(_ tag: Data) -> Data { tag + mpegFrames(4) }

/// An image with bytes that unsynchronisation escapes.
private let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0x00, 0xFF])

private func apic(_ type: UInt8 = 3, description: String = "", encoding: UInt8 = 0) -> Data {
    Data([encoding]) + ascii("image/jpeg\0") + Data([type])
        + id3Text(description, encoding: encoding).dropFirst()
        + (encoding == 1 || encoding == 2 ? Data([0, 0]) : Data([0])) + image
}

/// Reads the art back through the file entry points.
private func artBytes(_ file: Data) throws -> Data? {
    try withFile(file) { url in
        try readMetadata(at: url).metadata.art.map { try readArt($0, at: url) }
    }
}

@Test func readsEveryVersionsFrameIDs() throws {
    for version: UInt8 in [2, 3, 4] {
        let ids =
            version == 2
            ? ["TT2", "TP1", "TAL", "TP2", "TCM", "TRK", "TPA", "TCP"]
            : ["TIT2", "TPE1", "TALB", "TPE2", "TCOM", "TRCK", "TPOS", "TCMP"]
        let values = ["Title", "Artist", "Album", "Album Artist", "Composer", "4/10", "2/2", "1"]
        let frames = zip(ids, values).map { id3Frame($0, id3Text($1), version: version) }
        let tags = try parse(mp3(id3Tag(version: version, frames))).metadata.tags
        #expect(
            tags
                == TrackTags(
                    title: "Title", artist: "Artist", album: "Album", albumArtist: "Album Artist",
                    trackNumber: 4, trackTotal: 10, discNumber: 2, discTotal: 2, compilation: true,
                    composer: "Composer"),
            "ID3v2.\(version)")
    }
}

@Test func decodesEveryTextEncoding() throws {
    for encoding: UInt8 in [0, 1, 2, 3] {
        let text = encoding == 0 ? "Café" : "東京 Café 💃"
        let tag = id3Tag(
            version: 4, [id3Frame("TIT2", id3Text(text, encoding: encoding), version: 4)])
        #expect(try parse(mp3(tag)).metadata.tags.title == text, "encoding \(encoding)")
    }
}

@Test func takesTheFirstOfSeveralValues() throws {
    let tag = id3Tag(version: 4, [id3Frame("TPE1", id3Text("One\0Two", encoding: 3), version: 4)])
    #expect(try parse(mp3(tag)).metadata.tags.artist == "One")
}

@Test func resolvesGenreReferences() throws {
    let cases: [(UInt8, String, String)] = [
        (3, "(17)", "Rock"), (3, "(17)Rocking", "Rocking"),
        (3, "((Not a reference)", "(Not a reference)"),
        (3, "(RX)", "Remix"), (4, "52", "Electronic"), (3, "52", "52"), (4, "Shoegaze", "Shoegaze"),
    ]
    for (version, text, expected) in cases {
        let tag = id3Tag(version: version, [id3Frame("TCON", id3Text(text), version: version)])
        #expect(try parse(mp3(tag)).metadata.tags.genre == expected, "\(text)")
    }
    let bad = try parse(mp3(id3Tag([id3Frame("TCON", id3Text("(999)"))])))
    #expect(bad.metadata.tags.genre == nil)
    #expect(bad.warnings.map(\.kind) == [.unreadableField])
}

@Test func usesTheFirstOfSeveralGenreReferencesAndKeepsCustomNumbers() throws {
    let cases: [(UInt8, String, String)] = [
        (3, "(51)(39)", id3v1Genres[51]), (3, "(51)(39)Noisy", "Noisy"),
        (3, "(51)(RX)", id3v1Genres[51]), (4, "2000", "2000"), (4, "256", "256"),
    ]
    for (version, text, expected) in cases {
        let tag = id3Tag(version: version, [id3Frame("TCON", id3Text(text), version: version)])
        let parsed = try parse(mp3(tag))
        #expect(parsed.metadata.tags.genre == expected, "\(text)")
        #expect(parsed.warnings.isEmpty, "\(text)")
    }
}

@Test func readsOnlyTheUndescribedComment() throws {
    let described = Data([0]) + ascii("engiTunNORM\0 000001")
    let plain = Data([0]) + ascii("eng\0Liner notes")
    let tag = id3Tag([id3Frame("COMM", described), id3Frame("COMM", plain)])
    #expect(try parse(mp3(tag)).metadata.tags.comment == "Liner notes")
}

@Test func skipsTheExtendedHeader() throws {
    let v3 = id3Tag(
        version: 3, flags: 0x40, [id3Frame("TIT2", id3Text("Three"))],
        extendedHeader: bigEndian32(6) + Data(count: 6))
    #expect(try parse(mp3(v3)).metadata.tags.title == "Three")
    var size = Data()
    size.appendSyncsafe(6)
    let v4 = id3Tag(
        version: 4, flags: 0x40, [id3Frame("TIT2", id3Text("Four"), version: 4)],
        extendedHeader: size + Data([1, 0]))
    #expect(try parse(mp3(v4)).metadata.tags.title == "Four")
}

@Test func skipsTheFooterToFindTheAudio() throws {
    let tag = id3Tag(version: 4, flags: 0x10, [id3Frame("TIT2", id3Text("Footed"), version: 4)])
    let metadata = try parse(mp3(tag)).metadata
    #expect(metadata.tags.title == "Footed")
    #expect(metadata.audio.lengthFrames == 4 * 1152)
}

@Test func readsAWholeUnsynchronisedTagAndItsArt() throws {
    let tag = id3Tag(
        version: 3, flags: 0x80,
        [id3Frame("TIT2", id3Text("ÿÿ escaped")), id3Frame("APIC", apic())], padding: 10)
    let file = mp3(tag)
    let metadata = try parse(file).metadata
    #expect(metadata.tags.title == "ÿÿ escaped")
    let art = try #require(metadata.art)
    #expect(art.unsynchronised)
    #expect(art.byteCount > image.count)
    #expect(try artBytes(file) == image)
}

@Test func readsAnUnsynchronisedFrameWithADataLengthIndicator() throws {
    var length = Data()
    length.appendSyncsafe(image.count)
    // Format flags: grouping (0x40), unsynchronisation (0x02), data length indicator (0x01).
    let body = Data([7]) + length + unsynchronise(apic(description: "ÿ", encoding: 1))
    let tag = id3Tag(
        version: 4,
        [
            id3Frame("TIT2", id3Text("Four"), version: 4),
            id3Frame("APIC", body, version: 4, flags: 0x43),
        ])
    #expect(try artBytes(mp3(tag)) == image)
}

@Test func prefersTheFrontCover() throws {
    let tag = id3Tag([id3Frame("APIC", apic(4)), id3Frame("APIC", apic(3, description: "front"))])
    let file = mp3(tag)
    let art = try #require(try parse(file).metadata.art)
    let front = try #require(file.range(of: ascii("front\0")))
    #expect(art.offset == front.upperBound)
}

@Test func mapsID3v22PictureFormats() throws {
    let pic = Data([0]) + ascii("PNG") + Data([3, 0]) + image
    let art = try #require(
        try parse(mp3(id3Tag(version: 2, [id3Frame("PIC", pic, version: 2)]))).metadata.art)
    #expect(art.mimeType == "image/png")
    #expect(art.byteCount == image.count)
}

@Test func readsATagInsideAnAIFFChunk() throws {
    let tag = id3Tag(version: 4, [id3Frame("TIT2", id3Text("In a chunk"), version: 4)])
    let file = riffForm(
        "AIFF",
        chunks: riffChunk("COMM", aiffCommon(), .big) + riffChunk("SSND", Data(count: 8), .big)
            + riffChunk("ID3 ", tag, .big), .big)
    #expect(try parse(file).metadata.tags.title == "In a chunk")
}

@Test func skipsCompressedFramesWithAWarning() throws {
    let compressed = try parse(
        mp3(
            id3Tag([id3Frame("TIT2", id3Text("x"), flags: 0x0080), id3Frame("TPE1", id3Text("A"))]))
    )
    #expect(compressed.metadata.tags.title == nil)
    #expect(compressed.metadata.tags.artist == "A")
    #expect(compressed.warnings.map(\.kind) == [.unreadableField])
    #expect(compressed.warnings.first?.offset == 10)
    let unneeded = id3Tag([
        id3Frame("TSSE", id3Text("x"), flags: 0x0080), id3Frame("TIT2", id3Text("Kept")),
    ])
    #expect(try warnings(mp3(unneeded)).isEmpty)
}

@Test func anInvalidFrameIDEndsTheTagWithAWarning() throws {
    let tag = id3Tag([id3Frame("TIT2", id3Text("Kept")), id3Frame("ti!2", id3Text("x"))])
    let parsed = try parse(mp3(tag))
    #expect(parsed.metadata.tags.title == "Kept")
    #expect(parsed.metadata.audio.lengthFrames == 4 * 1152)
    #expect(parsed.warnings.map(\.kind) == [.unreadableField])
}

@Test func structuralID3DamageStillFails() {
    var notSyncsafe = id3Tag(version: 4, [id3Frame("TIT2", id3Text("x"), version: 4)])
    notSyncsafe[14] = 0x80
    #expect(failure(mp3(notSyncsafe))?.kind == .malformed)
    var pastTag = id3Tag([id3Frame("TIT2", id3Text("x"))])
    pastTag.replaceBigEndian(1000, at: 14)
    #expect(failure(mp3(pastTag))?.kind == .malformed)
    #expect(failure(mp3(id3Tag(version: 5, []))).map(\.kind) == .unsupported)
}

/// A v2.4 frame whose size iTunes wrote as a plain integer: for 200 bytes the syncsafe reading
/// is 328, which lands mid-frame, while the plain reading lands on the next frame.
private func iTunesFrame(_ id: String, _ body: Data) -> Data {
    ascii(id) + bigEndian32(body.count) + Data([0, 0]) + body
}

@Test func readsITunesPlainFrameSizes() throws {
    let long = String(repeating: "x", count: 199)
    let tag = id3Tag(
        version: 4,
        [
            iTunesFrame("TIT2", id3Text(long, encoding: 3)),
            id3Frame("TPE1", id3Text("After", encoding: 3), version: 4),
        ])
    let parsed = try parse(mp3(tag))
    #expect(parsed.metadata.tags.title == long)
    #expect(parsed.metadata.tags.artist == "After")
    #expect(parsed.warnings.map(\.kind) == [.nonSyncsafeFrameSize])
    #expect(parsed.warnings.first?.offset == 14)
}

@Test func keepsTheSyncsafeSizeWhenItLandsOnAFrame() throws {
    // 0x0101 as syncsafe is 129: the frame below is exactly that long.
    let body = id3Text(String(repeating: "y", count: 128), encoding: 3)
    let frame = ascii("TIT2") + Data([0, 0, 1, 1, 0, 0]) + body
    let parsed = try parse(
        mp3(id3Tag(version: 4, [frame, id3Frame("TPE1", id3Text("B"), version: 4)])))
    #expect(parsed.metadata.tags.artist == "B")
    #expect(parsed.warnings.isEmpty)
}

@Test func badFieldValuesAreDroppedOrPartlyReadWithWarnings() throws {
    let tag = id3Tag(
        version: 4,
        [
            id3Frame("TRCK", id3Text("A1"), version: 4),
            id3Frame("TPOS", id3Text(" 01/12 "), version: 4),
            id3Frame("TCMP", id3Text("yes"), version: 4),
            id3Frame("TIT2", Data([3, 0x43, 0x61, 0x66, 0xE9]), version: 4),
            id3Frame("TPE1", Data([1, 0x41, 0x00, 0x42, 0x00]), version: 4),
            id3Frame("TALB", Data([2, 0xD8, 0x00]), version: 4),
        ])
    let parsed = try parse(mp3(tag))
    let tags = parsed.metadata.tags
    #expect(tags.trackNumber == nil)
    #expect(tags.discNumber == 1)
    #expect(tags.discTotal == 12)
    #expect(!tags.compilation)
    #expect(tags.title == "Café")
    #expect(tags.artist == "AB")
    #expect(tags.album == "\u{FFFD}")
    #expect(parsed.warnings.map(\.kind) == [.badNumber, .badValue, .badText, .badText, .badText])
    #expect(parsed.warnings.allSatisfy { $0.offset > 10 })
}
