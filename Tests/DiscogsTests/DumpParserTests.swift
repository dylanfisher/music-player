import Foundation
import Testing

@testable import Discogs
@testable import Fixtures

private let date = "20261101"

@Test func aRecordWithEveryOptionalElementMissingIsKeptWithItsID() throws {
    let folder = try DumpFolder()
    try folder.write(
        date, labels: "<label><id>3</id></label>\n", artists: "<artist><id>4</id></artist>\n",
        masters: #"<master id="5"></master>"# + "\n",
        releases: #"<release id="6"></release>"# + "\n")
    let catalog = try folder.importedCatalog()
    #expect(try catalog.label(id: 3) == CatalogLabel(id: 3, name: ""))
    #expect(try catalog.artist(id: 4) == CatalogArtist(id: 4, name: ""))
    #expect(try catalog.master(id: 5) == CatalogMaster(id: 5, title: ""))
    #expect(try catalog.release(id: 6) == CatalogRelease(id: 6, title: ""))
    #expect(try catalog.release(id: 7) == nil)
}

@Test func aReleaseKeepsWhatTheMatcherAndTheMappingUse() throws {
    let folder = try DumpFolder()
    try folder.write(
        date,
        releases: """
            <release id="1"><artists><artist><id>1</id><name>The Persuader</name><anv>Persuader</anv><join>&amp;</join></artist><artist><id>2</id><name>Soleil (2)</name></artist></artists>\
            <title>Stockholm</title><labels><label name="Svek" catno="SK032" id="5"/><label name="Svek" catno="SK 032" id="5"/></labels>\
            <extraartists><artist><id>239</id><name>Jesper Dahlbäck</name><role>Written-By [All Tracks By]</role><tracks>A to D</tracks></artist><artist><name>Unlinked Person</name><role>Photography By</role></artist></extraartists>\
            <formats><format name="Vinyl" qty="2" text="Gatefold"><descriptions><description>12"</description><description>33 ⅓ RPM</description></descriptions></format></formats>\
            <genres><genre>Electronic</genre></genres><styles><style>Deep House</style><style>Techno</style></styles><country>Sweden</country><released>1999-03-00</released>\
            <notes>Recorded at the Globe studio.</notes><data_quality>Correct</data_quality><master_id is_main_release="true">1660109</master_id>\
            <tracklist><track><position>A</position><title>Östermalm</title><duration>4:45</duration><artists><artist><id>3</id><name>Guest</name></artist></artists><extraartists><artist><id>4</id><name>Remixer</name><role>Remix</role></artist></extraartists></track></tracklist>\
            <identifiers><identifier type="Barcode" description="Text" value="7 18755 61492 1"/><identifier type="Matrix / Runout" description="A-side" value="SK 032 A1"/></identifiers>\
            <videos><video src="https://www.youtube.com/watch?v=x" duration="325" embed="true"><title>A video</title><description>Not kept</description></video></videos>\
            <companies><company><id>1</id><name>The Globe Studios</name><entity_type>23</entity_type></company></companies></release>

            """)
    let release = try #require(try folder.importedCatalog().release(id: 1))
    #expect(
        release
            == CatalogRelease(
                id: 1, masterID: 1_660_109, isMainRelease: true, title: "Stockholm",
                artists: [
                    CatalogArtistCredit(
                        id: 1, name: "The Persuader", nameVariation: "Persuader", join: "&"),
                    CatalogArtistCredit(id: 2, name: "Soleil (2)"),
                ],
                labels: [
                    CatalogRelease.Label(id: 5, name: "Svek", catalogNumber: "SK032"),
                    CatalogRelease.Label(id: 5, name: "Svek", catalogNumber: "SK 032"),
                ],
                formats: [
                    CatalogRelease.Format(
                        name: "Vinyl", quantity: 2, text: "Gatefold",
                        descriptions: ["12\"", "33 ⅓ RPM"])
                ],
                country: "Sweden", released: "1999-03-00", genres: ["Electronic"],
                styles: ["Deep House", "Techno"], barcodes: ["7 18755 61492 1"],
                credits: [
                    CatalogCredit(
                        id: 239, name: "Jesper Dahlbäck", role: "Written-By [All Tracks By]",
                        tracks: "A to D"),
                    CatalogCredit(id: nil, name: "Unlinked Person", role: "Photography By"),
                ],
                tracks: [
                    CatalogTrack(
                        kind: .track, position: "A", title: "Östermalm", durationSeconds: 285,
                        artists: [CatalogArtistCredit(id: 3, name: "Guest")],
                        credits: [CatalogCredit(id: 4, name: "Remixer", role: "Remix")])
                ]))
}

@Test func headingsAndIndexTracksKeepTheirKindAndSubTracks() throws {
    let folder = try DumpFolder()
    try folder.write(
        date,
        releases: """
            <release id="2"><title>Suites</title><tracklist>\
            <track><title>This Side</title></track>\
            <track><position>1</position><title>Opening</title><duration>3:10</duration></track>\
            <track><title>Black Jackal Throwbacks</title><duration>11:46</duration><sub_tracks>\
            <track><position>2a</position><title>Part 1</title></track>\
            <track><position>2b</position><title>Part 2</title><duration>5:00</duration></track></sub_tracks></track>\
            <track><position></position><title>That Side</title><duration></duration></track>\
            <track><position>11</position><title>Medley</title><sub_tracks><track><position>11.a</position><title>909 Shuffle</title><duration>3:10</duration></track></sub_tracks></track>\
            </tracklist></release>

            """)
    let tracks = try #require(try folder.importedCatalog().release(id: 2)).tracks
    #expect(
        tracks == [
            CatalogTrack(kind: .heading, position: nil, title: "This Side"),
            CatalogTrack(kind: .track, position: "1", title: "Opening", durationSeconds: 190),
            CatalogTrack(
                kind: .index, position: nil, title: "Black Jackal Throwbacks", durationSeconds: 706,
                subTracks: [
                    CatalogTrack(kind: .track, position: "2a", title: "Part 1"),
                    CatalogTrack(
                        kind: .track, position: "2b", title: "Part 2", durationSeconds: 300),
                ]),
            CatalogTrack(kind: .heading, position: nil, title: "That Side"),
            CatalogTrack(
                kind: .index, position: "11", title: "Medley",
                subTracks: [
                    CatalogTrack(
                        kind: .track, position: "11.a", title: "909 Shuffle", durationSeconds: 190)
                ]),
        ])
}

@Test func vinylAndMultiDiscPositionsAreKeptAsWritten() throws {
    let folder = try DumpFolder()
    let positions = ["A1", "AA", "B", "CD1-1", "CD2-4", "2-03", "D2", "Video"]
    try folder.write(
        date,
        releases: #"<release id="3"><title>Box</title><tracklist>"#
            + positions.map {
                "<track><position>\($0)</position><title>T</title><duration>1:02:03</duration></track>"
            }
            .joined() + "</tracklist></release>\n")
    let tracks = try #require(try folder.importedCatalog().release(id: 3)).tracks
    #expect(tracks.map(\.position) == positions)
    #expect(tracks.allSatisfy { $0.kind == .track && $0.durationSeconds == 3723 })
}

@Test func mastersArtistsAndLabelsKeepTheirNames() throws {
    let folder = try DumpFolder()
    try folder.write(
        date,
        labels: """
            <label><id>5</id><name>Svek</name><contactinfo>Stockholm</contactinfo><profile>A label.</profile><parentLabel id="4711">Goldhead Music</parentLabel><urls><url>https://x</url></urls><sublabels><label id="2437">Birdy</label></sublabels></label>

            """,
        artists: """
            <artist><id>1</id><name>The Persuader</name><realname>Jesper Dahlbäck</realname><profile>Electronic artist.</profile><urls><url>https://x</url></urls><namevariations><name>Persuader</name><name>The Presuader</name></namevariations><aliases><name id="239">Jesper Dahlbäck</name></aliases><members><name id="26">Alexi Delano</name></members></artist>

            """,
        masters: """
            <master id="113"><main_release>116925</main_release><artists><artist><id>3225</id><name>Vince Watson</name><join>,</join></artist></artists><genres><genre>Electronic</genre></genres><styles><style>Techno</style></styles><year>2002</year><title>Moments In Time</title><data_quality>Correct</data_quality><videos><video src="x" duration="1" embed="true"><title>Not the title</title></video></videos></master>
            <master id="114"><title>No Year</title><year>0</year></master>

            """,
        releases: "")
    let catalog = try folder.importedCatalog()
    #expect(try catalog.label(id: 5) == CatalogLabel(id: 5, name: "Svek"))
    #expect(try catalog.label(id: 2437) == nil)
    #expect(
        try catalog.artist(id: 1)
            == CatalogArtist(
                id: 1, name: "The Persuader", nameVariations: ["Persuader", "The Presuader"]))
    #expect(try catalog.artist(id: 239) == nil)
    #expect(
        try catalog.master(id: 113)
            == CatalogMaster(
                id: 113, mainReleaseID: 116_925, title: "Moments In Time", year: 2002,
                artists: [CatalogArtistCredit(id: 3225, name: "Vince Watson", join: ",")],
                genres: ["Electronic"], styles: ["Techno"]))
    #expect(try catalog.master(id: 114) == CatalogMaster(id: 114, title: "No Year"))
}

@Test func aDurationReadsAsSecondsOrNotAtAll() {
    #expect(CatalogTrack.seconds("4:45") == 285)
    #expect(CatalogTrack.seconds("1:02:03") == 3723)
    #expect(CatalogTrack.seconds("0:00") == 0)
    #expect(CatalogTrack.seconds("") == nil)
    #expect(CatalogTrack.seconds("285") == nil)
    #expect(CatalogTrack.seconds("4:4x") == nil)
    #expect(CatalogTrack.seconds("1:2:3:4") == nil)
}

@Test func recordsAreReadTheSameInBatchesOfAnySize() throws {
    let folder = try DumpFolder()
    let records = [
        #"<release id="1"><title>Line One"#, "Line Two &lt;/release&gt;</title><notes>Notes",
        "", "over lines</notes><tracklist><track><position>A</position><title>T</title>",
        "</track></tracklist></release>",
        #"<release id="2"><title>Second</title></release>"#,
        #"<release id="3"><title>Third</title></release>"#, "",
    ].joined(separator: "\n")
    try folder.write(date, releases: records)
    for batchBytes in [1, 40, 1 << 20] {
        let catalog = try folder.importedCatalog(batchBytes: batchBytes)
        #expect(
            try catalog.release(id: 1)
                == CatalogRelease(
                    id: 1, title: "Line One\nLine Two </release>",
                    tracks: [CatalogTrack(kind: .track, position: "A", title: "T")]),
            "\(batchBytes)")
        #expect(try catalog.release(id: 3)?.title == "Third", "\(batchBytes)")
    }
}

@Test func aDumpOverOneBatchIsReadWhole() throws {
    let folder = try DumpFolder()
    let releases = DiscogsDumpFixture.syntheticReleases(count: 2500)
    #expect(releases.utf8.count > DumpBatches.batchBytes)
    try folder.write(date, releases: releases)
    #expect(try folder.importCatalog().records[.releases] == 2500)
    #expect(try Catalog(at: folder.catalog).release(id: 2500)?.tracks.count == 10)
}
