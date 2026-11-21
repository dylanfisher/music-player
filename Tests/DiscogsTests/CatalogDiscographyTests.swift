import Foundation
import Testing

@testable import Discogs
@testable import Recommender

private let releases = """
    <release id="10"><artists><artist><id>2</id><name>Simon</name><join>&amp;</join></artist><artist><id>3</id><name>Garfunkel (2)</name></artist><artist><id>2</id><name>Simon</name></artist></artists><title>Bookends</title><master_id is_main_release="true">100</master_id></release>
    <release id="12"><artists><artist><name>Unlinked</name></artist><artist><id>194</id><name>Various</name></artist><artist><id>5</id><name>Made-Up Artist</name></artist></artists><title>Made-Up Split</title></release>

    """

private let masters = """
    <master id="100"><main_release>10</main_release><artists><artist><id>2</id><name>Simon</name></artist></artists><title>Bookends</title><year>1968</year></master>

    """

private let artists = """
    <artist><id>3</id><name>Garfunkel (2)</name></artist>

    """

@Test func aReleaseOrMasterHasItsLinkedMainArtistsInOrder() throws {
    let folder = try DumpFolder()
    try folder.write("20261101", artists: artists, masters: masters, releases: releases)
    let catalog = try folder.importedCatalog()
    #expect(
        try catalog.discographyArtists(release: 10) == [
            RecommendationPage.Named(id: 2, name: "Simon"),
            RecommendationPage.Named(id: 3, name: "Garfunkel"),
            RecommendationPage.Named(id: 2, name: "Simon"),
        ])
    #expect(try catalog.discographyArtists(release: 12)?.map(\.id) == [194, 5])
    #expect(try catalog.discographyArtists(release: 99) == nil)
    #expect(try catalog.discographyArtists(master: 100)?.map(\.id) == [2])
    #expect(try catalog.discographyArtists(master: 99) == nil)
    #expect(try catalog.artistName(3) == "Garfunkel")
    #expect(try catalog.artistName(4) == nil)
}
