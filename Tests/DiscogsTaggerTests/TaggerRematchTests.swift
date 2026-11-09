import Foundation
import Library
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Settings

// Matching an album again: choosing a release, and leaving a file out or putting it back;
// and the count of changes that goes with each match.

/// Set once from any thread, read from the test.
private final class Flag: @unchecked Sendable {
    // `value` is guarded by `lock`.
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// View Changes' read doesn't keep a count the mapping changed under.
@MainActor
@Test func aCountReadBeforeTheMappingChangedIsntKept() async throws {
    let one = album(1, "Stockholm", titles: stockholm)
    let entered = Flag()
    let release = Gate()
    let tagger = await model(
        Seen(), albums: [one],
        matches: { album, _ in
            match(album, DiscogsTaggerTests.release(10, "Stockholm", titles: stockholm), tier: .exact)
        },
        files: { ids in
            entered.set()
            release.wait()
            return one.tracks.indices.map { file(one, $0) }.filter { ids.contains($0.id) }
        })
    tagger.analyze()
    await tagger.finished()
    let reading = Task { try await tagger.changeSet(for: 1) }
    try await eventually { entered.isSet }
    tagger.mapping = DiscogsPreset.oneToOne.mapping
    release.open()
    _ = try await reading.value
    #expect(tagger.changeCounts[1] == nil, "counted with the old mapping")
}

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

/// A count that can't be known, as with a file gone, isn't read again on every redraw, and no
/// count is read while other work runs.
@MainActor
@Test func aCountThatCantBeKnownIsntReadAgain() async throws {
    let seen = Seen()
    let gate = Gate()
    let one = album(1, "Stockholm", titles: stockholm)
    let tagger = await model(
        seen, albums: [one],
        matches: { album, _ in
            match(album, release(10, "Stockholm", titles: stockholm), tier: .exact)
        },
        files: { ids in [file(one, 0)].filter { ids.contains($0.id) } }, gate: gate)
    tagger.countDelayNanoseconds = 0
    tagger.analyze()
    gate.open()
    await tagger.finished()
    tagger.selectedID = 1
    tagger.countChanges()
    try await eventually { seen.reads.count == 1 }
    try await Task.sleep(nanoseconds: 50_000_000)
    for _ in 0..<3 { tagger.countChanges() }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(seen.reads.count == 1, "the missing files aren't read for again")
    #expect(tagger.changeCounts[1] == nil)

    tagger.analyze()
    tagger.countChanges()
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(seen.reads.count == 1, "nothing is read while Analyze runs")
    gate.open()
    await tagger.finished()
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
    let ignored = Task { await tagger.choose(82, for: 8) }
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(seen.matched.count == 2, "the choice wasn't matched while the rematch ran")
    // One for the rematch, and one more for each match that shouldn't have started.
    for _ in 1..<seen.matched.count { gate.open() }
    await leaving.value
    await ignored.value

    let choosing = Task { await tagger.choose(82, for: 8) }
    try await eventually { tagger.rematchingID == 8 }
    tagger.selectedID = 9
    tagger.tab = .exact
    gate.open()
    await choosing.value
    #expect(tagger.albums.first { $0.id == 8 }?.match.releaseID == 82)
    #expect(tagger.tab == .exact, "the user moved on, so the tab stays")
}
