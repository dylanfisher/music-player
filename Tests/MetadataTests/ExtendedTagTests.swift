import Foundation
import Testing

@testable import Fixtures
@testable import Metadata

// Each format's keys for the fields added in phase 16, as MusicBrainz Picard maps them (ADR 0006).

/// Every added field set, as each format below writes it.
private let expected: TrackTags = {
    var tags = TrackTags()
    tags.grouping = "Grouping"
    tags.catalogNumber = "CAT-001"
    tags.barcode = "0123456789012"
    tags.bpm = 128
    tags.key = "Am"
    tags.conductor = "Conductor"
    tags.lyricist = "Lyricist"
    tags.publisher = "Label"
    tags.copyright = "℗ 2001"
    tags.encoder = "Encoder"
    tags.description = "Description"
    tags.discSubtitle = "Disc Subtitle"
    tags.work = "Work"
    tags.movementNumber = 2
    tags.movementName = "Movement"
    tags.originalDate = "1969-09-26"
    return tags
}()

/// The fields ID3 has no Picard key for.
private var expectedID3: TrackTags {
    var tags = expected
    tags.description = nil
    return tags
}

private let mp3Rest = mpegFrames(4)

@Test func flacReadsEveryAddedField() throws {
    let comments = vorbisComment([
        "GROUPING=Grouping", "CATALOGNUMBER=CAT-001", "BARCODE=0123456789012", "BPM=127.9",
        "KEY=Am", "CONDUCTOR=Conductor", "LYRICIST=Lyricist", "LABEL=Label",
        "COPYRIGHT=℗ 2001", "ENCODEDBY=Encoder", "DESCRIPTION=Description",
        "DISCSUBTITLE=Disc Subtitle", "WORK=Work", "MOVEMENT=2", "MOVEMENTNAME=Movement",
        "ORIGINALDATE=1969-09-26",
    ])
    let parsed = try parse(flac([(0, streamInfo()), (4, comments)]))
    #expect(parsed.metadata.tags == expected)
    #expect(parsed.warnings.isEmpty)
}

@Test func vorbisReadsPublisherAsTheLabelAndKeepsDescriptionApartFromTheComment() throws {
    let comments = vorbisComment(["PUBLISHER=Imprint", "COMMENT=Note", "DESCRIPTION=About"])
    let tags = try parse(flac([(0, streamInfo()), (4, comments)])).metadata.tags
    #expect(tags.publisher == "Imprint")
    #expect(tags.comment == "Note")
    #expect(tags.description == "About")
}

private func id3Frames(version: UInt8) -> [Data] {
    func text(_ id: String, _ value: String) -> Data {
        id3Frame(id, id3Text(value, encoding: version == 4 ? 3 : 1), version: version)
    }
    func user(_ description: String, _ value: String) -> Data {
        id3Frame(
            "TXXX", Data([0]) + ascii(description) + Data([0]) + ascii(value), version: version)
    }
    return [
        text("TIT1", "Grouping"), user("CATALOGNUMBER", "CAT-001"),
        user("Barcode", "0123456789012"), text("TBPM", "128"), text("TKEY", "Am"),
        text("TPE3", "Conductor"), text("TEXT", "Lyricist"), text("TPUB", "Label"),
        text("TCOP", "℗ 2001"), text("TENC", "Encoder"), text("TSST", "Disc Subtitle"),
        user("WORK", "Work"), text("MVIN", "2/4"), text("MVNM", "Movement"),
        text(version == 4 ? "TDOR" : "TORY", "1969-09-26"),
    ]
}

@Test func id3v24ReadsEveryAddedFieldButDescription() throws {
    let tags = try parse(id3Tag(version: 4, id3Frames(version: 4)) + mp3Rest).metadata.tags
    #expect(tags == expectedID3)
}

@Test func id3v23InAnAIFFChunkReadsEveryAddedFieldButDescription() throws {
    let file = riffForm(
        "AIFF",
        chunks: riffChunk("COMM", aiffCommon(), .big) + riffChunk("SSND", Data(count: 8), .big)
            + riffChunk("ID3 ", id3Tag(version: 3, id3Frames(version: 3)), .big), .big)
    #expect(try parse(file).metadata.tags == expectedID3)
}

@Test func id3v22ReadsItsThreeLetterFrames() throws {
    func text(_ id: String, _ value: String) -> Data { id3Frame(id, id3Text(value), version: 2) }
    let frames = [
        text("TT1", "Grouping"), text("TBP", "128"), text("TKE", "Am"), text("TP3", "Conductor"),
        text("TXT", "Lyricist"), text("TPB", "Label"), text("TCR", "Copyright"),
        text("TEN", "Encoder"), text("TOR", "1969"),
        id3Frame("TXX", Data([0]) + ascii("CATALOGNUMBER\0CAT-001"), version: 2),
    ]
    let tags = try parse(id3Tag(version: 2, frames) + mp3Rest).metadata.tags
    #expect(tags.grouping == "Grouping")
    #expect(tags.bpm == 128)
    #expect(tags.key == "Am")
    #expect(tags.conductor == "Conductor")
    #expect(tags.lyricist == "Lyricist")
    #expect(tags.publisher == "Label")
    #expect(tags.copyright == "Copyright")
    #expect(tags.encoder == "Encoder")
    #expect(tags.originalDate == "1969")
    #expect(tags.catalogNumber == "CAT-001")
}

@Test func id3PrefersITunesGroupingOverTheContentGroupWhereverItIs() throws {
    let frames = [
        id3Frame("TIT1", id3Text("Work in TIT1")), id3Frame("GRP1", id3Text("Grouping")),
    ]
    #expect(try parse(id3Tag(frames) + mp3Rest).metadata.tags.grouping == "Grouping")
}

@Test func id3SkipsUnknownUserTextAndWarnsOnOneWithoutATerminator() throws {
    let frames = [
        id3Frame("TXXX", Data([0]) + ascii("MOOD\0calm")),
        id3Frame("TXXX", Data([0]) + ascii("BARCODE")),
        id3Frame("TXXX", Data([0]) + ascii("Barcode\0123")),
    ]
    let parsed = try parse(id3Tag(frames) + mp3Rest)
    #expect(parsed.metadata.tags.barcode == "123")
    #expect(parsed.warnings.map(\.kind) == [.unreadableField])
}

@Test func mp4ReadsEveryAddedField() throws {
    func freeform(_ name: String, _ value: String) -> Data {
        atom(
            "----",
            fullBox("mean", ascii("com.apple.iTunes")) + fullBox("name", ascii(name))
                + atom("data", bigEndian32(1) + bigEndian32(0) + Data(value.utf8)))
    }
    func text(_ type: String, _ value: String) -> Data {
        ilstItem(type, code: 1, Data(value.utf8))
    }
    var bpm = Data()
    bpm.appendBigEndian(UInt16(128))
    var movement = Data()
    movement.appendBigEndian(UInt16(2))
    let items: [Data] = [
        text("\u{A9}grp", "Grouping"), freeform("CATALOGNUMBER", "CAT-001"),
        freeform("BARCODE", "0123456789012"), ilstItem("tmpo", code: 21, bpm),
        freeform("initialkey", "Am"), freeform("CONDUCTOR", "Conductor"),
        freeform("LYRICIST", "Lyricist"), freeform("LABEL", "Label"), text("cprt", "℗ 2001"),
        text("\u{A9}too", "Encoder"), text("desc", "Description"),
        freeform("DISCSUBTITLE", "Disc Subtitle"), text("\u{A9}wrk", "Work"),
        ilstItem("\u{A9}mvi", code: 21, movement), text("\u{A9}mvn", "Movement"),
        freeform("ORIGINALDATE", "1969-09-26"),
    ]
    let file = mp4File(
        moov(
            entry: alacEntry(rate: 44_100, channels: 2, bits: 16), timescale: 44_100,
            duration: 4410, items: items.reduce(Data(), +)))
    let parsed = try parse(file)
    #expect(parsed.metadata.tags == expected)
    #expect(parsed.warnings.isEmpty)
}

@Test func aMalformedIntegerItemIsAWarningAndTheOtherTagsAreKept() throws {
    var movement = Data()
    movement.appendBigEndian(UInt16(2))
    let cases: [(String, Data)] = [
        ("text type", ilstItem("tmpo", code: 1, ascii("128"))),
        ("nine bytes", ilstItem("tmpo", code: 21, Data(count: 9))),
        ("empty", ilstItem("\u{A9}mvi", code: 21, Data())),
    ]
    for (name, bad) in cases {
        let items =
            ilstItem("\u{A9}nam", code: 1, ascii("Kept")) + bad
            + ilstItem("\u{A9}mvi", code: 21, movement) + ilstItem("\u{A9}grp", code: 1, ascii("G"))
        let file = mp4File(
            moov(
                entry: alacEntry(rate: 44_100, channels: 2, bits: 16), timescale: 44_100,
                duration: 4410, items: items))
        let parsed = try parse(file)
        #expect(parsed.metadata.tags.title == "Kept", "\(name)")
        #expect(parsed.metadata.tags.grouping == "G", "\(name)")
        #expect(parsed.metadata.tags.bpm == nil, "\(name)")
        #expect(parsed.metadata.tags.movementNumber == 2, "\(name)")
        #expect(parsed.warnings.map(\.kind) == [.unreadableField], "\(name)")
    }
}

@Test func wavReadsCopyrightFromInfoAndTheRestFromID3() throws {
    let info = riffChunk(
        "LIST", ascii("INFO") + riffChunk("ICOP", ascii("Info copyright\0"), .little), .little)
    let id3 = riffChunk("id3 ", id3Tag(id3Frames(version: 3)), .little)
    let file = riffForm(
        "WAVE",
        chunks: riffChunk("fmt ", wavFormat(), .little) + riffChunk("data", Data(count: 4), .little)
            + info + id3, .little)
    #expect(try parse(file).metadata.tags == expectedID3)
    let infoOnly = riffForm(
        "WAVE",
        chunks: riffChunk("fmt ", wavFormat(), .little) + riffChunk("data", Data(count: 4), .little)
            + info, .little)
    #expect(try parse(infoOnly).metadata.tags.copyright == "Info copyright")
}

@Test func aTempoThatIsNotANumberIsDroppedWithAWarningAndNothingIsGuessed() throws {
    let comments = vorbisComment(["BPM=fast", "MOVEMENT=II"])
    let parsed = try parse(flac([(0, streamInfo()), (4, comments)]))
    #expect(parsed.metadata.tags == TrackTags())
    #expect(parsed.warnings.map(\.kind) == [.badNumber, .badNumber])
}
