import Foundation
import Testing

@testable import Fixtures
@testable import Metadata

// Keys no field maps, read by name in each format (ADR 0129).

/// What every file below holds: two Discogs keys, one spelled in lowercase in the file.
private let expectedCustom = [
    "DISCOGS_RELEASE_ID": "1234567", "DISCOGS_MASTER_ID": "m744074",
]

private let mp3Rest = mpegFrames(4)

@Test func vorbisReadsUnmappedKeysByNameUppercasedAndTheFirstValueWins() throws {
    let comments = vorbisComment([
        "TITLE=Song", "DISCOGS_RELEASE_ID=1234567", "discogs_master_id=m744074",
        "DISCOGS_RELEASE_ID=7654321", "EMPTY=",
    ])
    let parsed = try parse(flac([(0, streamInfo()), (4, comments)]))
    #expect(parsed.metadata.tags.title == "Song")
    #expect(parsed.metadata.tags.custom == expectedCustom)
    #expect(parsed.warnings.isEmpty)
}

@Test func vorbisReadsACustomValueUpToANULWithAWarning() throws {
    let comments = vorbisComment(["DISCOGS_RELEASE_ID=1234567\u{0}junk"])
    let parsed = try parse(flac([(0, streamInfo()), (4, comments)]))
    #expect(parsed.metadata.tags.custom == ["DISCOGS_RELEASE_ID": "1234567"])
    #expect(parsed.warnings.map(\.kind) == [.badText])
}

@Test func id3ReadsUnmappedUserTextInEachVersion() throws {
    for version: UInt8 in [2, 3, 4] {
        let id = version == 2 ? "TXX" : "TXXX"
        let encoding: UInt8 = version == 4 ? 3 : 0
        let frames = [
            id3Frame(
                id, Data([encoding]) + ascii("DISCOGS_RELEASE_ID\u{0}1234567"), version: version),
            id3Frame(
                id, Data([encoding]) + ascii("Discogs_Master_Id\u{0}m744074"), version: version),
            id3Frame(id, Data([0]) + ascii("CATALOGNUMBER\u{0}CAT-001"), version: version),
        ]
        let tags = try parse(id3Tag(version: version, frames) + mp3Rest).metadata.tags
        #expect(tags.custom == expectedCustom, "ID3v2.\(version)")
        #expect(tags.catalogNumber == "CAT-001", "ID3v2.\(version)")
    }
}

@Test func mp4ReadsITunesFreeformTextItemsButNotOtherMeansOrBinaryData() throws {
    func freeform(_ mean: String, _ name: String, type: Int = 1, _ value: Data) -> Data {
        atom(
            "----",
            fullBox("mean", ascii(mean)) + fullBox("name", ascii(name))
                + atom("data", bigEndian32(type) + bigEndian32(0) + value))
    }
    let items = [
        freeform("com.apple.iTunes", "DISCOGS_RELEASE_ID", ascii("1234567")),
        freeform("com.apple.iTunes", "discogs_master_id", ascii("m744074")),
        freeform("org.example", "OTHER", ascii("not iTunes's")),
        freeform("com.apple.iTunes", "BINARY", type: 0, Data([1, 2, 3])),
        freeform(
            "com.apple.iTunes", "iTunSMPB", ascii(" 00000000 00000840 00000000 0000000000000E10")),
    ]
    let file = mp4File(
        moov(
            entry: alacEntry(rate: 44_100, channels: 2, bits: 16), timescale: 44_100,
            duration: 4410, items: items.reduce(Data(), +)))
    let parsed = try parse(file)
    #expect(parsed.metadata.tags.custom == expectedCustom)
    #expect(parsed.warnings.isEmpty)
}

@Test func fillingTakesTheOtherTagsCustomKeysAndKeepsItsOwn() throws {
    var tags = TrackTags()
    tags.custom = ["A": "id3"]
    var info = TrackTags()
    info.custom = ["A": "info", "B": "info"]
    #expect(tags.filling(from: info).custom == ["A": "id3", "B": "info"])
}
