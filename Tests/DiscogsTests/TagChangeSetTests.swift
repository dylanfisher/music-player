import Foundation
import TagWriter
import Testing

@testable import Discogs
@testable import Metadata
@testable import Settings

// What a mapping writes for a match (ADR 0132), worked out without reading or writing files.

private let oneToOne = DiscogsPreset.oneToOne.mapping

private let twoDiscs = CatalogRelease(
    id: 100, masterID: 7, title: "Live", artists: [artist(1, "Band (3)", anv: "The Band")],
    labels: [label(5, "Label (2)", "CAT 1"), label(6, "Other", "OTH 2")],
    formats: [format("CD", ["Album"]), format("DVD")], country: "Europe",
    released: "1999-03-00", genres: ["Rock", "Pop"], styles: ["Indie Rock"],
    barcodes: ["0123", "0456"],
    credits: [
        CatalogCredit(id: 9, name: "Pat", role: "Producer, Recorded By [Live]"),
        CatalogCredit(id: 10, name: "Sam", role: "Written-By", tracks: "CD1-1 to CD1-2"),
        CatalogCredit(id: 11, name: "Lee", nameVariation: "L.", role: "Mixed By", tracks: "CD2-1"),
    ],
    tracks: [
        CatalogTrack(kind: .heading, position: nil, title: "Night One"),
        song("CD1-1", "Opener"), song("CD1-2", "Second"),
        CatalogTrack(kind: .heading, position: nil, title: "Night Two"),
        CatalogTrack(
            kind: .track, position: "CD2-1", title: "Closer",
            artists: [artist(2, "Guest", join: "&"), artist(3, "Host")],
            credits: [CatalogCredit(id: 12, name: "Kim", role: "Remix")]),
    ])

private func changed(
    _ release: CatalogRelease = twoDiscs, _ mapping: DiscogsMapping = oneToOne,
    files: [AlbumFile]? = nil
) -> [Int64: [String: String?]] {
    let files = files ?? (1...3).map { albumFile(Int64($0), .flac, TrackTags()) }
    let set = changeSet(for: files, match: match(release), mapping: mapping)
    return Dictionary(
        uniqueKeysWithValues: set.files.map { file in
            (
                file.fileID,
                Dictionary(uniqueKeysWithValues: file.changes.map { ($0.tag.name, $0.new) })
            )
        })
}

@Test func oneToOneWritesEachFieldToItsOwnTag() {
    let first = changed()[1]!
    #expect(first["DISCOGS_RELEASE_ID"] == "100")
    #expect(first["DISCOGS_MASTER_ID"] == "m7")
    #expect(first["DISCOGS_RELEASE_URL"] == "https://www.discogs.com/release/100")
    #expect(first["album"] == "Live")
    #expect(first["albumArtist"] == "Band (3)")
    #expect(first["DISCOGS_ALBUMARTIST_URL"] == "https://www.discogs.com/artist/1")
    #expect(first["publisher"] == "Label (2) & Other")
    #expect(first["DISCOGS_LABEL_URL"] == "https://www.discogs.com/label/5")
    #expect(first["DISCOGS_LABEL_URL-2"] == "https://www.discogs.com/label/6")
    #expect(first["catalogNumber"] == "CAT 1")
    #expect(first["DISCOGS_CATALOG_NUMBER"] == "Label (2): CAT 1")
    #expect(first["DISCOGS_CATALOG_NUMBER-2"] == "Other: OTH 2")
    #expect(first["barcode"] == "0123")
    #expect(first["COUNTRY"] == "Europe")
    #expect(first["genre"] == "Rock, Pop")
    #expect(first["mood"] == "Indie Rock")
    #expect(first["media"] == "CD (Album), DVD")
    #expect(first["compilation"] == nil, "0 against a file that isn't one: no change")
    #expect(first["title"] == "Opener")
    #expect(first["DISCOGS_ARTIST_LIST"] == "Band (3)")
    #expect(first["DISCOGS_ANV_LIST"] == "Band (3)=The Band")
    #expect(first["TRACK_NUMBER_TEXT"] == "CD1-1")
    #expect(first["DISCOGS_RELEASE_ORDINAL_POSITION"] == "0")
    #expect(first["discSubtitle"] == "Night One")
}

@Test func discsAndTrackNumbersComeFromThePositions() {
    let all = changed()
    #expect(all[1]?["discNumber"] == "1")
    #expect(all[2]?["trackNumber"] == "2")
    #expect(all[2]?["trackTotal"] == "2")
    #expect(all[3]?["discNumber"] == "2")
    #expect(all[3]?["trackNumber"] == "1")
    #expect(all[3]?["trackTotal"] == "1")
    #expect(all[3]?["discTotal"] == "2")
    #expect(all[3]?["discSubtitle"] == "Night Two")
    #expect(all[3]?["DISCOGS_RELEASE_ORDINAL_POSITION"] == "2")
    // Vinyl sides aren't discs.
    let vinyl = CatalogRelease(
        id: 1, title: "LP", tracks: [song("A1", "One"), song("B1", "Two")])
    #expect(changed(vinyl, files: nil)[2]?["discNumber"] == "1")
    #expect(changed(vinyl)[2]?["trackNumber"] == "2")
}

@Test func artistsUseTheTracksOwnAndDiscogssJoins() {
    let closer = changed()[3]!
    #expect(closer["artist"] == "Guest & Host")
    #expect(closer["DISCOGS_ARTIST_LIST"] == "Guest;;;Host")
    #expect(closer["DISCOGS_ARTIST_URL"] == "https://www.discogs.com/artist/2")
    #expect(closer["DISCOGS_ARTIST_URL-2"] == "https://www.discogs.com/artist/3")
    #expect(changed()[1]?["DISCOGS_ARTIST_URL-2"] == nil)
}

@Test func namesFollowTheFormat() {
    var mapping = oneToOne
    mapping[.albumArtist].format = DiscogsFieldFormat(names: .variation)
    mapping[.artist].format = DiscogsFieldFormat(join: " / ", suffixes: .drop)
    mapping[.label].format = DiscogsFieldFormat(join: " & ", suffixes: .drop)
    let all = changed(twoDiscs, mapping)
    #expect(all[1]?["albumArtist"] == "The Band")
    #expect(all[1]?["artist"] == "Band")
    #expect(all[3]?["artist"] == "Guest / Host")
    #expect(all[1]?["publisher"] == "Label & Other")
}

@Test func creditsGoToTheirFieldsAndTheRestToTheInvolvedPeople() {
    let all = changed()
    // A release credit without tracks covers every track; one with tracks covers those.
    #expect(all[1]?["PRODUCER"] == "Pat")
    #expect(all[3]?["PRODUCER"] == "Pat")
    #expect(all[1]?["composer"] == "Sam")
    #expect(all[2]?["composer"] == "Sam")
    #expect(all[3]?["composer"] == nil)
    #expect(all[3]?["remixer"] == "Kim")
    #expect(all[1]?["INVOLVEDPEOPLE"] == "Pat (Recorded By)")
    #expect(all[3]?["INVOLVEDPEOPLE"] == "Pat (Recorded By);;;Lee (Mixed By)")

    var mapping = oneToOne
    mapping[.involvedPeople] = DiscogsFieldRule(
        .replace, [.key(PerTagFormat("INVOLVEDPEOPLE"))],
        format: DiscogsFieldFormat(
            join: ";;;", names: .variation,
            credits: PerTagFormat(vorbis: .roleNames, mp4: .nameRole, id3: .nameRole)))
    #expect(changed(twoDiscs, mapping)[3]?["INVOLVEDPEOPLE"] == "Recorded By;;;Pat;;;Mixed By;;;L.")
}

@Test func aDateKnownInPartIsItsYear() {
    #expect(changed()[1]?["date"] == "1999")
    var mapping = oneToOne
    mapping[.date].format = DiscogsFieldFormat(date: .year)
    var full = twoDiscs
    full.released = "1999-03-15"
    #expect(changed(full)[1]?["date"] == "1999-03-15")
    #expect(changed(full, mapping)[1]?["date"] == "1999")
}

@Test func aTemplateBuildsATagFromSeveralFields() {
    var mapping = oneToOne
    mapping[.genres] = DiscogsFieldRule(
        .replace, [.field(.genre)],
        format: DiscogsFieldFormat(join: ", ", template: "{genre} - {styles} ({country})"))
    #expect(changed(twoDiscs, mapping)[1]?["genre"] == "Rock - Indie Rock (Europe)")
    var bare = twoDiscs
    bare.styles = []
    bare.country = nil
    #expect(changed(bare, mapping)[1]?["genre"] == "Rock -  ()")
}

@Test func fillEmptyLeavesATagWithAValueAndOffWritesNothing() {
    var mapping = oneToOne
    mapping[.album].mode = .fillEmpty
    mapping[.title].mode = .off
    mapping[.styles].targets = [.key("STYLE")]
    let current = tags {
        $0.album = "My Title"
        $0.date = "1999"
        $0.custom = ["STYLE": "Indie Rock"]
    }
    let files = (1...3).map { albumFile(Int64($0), .flac, current) }
    let all = changed(twoDiscs, mapping, files: files)
    #expect(all[1]?.keys.contains("album") == false)
    #expect(all[1]?.keys.contains("title") == false)
    #expect(all[1]?.keys.contains("date") == false, "the same value is no change")
    #expect(all[1]?.keys.contains("STYLE") == false, "custom keys compare uppercased")
    var empty = twoDiscs
    empty.barcodes = []
    let withBarcode = (1...3).map {
        albumFile(Int64($0), .flac, tags { $0.barcode = "999" })
    }
    var keepBarcode = oneToOne
    keepBarcode[.barcode].mode = .fillEmpty
    #expect(
        changed(empty, keepBarcode, files: withBarcode)[1]?.keys.contains("barcode") == false,
        "a field Discogs lacks leaves a tag that fills only empty ones")
}

@Test func aFieldDiscogsLacksClearsTheTagsItReplaces() throws {
    var bare = twoDiscs
    bare.barcodes = []
    bare.labels = []
    let current = tags {
        $0.barcode = "999"
        $0.publisher = "Old Label"
        $0.custom = ["DISCOGS_LABEL_URL": "old 1", "DISCOGS_LABEL_URL-2": "old 2"]
    }
    let files = (1...3).map { albumFile(Int64($0), .flac, current) }
    let first = changed(bare, files: files)[1]!
    #expect(first["barcode"] == .some(nil))
    #expect(first["publisher"] == .some(nil))
    #expect(first["DISCOGS_LABEL_URL"] == .some(nil))
    #expect(first["DISCOGS_LABEL_URL-2"] == .some(nil))
    #expect(first["catalogNumber"] == nil, "a tag the file doesn't have is no change")
    let set = changeSet(for: files, match: match(bare), mapping: oneToOne)
    let edit = try set.edits()[0].edit
    #expect(edit.values[.barcode] == "")
    #expect(edit.custom["DISCOGS_LABEL_URL-2"] == "")

    // A template that fills to no text clears its tag too.
    var mapping = oneToOne
    mapping[.genres].format.template = "{country}"
    var noCountry = twoDiscs
    noCountry.country = nil
    let genred = (1...3).map { albumFile(Int64($0), .flac, tags { $0.genre = "Rock" }) }
    #expect(changed(noCountry, mapping, files: genred)[1]?["genre"] == .some(nil))
}

@Test func aFieldDiscogsLacksLeavesTheTagsOfAKeptField() {
    var undated = twoDiscs
    undated.released = nil
    let files = (1...3).map { albumFile(Int64($0), .flac, tags { $0.date = "2001" }) }
    #expect(changed(undated, oneToOne.keepingExistingValues(), files: files)[1]?["date"] == nil)
    #expect(changed(undated, oneToOne, files: files)[1]?["date"] == .some(nil))
}

@Test func anotherSpellingOfAFieldsKeyIsRemoved() throws {
    // As YATE leaves a FLAC album, keys uppercased as they are read.
    let yate = tags {
        $0.custom = [
            "TRACK NUMBER TEXT": "2", "DISCOGS RELEASE ORDINAL POSITION": "1",
            "DISCOGS_ALBUM_RELEASECOUNTRY": "UK", "DISCOGS ALBUM RELEASE COUNTRY": "UK",
            "DISCOGS_IMPORT_SETTINGS": "yate's",
        ]
    }
    let files = (1...3).map { albumFile(Int64($0), .flac, yate) }
    let first = changed(twoDiscs, files: files)[1]!
    for key in [
        "TRACK NUMBER TEXT", "DISCOGS RELEASE ORDINAL POSITION", "DISCOGS_ALBUM_RELEASECOUNTRY",
        "DISCOGS ALBUM RELEASE COUNTRY",
    ] {
        #expect(first[key] == .some(nil), "\(key)")
    }
    #expect(first["TRACK_NUMBER_TEXT"] == "CD1-1")
    #expect(first["COUNTRY"] == "Europe")
    #expect(first["DISCOGS_IMPORT_SETTINGS"] == nil, "a key no field has is left")
    let set = changeSet(for: files, match: match(twoDiscs), mapping: oneToOne)
    #expect(set.files[0].changes.first { $0.tag.name == "TRACK NUMBER TEXT" }?.field == .position)
    #expect(try set.edits()[0].edit.custom["DISCOGS ALBUM RELEASE COUNTRY"] == "")

    // YATE's preset writes its own spellings of the country, so it keeps them.
    let mp4 = (1...3).map { albumFile(Int64($0), .aac, yate) }
    let byYATE = changed(twoDiscs, DiscogsPreset.yate.mapping, files: mp4)[1]!
    #expect(byYATE["Discogs Album Release Country"] == "Europe")
    #expect(byYATE["DISCOGS_ALBUM_RELEASECOUNTRY"] == .some(nil), "FLAC's spelling, in MP4")
    #expect(byYATE["DISCOGS ALBUM RELEASE COUNTRY"] == nil)
}

@Test func anotherSpellingsNumberedKeysAreRemoved() {
    let current = tags {
        $0.custom = [
            "DISCOGS_ALBUM_ARTIST_URL": "https://www.discogs.com/artist/1",
            "DISCOGS_ALBUM_ARTIST_URL-2": "https://www.discogs.com/artist/2",
            "DISCOGS CATALOG NUMBER-2": "Other: OTH 2",
        ]
    }
    let files = (1...3).map { albumFile(Int64($0), .flac, current) }
    let first = changed(twoDiscs, files: files)[1]!
    #expect(first["DISCOGS_ALBUM_ARTIST_URL"] == .some(nil))
    #expect(first["DISCOGS_ALBUM_ARTIST_URL-2"] == .some(nil))
    #expect(first["DISCOGS CATALOG NUMBER-2"] == .some(nil))
    #expect(first["DISCOGS_ALBUMARTIST_URL"] == "https://www.discogs.com/artist/1")
    #expect(first["DISCOGS_CATALOG_NUMBER-2"] == "Other: OTH 2")
    var keep = oneToOne
    keep[.labelCatalogNumbers].mode = .fillEmpty
    #expect(
        changed(twoDiscs, keep, files: files)[1]?.keys.contains("DISCOGS CATALOG NUMBER-2")
            == false, "a field that fills only empty tags removes nothing")

    // ID3's WXXX frames are YATE's spelling of the URLs.
    let mp3 = albumFile(
        1, .mp3,
        tags { $0.custom = ["WXXX:DISCOGS_ALBUMARTIST_URL-2": "https://www.discogs.com/artist/X"] })
    #expect(changed(twoDiscs, files: [mp3])[1]?["WXXX:DISCOGS_ALBUMARTIST_URL-2"] == .some(nil))
}

@Test func aKeyTheMappingWritesIsNeverRemoved() {
    var mapping = oneToOne
    mapping[.position].targets = [.key("Track Number Text")]
    mapping[.producer].targets = [.key(DiscogsKey.releaseCountryVorbis)]
    let current = tags {
        $0.custom = [
            "TRACK NUMBER TEXT": "2", "TRACK_NUMBER_TEXT": "2",
            "DISCOGS_ALBUM_RELEASECOUNTRY": "UK",
        ]
    }
    let files = (1...3).map { albumFile(Int64($0), .flac, current) }
    let first = changed(twoDiscs, mapping, files: files)[1]!
    #expect(first["Track Number Text"] == "CD1-1")
    #expect(first["TRACK NUMBER TEXT"] == nil, "the key it writes isn't also removed")
    #expect(first["TRACK_NUMBER_TEXT"] == .some(nil))
    #expect(first["DISCOGS_ALBUM_RELEASECOUNTRY"] == "Pat", "another field's target is kept")
}

@Test func aNumberedKeyPastTheReleasesValuesIsRemoved() throws {
    let current = tags {
        $0.custom = [
            "DISCOGS_CATALOG_NUMBER": "Old: 1", "DISCOGS_CATALOG_NUMBER-2": "Old: 2",
            "DISCOGS_CATALOG_NUMBER-3": "Old: 3", "DISCOGS_CATALOG_NUMBER-X": "kept",
        ]
    }
    let files = (1...3).map { albumFile(Int64($0), .flac, current) }
    let set = changeSet(for: files, match: match(twoDiscs), mapping: oneToOne)
    let numbers = set.files[0].changes.filter { $0.field == .labelCatalogNumbers }
    #expect(
        numbers.map { [$0.tag.name, $0.current, $0.new] } == [
            ["DISCOGS_CATALOG_NUMBER", "Old: 1", "Label (2): CAT 1"],
            ["DISCOGS_CATALOG_NUMBER-2", "Old: 2", "Other: OTH 2"],
            ["DISCOGS_CATALOG_NUMBER-3", "Old: 3", nil],
        ])
    let edit = try set.edits()[0].edit
    #expect(edit.custom["DISCOGS_CATALOG_NUMBER-3"] == "")
    #expect(edit.custom["DISCOGS_CATALOG_NUMBER-X"] == nil)
}

@Test func aFileMatchedToNoTrackGetsTheReleasesFieldsOnly() {
    let files = (1...4).map { albumFile(Int64($0), .flac, TrackTags()) }
    let set = changeSet(for: files, match: match(twoDiscs, files: 3), mapping: oneToOne)
    let bonus = Set(set.files[3].changes.map(\.field))
    #expect(bonus.contains(.releaseID))
    #expect(bonus.allSatisfy { $0.level == .release })
    #expect(set.files[3].changes.contains { $0.field == .album })

    // A bonus track's tags of the track's fields are left, other spellings too.
    let bonusTags = tags {
        $0.title = "Bonus"
        $0.custom = ["TRACK_NUMBER_TEXT": "5", "TRACK NUMBER TEXT": "5"]
    }
    let withBonus = Array(files.prefix(3)) + [albumFile(4, .flac, bonusTags)]
    let tagged = changeSet(for: withBonus, match: match(twoDiscs, files: 3), mapping: oneToOne)
    #expect(!tagged.files[3].changes.isEmpty)
    #expect(tagged.files[3].changes.allSatisfy { $0.field.level == .release })
}

@Test func aDSDFileCantBeWrittenAndNoReleaseChangesNothing() throws {
    let dsd = albumFile(1, .dsd, TrackTags())
    let set = changeSet(for: [dsd], match: match(twoDiscs), mapping: oneToOne)
    #expect(set.files[0].changes == [])
    #expect(set.files[0].unwritable != nil)
    #expect(try set.edits().isEmpty)
    var none = match(twoDiscs)
    none.release = nil
    let nothing = changeSet(
        for: [albumFile(1, .flac, TrackTags())], match: none, mapping: oneToOne)
    #expect(nothing.files.flatMap(\.changes).isEmpty)
}

@Test func theEditsKeepTheCheckedChangesAndRefuseAValueNoFormatHolds() throws {
    let files = (1...3).map { albumFile(Int64($0), .mp3, TrackTags()) }
    let set = changeSet(for: files, match: match(twoDiscs), mapping: oneToOne)
    let onlyTitles = try set.edits { $0.tag == .field(.title) }
    #expect(onlyTitles.map(\.path) == files.map(\.path))
    #expect(
        onlyTitles.map(\.edit)
            == ["Opener", "Second", "Closer"].map {
                TagEdit(values: [.title: $0])
            })
    #expect(try set.edits { _ in false }.isEmpty)
    #expect(try set.edits().count == 3)

    var mapping = oneToOne
    mapping[.title] = DiscogsFieldRule(.replace, [.field(.bpm)])
    mapping[.trackNumber].mode = .off
    let wrong = changeSet(for: files, match: match(twoDiscs), mapping: mapping)
    #expect(throws: TagValueError.self) { try wrong.edits() }
}

@Test func theSortArtistIsFilledFromTheAlbumArtistOnlyWhereEmpty() throws {
    let files = [
        albumFile(1, .flac, TrackTags()),
        albumFile(2, .flac, tags { $0.artistSort = "Band, The" }),
        albumFile(3, .flac, tags { $0.albumArtist = "Mine" }),
    ]
    var mapping = oneToOne
    let set = changeSet(
        for: files, match: match(twoDiscs), mapping: mapping, fillingSortArtist: true)
    func sorted(_ set: AlbumChangeSet, _ index: Int) -> TagChange? {
        set.files[index].changes.first { $0.tag == .field(.artistSort) }
    }
    // The album artist the changes write.
    #expect(sorted(set, 0)?.new == "Band (3)")
    #expect(sorted(set, 0)?.field == .albumArtist)
    #expect(sorted(set, 1) == nil, "a sort artist is left as it is")
    #expect(try set.edits()[0].edit.values[.artistSort] == "Band (3)")
    // The file's own album artist where the mapping keeps it.
    mapping[.albumArtist].mode = .fillEmpty
    let kept = changeSet(
        for: files, match: match(twoDiscs), mapping: mapping, fillingSortArtist: true)
    #expect(sorted(kept, 2)?.new == "Mine")
    #expect(sorted(changeSet(for: files, match: match(twoDiscs), mapping: mapping), 0) == nil)
    // Nothing to fill from.
    mapping[.albumArtist].mode = .off
    let none = changeSet(
        for: [files[0]], match: match(twoDiscs), mapping: mapping, fillingSortArtist: true)
    #expect(sorted(none, 0) == nil)
}

@Test func keepingExistingValuesLeavesTheFilesOwnTitlesAndNumbers() {
    let file = albumFile(
        1, .flac,
        tags {
            $0.title = "My Opener"
            $0.artist = "My Band"
            $0.trackNumber = 9
            $0.date = "2001"
        })
    let kept = changed(twoDiscs, oneToOne.keepingExistingValues(), files: [file])[1]!
    #expect(kept["title"] == nil)
    #expect(kept["artist"] == nil)
    #expect(kept["trackNumber"] == nil)
    #expect(kept["date"] == nil)
    #expect(kept["album"] == "Live", "fields that aren't kept are replaced")
    #expect(kept["trackTotal"] == "2", "an empty tag of a kept field is filled")
    let replaced = changed(twoDiscs, oneToOne, files: [file])[1]!
    #expect(replaced["title"] == "Opener")
    #expect(replaced["date"] == "1999")
}
