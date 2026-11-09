import Foundation
import Library
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Settings

// Matching an album again: choosing a release, and leaving a file out or putting it back.

private let stockholm = ["Östermalm", "Gamla Stan", "Kungsholmen"]

/// A release Look Up found on Discogs stays matched with the API when a file is left out
/// later, with the catalog as the source.
@MainActor
@Test func leavingAFileOutOfAnAPIReleaseMatchesWithTheAPI() async throws {
    let seen = Seen()
    let doubled = album(8, "Stockholm", titles: ["Östermalm", "Östermalm", "Gamla Stan"])
    let tagger = await model(
        seen, albums: [doubled],
        matches: { album, chosen in
            var found = match(
                album, release(chosen ?? 80, "Stockholm", titles: stockholm), tier: .likely)
            if chosen == 81 { found.origin = .api }
            return found
        })
    tagger.analyze()
    await tagger.finished()
    tagger.selectedID = 8
    await tagger.choose(81, for: 8, from: .api)
    #expect(seen.sources.last == .both)
    await tagger.setLeftOut(true, 801, of: 8)
    #expect(seen.matched.last == [8: 81])
    #expect(seen.sources.last == .both, "not the catalog alone, which lacks the release")
}
