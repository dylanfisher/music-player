import Foundation
import Testing

@testable import Metadata
@testable import TagWriter

// The fields part 42g made editable, written, read back and undone in every format the writer
// handles, each in the key ADR 0101 names, spelled out here apart from the code.

/// The fields this file covers: every field but those phase 11 wrote.
private let extendedFields = TagEditField.allCases.filter {
    ![
        .title, .artist, .album, .albumArtist, .genre, .date, .composer, .comment, .trackNumber,
        .trackTotal, .discNumber, .discTotal, .compilation,
    ].contains($0)
}

/// A value each field takes: text with a non-ASCII letter, a number, or a Latin-1 URL.
private func value(_ field: TagEditField) -> String {
    switch field {
    case .bpm: "128"
    case .movementNumber: "2"
    case .movementTotal: "4"
    case .originalDate: "1969-09-26"
    case .lyrics: "First line\nSecond line, Perälä"
    case .artistURL, .audioFileURL, .audioSourceURL, .commercialURL, .copyrightURL, .paymentURL,
        .publisherURL, .radioStationURL:
        "https://example.com/\(field.rawValue)"
    default: "\(field.rawValue) Perälä"
    }
}

/// The key each field is found under in the layout of a written file: the Vorbis key, the MP4
/// item (`----:com.apple.iTunes:NAME` for a freeform one), and the ID3 frame in 2.4 and 2.3.
private let expectedKeys:
    [TagEditField: (vorbis: String, mp4: String, id3v24: String, id3v23: String)] = [
        .grouping: ("GROUPING", "\u{A9}grp", "TIT1", "TIT1"),
        .bpm: ("BPM", "tmpo", "TBPM", "TBPM"),
        .key: ("KEY", "----:com.apple.iTunes:initialkey", "TKEY", "TKEY"),
        .conductor: ("CONDUCTOR", "----:com.apple.iTunes:CONDUCTOR", "TPE3", "TPE3"),
        .lyricist: ("LYRICIST", "----:com.apple.iTunes:LYRICIST", "TEXT", "TEXT"),
        .remixer: ("REMIXER", "----:com.apple.iTunes:REMIXER", "TPE4", "TPE4"),
        .originalArtist: ("ORIGINALARTIST", "----:com.apple.iTunes:ORIGINALARTIST", "TOPE", "TOPE"),
        .publisher: ("LABEL", "----:com.apple.iTunes:LABEL", "TPUB", "TPUB"),
        .copyright: ("COPYRIGHT", "cprt", "TCOP", "TCOP"),
        .catalogNumber: ("CATALOGNUMBER", "----:com.apple.iTunes:CATALOGNUMBER", "TXXX", "TXXX"),
        .barcode: ("BARCODE", "----:com.apple.iTunes:BARCODE", "TXXX", "TXXX"),
        .isrc: ("ISRC", "----:com.apple.iTunes:ISRC", "TSRC", "TSRC"),
        .encoder: ("ENCODEDBY", "\u{A9}too", "TENC", "TENC"),
        .description: ("DESCRIPTION", "desc", "TXXX", "TXXX"),
        .discSubtitle: ("DISCSUBTITLE", "----:com.apple.iTunes:DISCSUBTITLE", "TSST", "TXXX"),
        .work: ("WORK", "\u{A9}wrk", "TXXX", "TXXX"),
        .movementNumber: ("MOVEMENT", "\u{A9}mvi", "MVIN", "MVIN"),
        .movementTotal: ("MOVEMENTTOTAL", "\u{A9}mvc", "MVIN", "MVIN"),
        .movementName: ("MOVEMENTNAME", "\u{A9}mvn", "MVNM", "MVNM"),
        .originalDate: ("ORIGINALDATE", "----:com.apple.iTunes:ORIGINALDATE", "TDOR", "TXXX"),
        .originalAlbum: ("ORIGINALALBUM", "----:com.apple.iTunes:ORIGINALALBUM", "TOAL", "TOAL"),
        .language: ("LANGUAGE", "----:com.apple.iTunes:LANGUAGE", "TLAN", "TLAN"),
        .mood: ("MOOD", "----:com.apple.iTunes:MOOD", "TMOO", "TXXX"),
        .media: ("MEDIA", "----:com.apple.iTunes:MEDIA", "TMED", "TMED"),
        .lyrics: ("LYRICS", "\u{A9}lyr", "USLT", "USLT"),
        .titleSort: ("TITLESORT", "sonm", "TSOT", "TSOT"),
        .artistSort: ("ARTISTSORT", "soar", "TSOP", "TSOP"),
        .albumSort: ("ALBUMSORT", "soal", "TSOA", "TSOA"),
        .albumArtistSort: ("ALBUMARTISTSORT", "soaa", "TSO2", "TSO2"),
        .composerSort: ("COMPOSERSORT", "soco", "TSOC", "TSOC"),
        .artistURL: ("WWWARTIST", "----:com.apple.iTunes:WWWARTIST", "WOAR", "WOAR"),
        .audioFileURL: ("WWWAUDIOFILE", "----:com.apple.iTunes:WWWAUDIOFILE", "WOAF", "WOAF"),
        .audioSourceURL: ("WWWAUDIOSOURCE", "----:com.apple.iTunes:WWWAUDIOSOURCE", "WOAS", "WOAS"),
        .commercialURL: (
            "WWWCOMMERCIALINFO", "----:com.apple.iTunes:WWWCOMMERCIALINFO", "WCOM", "WCOM"
        ),
        .copyrightURL: ("WWWCOPYRIGHT", "----:com.apple.iTunes:WWWCOPYRIGHT", "WCOP", "WCOP"),
        .paymentURL: ("WWWPAYMENT", "----:com.apple.iTunes:WWWPAYMENT", "WPAY", "WPAY"),
        .publisherURL: ("WWWPUBLISHER", "----:com.apple.iTunes:WWWPUBLISHER", "WPUB", "WPUB"),
        .radioStationURL: ("WWWRADIOPAGE", "----:com.apple.iTunes:WWWRADIOPAGE", "WORS", "WORS"),
    ]

/// The file's tag version, which picks the expected ID3 frame.
private func expectedKey(_ field: TagEditField, _ sample: Sample) throws -> String {
    let keys = try #require(expectedKeys[field], "\(field) has an expected key")
    switch sample {
    case .flac, .flacWithArt: return "vorbisComment/" + keys.vorbis
    case .mp4, .mp4WithArt: return "moov/udta/meta/ilst/" + keys.mp4
    case .aiffV23: return "ID3 /" + keys.id3v23
    case .aiffV24: return "ID3 /" + keys.id3v24
    case .wavID3: return "id3 /" + keys.id3v23
    case .mp3v23, .mp3v23WithArt: return "ID3/" + keys.id3v23
    default: return "ID3/" + keys.id3v24
    }
}

private let writtenSamples: [Sample] = [.flac, .mp4, .mp3v23, .mp3v24, .aiffV23, .aiffV24, .wavID3]

@Test func everyFieldHasAnExpectedKey() {
    #expect(Set(expectedKeys.keys) == Set(extendedFields))
}

@Test(arguments: writtenSamples)
func everyExtendedFieldIsWrittenInItsKeyReadBackClearedAndUndone(_ sample: Sample) throws {
    let url = try sample.copy()
    let pristine = try scratchCopy(of: url)
    let original = try Data(contentsOf: url)
    let originalTags = try tags(url)
    let writer = scratchWriter()

    let edit = TagEdit(
        values: Dictionary(uniqueKeysWithValues: extendedFields.map { ($0, value($0)) }))
    expectChanged(writer.write(edit, to: [url.path]), [url])
    let written = try tags(url)
    #expect(written == (try edit.applied(to: originalTags)))
    #expect(written.lyrics == value(.lyrics), "lines kept")
    #expect(written.movementTotal == 4)
    let layout = try readTagLayout(at: url)
    for field in extendedFields {
        let key = try expectedKey(field, sample)
        #expect(
            layout.blocks.contains { $0.path == key && $0.fields.contains(field) },
            "\(field) in \(key): \(layout.blocks.map(\.path))")
    }
    #expect(try untouchedBlockDifferences(original: pristine, edited: url, edit: edit) == [])

    let cleared = TagEdit(values: Dictionary(uniqueKeysWithValues: extendedFields.map { ($0, "") }))
    expectChanged(writer.write(cleared, to: [url.path]), [url])
    #expect(try tags(url) == (try cleared.applied(to: written)))
    #expect(
        try readTagLayout(at: url).blocks.allSatisfy { $0.fields.isDisjoint(with: extendedFields) })

    expectChanged(writer.undoLast(), [url])
    expectChanged(writer.undoLast(), [url])
    #expect(try Data(contentsOf: url) == original)
}

@Test(arguments: [Sample.mp3v23, .aiffV23])
func anOriginalYearGoesInID3v23sYearFrame(_ sample: Sample) throws {
    let url = try sample.copy()
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.originalDate: "1969"]), to: [url.path]), [url])
    #expect(try tags(url).originalDate == "1969")
    #expect(try readTagLayout(at: url).blocks.contains { $0.path.hasSuffix("/TORY") })
}

@Test func aGroupingEditStaysInITunesGroupingFrame() throws {
    let url = try mp3(
        withTag: id3Tag(
            [
                id3TextFrame("GRP1", "Old grouping", version: 4),
                id3TextFrame("TIT1", "A work in iTunes's place", version: 4),
            ], version: 4))
    let writer = scratchWriter()
    expectChanged(writer.write(TagEdit(values: [.grouping: "New"]), to: [url.path]), [url])
    #expect(try tags(url).grouping == "New")
    let paths = try readTagLayout(at: url).blocks.map(\.path)
    #expect(paths.contains("ID3/GRP1") && paths.contains("ID3/TIT1"), "\(paths)")
}

@Test func id3RefusesAURLOutsideLatin1AndFLACTakesIt() throws {
    let url = try Sample.mp3v24.copy()
    let original = try Data(contentsOf: url)
    let edit = TagEdit(values: [.artistURL: "https://example.com/日本"])
    let report = scratchWriter().write(edit, to: [url.path])
    #expect(report.failures.map(\.kind) == [.unsupported])
    #expect(try Data(contentsOf: url) == original)

    let flac = try Sample.flac.copy()
    expectChanged(scratchWriter().write(edit, to: [flac.path]), [flac])
    #expect(try tags(flac).artistURL == "https://example.com/日本")
}

@Test func aDescribedLyricsFrameIsAPlayersAndStays() throws {
    let described = try ID3Frame(
        id: "USLT", body: [0] + Array("eng".utf8) + Array("Karaoke".utf8) + [0] + Array("La".utf8),
        version: 4)
    let url = try mp3(withTag: id3Tag([described.raw], version: 4))
    #expect(try tags(url).lyrics == nil)
    expectChanged(scratchWriter().write(TagEdit(values: [.lyrics: "Words"]), to: [url.path]), [url])
    #expect(try tags(url).lyrics == "Words")
    #expect(try readTagLayout(at: url).blocks.filter { $0.path == "ID3/USLT" }.count == 2)
}
