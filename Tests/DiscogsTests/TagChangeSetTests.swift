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
    #expect(first["publisher"] == "Label (2) & Other")
    #expect(first["DISCOGS_LABEL_URL"] == "https://www.discogs.com/label/5")
    #expect(first["DISCOGS_LABEL_URL-2"] == "https://www.discogs.com/label/6")
    #expect(first["catalogNumber"] == "CAT 1")
    #expect(first["DISCOGS_CATALOG_NUMBER"] == "Label (2): CAT 1")
    #expect(first["DISCOGS_CATALOG_NUMBER-2"] == "Other: OTH 2")
    #expect(first["barcode"] == "0123")
    #expect(first["COUNTRY"] == "Europe")
    #expect(first["genre"] == "Rock, Pop")
    #expect(first["STYLE"] == "Indie Rock")
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
    #expect(
        changed(empty, files: withBarcode)[1]?.keys.contains("barcode") == false,
        "a field Discogs lacks leaves the tag")
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
    #expect(nothing.changeCount == 0)
}

@Test func theEditsKeepTheCheckedChangesAndRefuseAValueNoFormatHolds() throws {
    let files = (1...3).map { albumFile(Int64($0), .mp3, TrackTags()) }
    let set = changeSet(for: files, match: match(twoDiscs), mapping: oneToOne)
    #expect(set.changeCount == set.files.map(\.changes.count).reduce(0, +))
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
