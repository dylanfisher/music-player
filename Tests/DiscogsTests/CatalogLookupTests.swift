import Foundation
import Testing

@testable import Discogs

private let releases = """
    <release id="10"><artists><artist><id>1</id><name>The Persuader</name></artist></artists><title>Stockholm</title><labels><label name="Svek" catno="SK 032" id="5"/><label name="Distributor (2)" catno="none" id="9"/></labels><master_id is_main_release="true">100</master_id><identifiers><identifier type="Barcode" value="7 18755 61492 1"/><identifier type="Barcode" value="718755614921"/></identifiers></release>
    <release id="11"><artists><artist><id>1</id><name>The Persuader</name></artist></artists><title>Stockholm</title><labels><label name="Svek" catno="SK032" id="5"/></labels><master_id is_main_release="false">100</master_id><identifiers><identifier type="Barcode" value="718755614921"/></identifiers></release>
    <release id="12"><artists><artist><id>2</id><name>Simon</name><join>&amp;</join></artist><artist><id>3</id><name>Garfunkel (2)</name></artist></artists><title>Bookends (Remastered)</title><labels><label name="Columbia" catno="KCS 9529" id="1866"/></labels></release>

    """

private let masters = """
    <master id="100"><main_release>10</main_release><artists><artist><id>1</id><name>The Persuader</name></artist></artists><title>Stockholm</title><year>1999</year></master>

    """

@Test func aReleaseIsFoundByItsBarcodeHoweverItIsWritten() throws {
    let folder = try DumpFolder()
    try folder.write("20261101", masters: masters, releases: releases)
    let catalog = try folder.importedCatalog()
    #expect(try catalog.releaseIDs(barcode: "718755614921") == [10, 11])
    #expect(try catalog.releaseIDs(barcode: "7-18755-61492-1") == [10, 11])
    #expect(try catalog.releaseIDs(barcode: "123") == [])
    #expect(try catalog.releaseIDs(barcode: " ") == [])
    #expect(try catalog.releaseIDs(barcode: "none") == [])
}

@Test func aReleaseIsFoundByItsLabelAndCatalogNumber() throws {
    let folder = try DumpFolder()
    try folder.write("20261101", masters: masters, releases: releases)
    let catalog = try folder.importedCatalog()
    #expect(try catalog.releaseIDs(label: "Svek", catalogNumber: "SK032") == [10, 11])
    #expect(try catalog.releaseIDs(label: "SVEK", catalogNumber: "sk-032") == [10, 11])
    #expect(try catalog.releaseIDs(label: "Columbia", catalogNumber: "KCS 9529") == [12])
    #expect(try catalog.releaseIDs(label: "Distributor", catalogNumber: "none") == [])
    #expect(try catalog.releaseIDs(label: "Svek", catalogNumber: "KCS 9529") == [])
}

@Test func anAlbumIsFoundByArtistAndTitleAmongMastersAndReleasesWithoutOne() throws {
    let folder = try DumpFolder()
    try folder.write("20261101", masters: masters, releases: releases)
    let catalog = try folder.importedCatalog()
    // The master, not its releases, which are found through it.
    #expect(try catalog.titleMatches(artist: "Persuader", title: "Stockholm") == [.master(100)])
    #expect(
        try catalog.titleMatches(artist: "The Persuader", title: "Stockholm (Deluxe Edition)")
            == [.master(100)])
    // A release with no master, by each artist, or the two together however they're joined.
    for artist in ["Simon & Garfunkel", "Simon and Garfunkel", "Garfunkel", "Simon"] {
        #expect(
            try catalog.titleMatches(artist: artist, title: "Bookends") == [.release(12)],
            "\(artist)")
    }
    #expect(try catalog.titleMatches(artist: "Simon", title: "Stockholm") == [])
}

@Test func aMastersReleasesAreFoundByItsID() throws {
    let folder = try DumpFolder()
    try folder.write("20261101", masters: masters, releases: releases)
    let catalog = try folder.importedCatalog()
    #expect(try catalog.releaseIDs(master: 100) == [10, 11])
    #expect(try catalog.releaseIDs(master: 999) == [])
}

@Test func aReleaseTheDumpGivesMasterZeroHasNoMasterAndIsFoundByItsTitle() throws {
    let folder = try DumpFolder()
    try folder.write(
        "20261101",
        releases:
            #"<release id="20"><artists><artist><id>7</id><name>Seraphim Rytm</name></artist></artists><title>Andromeda</title><master_id is_main_release="false">0</master_id></release>"#
            + "\n")
    let catalog = try folder.importedCatalog()
    #expect(try catalog.release(id: 20)?.masterID == nil)
    #expect(try catalog.titleMatches(artist: "Seraphim Rytm", title: "Andromeda") == [.release(20)])
}
