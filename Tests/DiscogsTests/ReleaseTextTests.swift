import Foundation
import Testing

@testable import Discogs

/// Get Info's Discogs tab: a release from the local catalog as plain lines, its label and
/// catalog number, country, date, format, genres, styles, credits and tracklist (53.11).
@Test func aReleasesTextHasItsFactsCreditsAndTracklist() async throws {
    let folder = try DumpFolder()
    try folder.write("20261101", masters: apiDumpMasters, releases: apiDumpReleases)
    try folder.importCatalog()
    let stockholm = try #require(try await releaseDetail(1001, catalogAt: folder.catalog))
    #expect(
        stockholm.text == """
            Persuader – Stockholm
            Labels: Svek – SK 032
            Release Country: Sweden
            Released: 1999-03
            Release Formats: CD (Album)
            Genres: Electronic
            Styles: Techno, Minimal

            Credits
            Producer: Jesper Dahlbäck

            Tracklist
            1\tÖstermalm\t4:45
            2\tGamla Stan\t6:10
            3\tKungsholmen\t5:00
            """)
    let duos = try #require(try await releaseDetail(1005, catalogAt: folder.catalog))
    let credits = duos.text.components(separatedBy: "\n\n")[1]
    #expect(
        credits == """
            Credits
            Written-By [All Tracks By]: J. Dahlbäck (1, 2)
            Mastered By: Unlinked Engineer
            """)
    // The heading is View Release's.
    #expect(duos.text.hasPrefix("\(duos.summary.artist) – \(duos.summary.title)\n"))
    #expect(duos.text.contains("\nReleased: 2003\n"))
}
