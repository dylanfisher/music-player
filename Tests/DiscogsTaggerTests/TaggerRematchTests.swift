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

/// One album is matched again at a time: a release chosen while a file's rematch runs is
/// ignored, and a rematch that ends after the user moved to another album leaves the tab.
@MainActor
@Test func onlyOneRematchRunsAndTheTabStaysWithTheUser() async throws {
    let seen = Seen()
    let gate = Gate()
    let doubled = album(8, "Stockholm", titles: ["Östermalm", "Östermalm", "Gamla Stan"])
    let other = album(9, "Other", titles: stockholm)
    let tagger = await model(
        seen, albums: [doubled, other],
        matches: { album, chosen in
            match(
                album, release(chosen ?? 80, "Stockholm", titles: stockholm),
                tier: album.id == 9 ? .exact : chosen == nil ? .incomplete : .likely)
        }, gate: gate)
    tagger.analyze()
    for _ in 0..<2 { gate.open() }
    await tagger.finished()
    tagger.selectedID = 8
    tagger.tab = .incomplete

    let leaving = Task { await tagger.setLeftOut(true, 801, of: 8) }
    try await eventually { tagger.rematchingID == 8 }
    await tagger.choose(82, for: 8)
    #expect(seen.matched.count == 2, "the choice wasn't matched while the rematch ran")
    gate.open()
    await leaving.value

    let choosing = Task { await tagger.choose(82, for: 8) }
    try await eventually { tagger.rematchingID == 8 }
    tagger.selectedID = 9
    tagger.tab = .exact
    gate.open()
    await choosing.value
    #expect(tagger.albums.first { $0.id == 8 }?.match.releaseID == 82)
    #expect(tagger.tab == .exact, "the user moved on, so the tab stays")
}
