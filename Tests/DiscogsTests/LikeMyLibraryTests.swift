import Foundation
import Testing

@testable import Discogs
@testable import Metadata
@testable import Settings

// "Like my library" applied to a release reproduces the tags the owner's matched albums
// carry. The albums are written by hand from ADR 0128's findings and examples, one per tag
// format, with each format's spellings as the survey found them; the survey's cache of the
// library is gone, and no test reads the library. The survey didn't record the URLs' values,
// so those are left out of the comparison, and these releases have no credits.

private let likeMyLibrary = DiscogsPreset.likeMyLibrary.mapping
private let unrecorded: Set<DiscogsField> = [
    .releaseURL, .masterURL, .artistURL, .albumArtistURL, .labelURL,
]

/// The changes "Like my library" would make, apart from the URLs the survey didn't record.
private func changes(_ files: [AlbumFile], _ release: CatalogRelease) -> [TagChange] {
    changeSet(for: files, match: match(release), mapping: likeMyLibrary).files
        .flatMap(\.changes).filter { !unrecorded.contains($0.field) }
}

/// A dub techno album in FLAC: `GENRE` as the first genre and the styles, `MOOD` the styles,
/// `GROUPING` the label, a master id, and FLAC's own spellings.
@Test func aFLACAlbumKeepsItsTags() {
    let release = CatalogRelease(
        id: 5_323_221, masterID: 744_074, isMainRelease: true, title: "Fluctuations",
        artists: [artist(11, "Deepchord")], labels: [label(21, "Echospace", "echospace 019")],
        formats: [format("File", ["FLAC", "Album"])], country: "US", released: "2014-05-12",
        genres: ["Electronic"], styles: ["Dub Techno", "House", "Techno", "Minimal"],
        tracks: [song("1", "Fluctuations 1"), song("2", "Fluctuations 2")])
    let files = (0..<2).map { index in
        albumFile(
            Int64(index + 1), .flac,
            tags { tags in
                tags.title = "Fluctuations \(index + 1)"
                tags.artist = "Deepchord"
                tags.albumArtist = "Deepchord"
                tags.album = "Fluctuations"
                tags.genre = "Electronic - Dub Techno, House, Techno, Minimal"
                tags.mood = "Dub Techno, House, Techno, Minimal"
                tags.publisher = "Echospace"
                tags.grouping = "Echospace"
                tags.catalogNumber = "echospace 019"
                tags.media = "File (FLAC,Album)"
                tags.date = "2014-05-12"
                tags.trackNumber = index + 1
                tags.trackTotal = 2
                tags.discNumber = 1
                tags.discTotal = 1
                tags.custom = [
                    "DISCOGS_RELEASE_ID": "5323221", "DISCOGS_MASTER_ID": "m744074",
                    "DISCOGS_CATALOG_NUMBER": "Echospace: echospace 019",
                    "DISCOGS_ARTIST_LIST": "Deepchord",
                    "DISCOGS_RELEASE_ORDINAL_POSITION": "\(index)",
                    "TRACK_NUMBER_TEXT": "\(index + 1)",
                    "DISCOGS_ALBUM_RELEASECOUNTRY": "US", "COUNTRY": "US",
                ]
            })
    }
    #expect(changes(files, release) == [])
}

/// A jazz album in MP4: two labels joined with " & ", repeats kept, a second catalog number,
/// a featured artist joined with Discogs's word, an ANV kept out of `ARTIST`, no styles, so
/// `GENRE` ends in " - ", a year for a date, and MP4's title-case spellings.
@Test func anMP4AlbumKeepsItsTags() {
    let release = CatalogRelease(
        id: 1_157_354, masterID: 61_380, title: "Journey In Satchidananda",
        artists: [
            artist(31, "Alice Coltrane", join: "Featuring"),
            artist(32, "Pharoah Sanders", anv: "Pharoah"),
        ],
        labels: [label(41, "Impulse!", "AS-9203"), label(41, "Impulse!", "AS 9203")],
        formats: [format("Vinyl", ["LP", "Album"])], country: "US", released: "1971",
        genres: ["Jazz"], styles: [],
        tracks: [song("A1", "Journey In Satchidananda"), song("A2", "Shiva-Loka")])
    let files = (0..<2).map { index in
        albumFile(
            Int64(index + 1), .alac,
            tags { tags in
                tags.title = ["Journey In Satchidananda", "Shiva-Loka"][index]
                tags.artist = "Alice Coltrane Featuring Pharoah Sanders"
                tags.albumArtist = "Alice Coltrane Featuring Pharoah Sanders"
                tags.album = "Journey In Satchidananda"
                tags.genre = "Jazz - "
                tags.publisher = "Impulse! & Impulse!"
                tags.grouping = "Impulse! & Impulse!"
                tags.catalogNumber = "AS-9203"
                tags.media = "Vinyl (LP,Album)"
                tags.date = "1971"
                tags.trackNumber = index + 1
                tags.trackTotal = 2
                tags.discNumber = 1
                tags.discTotal = 1
                tags.custom = [
                    "DISCOGS_RELEASE_ID": "1157354", "DISCOGS_MASTER_ID": "m61380",
                    "DISCOGS_CATALOG_NUMBER": "Impulse!: AS-9203",
                    "DISCOGS_CATALOG_NUMBER-2": "Impulse!: AS 9203",
                    "DISCOGS_ARTIST_LIST": "Alice Coltrane;;;Pharoah Sanders",
                    "DISCOGS_ANV_LIST": "Pharoah Sanders=Pharoah",
                    "DISCOGS RELEASE ORDINAL POSITION": "\(index)",
                    "TRACK NUMBER TEXT": ["A1", "A2"][index],
                    "DISCOGS ALBUM RELEASE COUNTRY": "US", "COUNTRY": "US",
                ]
            })
    }
    #expect(changes(files, release) == [])
}

/// A folk album in MP3: a genre name holding commas, artists joined by Discogs's "," with
/// YATE's spaces around it, a "(2)" dropped from `ARTIST` and kept in the artist list, and a
/// release without a master or styles.
@Test func anMP3AlbumKeepsItsTags() {
    let release = CatalogRelease(
        id: 2_201_998, title: "Hey Hey",
        artists: [
            artist(51, "Benedek", join: ","), artist(52, "Tom Noble (2)"),
        ],
        labels: [label(61, "Leng", "LENG 012")], formats: [format("CD", ["Album"])],
        country: "UK", released: "2010-09-20", genres: ["Folk, World, & Country"],
        styles: ["Celtic"], tracks: [song("1", "Hey Hey")])
    let file = albumFile(
        1, .mp3,
        tags { tags in
            tags.title = "Hey Hey"
            tags.artist = "Benedek , Tom Noble"
            tags.albumArtist = "Benedek , Tom Noble"
            tags.album = "Hey Hey"
            tags.genre = "Folk, World, & Country - Celtic"
            tags.mood = "Celtic"
            tags.publisher = "Leng"
            tags.grouping = "Leng"
            tags.catalogNumber = "LENG 012"
            tags.media = "CD (Album)"
            tags.date = "2010-09-20"
            tags.trackNumber = 1
            tags.trackTotal = 1
            tags.discNumber = 1
            tags.discTotal = 1
            tags.custom = [
                "DISCOGS_RELEASE_ID": "2201998", "DISCOGS_CATALOG_NUMBER": "Leng: LENG 012",
                "DISCOGS_ARTIST_LIST": "Benedek;;;Tom Noble (2)",
                "DISCOGS RELEASE ORDINAL POSITION": "0", "TRACK NUMBER TEXT": "1",
                "DISCOGS ALBUM RELEASE COUNTRY": "UK", "COUNTRY": "UK",
            ]
        })
    #expect(changes([file], release) == [])
}

/// The same release written to an album with none of its tags yet: every field the owner's
/// albums carry, in ID3's spellings, the links as `WXXX` frames and the credits as `TIPL`.
@Test func anUntaggedMP3AlbumGetsTheOwnersLayoutInID3Spellings() throws {
    let release = CatalogRelease(
        id: 2_201_998, masterID: 9, title: "Hey Hey",
        artists: [artist(51, "Benedek", join: ","), artist(52, "Tom Noble (2)")],
        labels: [label(61, "Leng", "LENG 012")], formats: [format("CD", ["Album"])],
        country: "UK", released: "2010-09-20", genres: ["Folk, World, & Country"],
        styles: ["Celtic", "Folk"],
        credits: [CatalogCredit(id: 70, name: "Mia", role: "Mastered By")],
        tracks: [song("1", "Hey Hey")])
    let set = changeSet(
        for: [albumFile(1, .mp3, TrackTags())], match: match(release), mapping: likeMyLibrary)
    let written = Dictionary(
        uniqueKeysWithValues: set.files[0].changes.map { ($0.tag.name, $0.new!) })
    #expect(written["genre"] == "Folk, World, & Country - Celtic, Folk")
    #expect(written["mood"] == "Celtic, Folk")
    #expect(written["grouping"] == "Leng")
    #expect(written["Discogs Release Ordinal Position"] == "0")
    #expect(written["Track Number Text"] == "1")
    #expect(written["Discogs Album Release Country"] == "UK")
    #expect(written["Country"] == "UK")
    #expect(written["WXXX:DISCOGS_RELEASE_URL"] == "https://www.discogs.com/release/2201998")
    #expect(written["WXXX:DISCOGS_MASTER_URL"] == "https://www.discogs.com/master/9")
    #expect(written["WXXX:DISCOGS_ARTIST_URL"] == "https://www.discogs.com/artist/51")
    #expect(written["WXXX:DISCOGS_ARTIST_URL-2"] == "https://www.discogs.com/artist/52")
    #expect(written["TIPL"] == "Mastered By;;;Mia")
    #expect(written["DISCOGS_MASTER_ID"] == "m9")
    #expect(written.keys.contains { $0.hasPrefix("DISCOGS_IMPORT") } == false)
    let edits = try set.edits()
    #expect(edits.count == 1)
    #expect(edits[0].edit.custom["TIPL"] == "Mastered By;;;Mia")
    #expect(edits[0].edit.values[.genre] == "Folk, World, & Country - Celtic, Folk")
}
