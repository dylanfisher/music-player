import Foundation
import Settings
import Testing

@testable import Recommender

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// An album of Threads with the id `id`, never played and of no year unless given.
private func album(
    _ id: String, plays: Int = 0, lastPlayed: Int? = nil, year: Int? = nil
) -> RediscoverDay.Album {
    RediscoverDay.Album(
        id: id, key: "a\(id)", artist: "Made-Up Artist", title: "Album \(id)", releaseID: nil,
        year: year, label: nil, styles: [], plays: plays, skips: 0, lastPlayed: lastPlayed,
        score: nil, community: nil, reasons: [])
}

private func thread(_ kind: RediscoverDay.Thread.Kind, _ ids: [String])
    -> RediscoverDay.Thread
{
    RediscoverDay.Thread(kind: kind, words: "\(kind)", ids: ids, artist: nil, label: nil)
}

/// Threads of a seed from `seedYear` holding `albums` in `threads`.
private func reply(
    _ albums: [RediscoverDay.Album], _ threads: [RediscoverDay.Thread], seedYear: Int? = 1990
) -> AlbumThreads {
    AlbumThreads(
        seed: album("seed", year: seedYear), computedAt: 1_800_000_000, albums: albums,
        threads: threads)
}

private func filter(
    otherArtistsOnly: Bool = false, hidden: Set<ThreadsKind> = [],
    played: ThreadsPlayed = .anyTime, years: ThreadsYears = .anyYear
) -> ThreadsFilter {
    ThreadsFilter(
        otherArtistsOnly: otherArtistsOnly, hiddenKinds: hidden, played: played, years: years)
}

@Test func theDefaultsShowEveryThreadAndAlbum() {
    let threads = reply(
        [album("1"), album("2"), album("3")],
        [thread(.artist, ["1"]), thread(.credit, ["2", "3"]), thread(.styles, ["3"])])
    let shown = threads.shown(by: .defaults, now: now)
    #expect(ThreadsFilter.defaults == filter())
    #expect(shown.threads.map(\.place) == [0, 1, 2])
    #expect(shown.threads.map(\.ids) == [["1"], ["2", "3"], ["3"]])
    #expect(shown.albums == ["1", "2", "3"])
}

@Test func otherArtistsOnlyHidesTheArtistThreadAndTheAlbumsOnlyItHas() {
    // "2" is in the artist thread and a credit thread, as an album of the seed artist's that
    // another thread has too.
    let threads = reply(
        [album("1"), album("2"), album("3")],
        [thread(.artist, ["1", "2"]), thread(.credit, ["2", "3"])])
    let shown = threads.shown(by: filter(otherArtistsOnly: true), now: now)
    #expect(shown.threads.map(\.place) == [1])
    #expect(shown.albums == ["2", "3"])
}

@Test func aHiddenKindsThreadIsntListedAndItsAlbumsLeaveAll() {
    let threads = reply(
        [album("1"), album("2"), album("3")],
        [thread(.artist, ["1"]), thread(.label, ["2"]), thread(.styles, ["2", "3"])])
    let shown = threads.shown(by: filter(hidden: [.styles]), now: now)
    #expect(shown.threads.map(\.place) == [0, 1], "the artist thread is the checkbox's")
    #expect(shown.albums == ["1", "2"])
}

@Test func neverPlayedKeepsOnlyAlbumsOfNoPlays() {
    let threads = reply(
        [album("1"), album("2", plays: 3, lastPlayed: 1_000)], [thread(.credit, ["1", "2"])])
    let shown = threads.shown(by: filter(played: .neverPlayed), now: now)
    #expect(shown.threads.map(\.ids) == [["1"]] && shown.albums == ["1"])
}

@Test func notInAYearKeepsTheNeverPlayedAndThoseLastPlayedOverAYearAgo() {
    let day = 86_400
    let at = Int(now.timeIntervalSince1970)
    let threads = reply(
        [
            album("never"), album("old", plays: 4, lastPlayed: at - 366 * day),
            album("recent", plays: 4, lastPlayed: at - 364 * day),
            // Plays without a last play the player saw: none it knows of in the year.
            album("imported", plays: 9, lastPlayed: nil),
        ], [thread(.credit, ["never", "old", "recent", "imported"])])
    let shown = threads.shown(by: filter(played: .notInAYear), now: now)
    #expect(shown.albums == ["never", "old", "imported"])
}

@Test func yearsKeepAlbumsNearTheSeedsYearAndLeaveOutThoseWithout() {
    let threads = reply(
        [album("1", year: 1995), album("2", year: 1996), album("3"), album("4", year: 1978)],
        [thread(.credit, ["1", "2", "3", "4"])])
    #expect(threads.shown(by: filter(years: .within5Years), now: now).albums == ["1"])
    #expect(threads.shown(by: filter(years: .within10Years), now: now).albums == ["1", "2"])
    let noYear = reply(threads.albums, threads.threads, seedYear: nil)
    #expect(
        noYear.shown(by: filter(years: .within5Years), now: now).albums == ["1", "2", "3", "4"],
        "Years applies only while the seed has a year")
}

@Test func aThreadAllOfWhoseAlbumsTheFiltersLeaveOutIsListedEmpty() {
    let threads = reply(
        [album("1"), album("2", plays: 1, lastPlayed: 1_000)],
        [thread(.credit, ["1"]), thread(.label, ["2"])])
    let shown = threads.shown(by: filter(played: .neverPlayed), now: now)
    #expect(shown.threads.map(\.place) == [0, 1])
    #expect(shown.threads.map(\.ids) == [["1"], []])
    #expect(shown.albums == ["1"])
}

@Test func everyKindButArtistIsAnItemOfKinds() {
    let kinds: [RediscoverDay.Thread.Kind] = [.artist, .credit, .related, .label, .styles]
    #expect(kinds.map(\.choice) == [nil, .credit, .related, .label, .styles])
}

@MainActor @Test func theFiltersSaveToTheSettingsAndReadBack() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("threads-filter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let settings = ConfigStore(
        AppSettings(), fileURL: folder.appendingPathComponent("config.json", isDirectory: false),
        check: { _, _, _ in nil }, creating: false)
    #expect(ThreadsFilter(settings) == .defaults)
    let chosen = filter(
        otherArtistsOnly: true, hidden: [.styles, .credit], played: .notInAYear,
        years: .within10Years)
    try chosen.save(to: settings)
    #expect(ThreadsFilter(settings) == chosen)
    #expect(settings[\.threadsHiddenKinds] == [.credit, .styles], "in the pull-down's order")
}

@Test func notInAYearTakesAnAlbumLastPlayedExactly365DaysAgoAsPlayedInTheYear() {
    let at = Int(now.timeIntervalSince1970)
    let year = 365 * 86_400
    let threads = reply(
        [
            album("edge", plays: 1, lastPlayed: at - year),
            album("past", plays: 1, lastPlayed: at - year - 1),
        ], [thread(.credit, ["edge", "past"])])
    #expect(threads.shown(by: filter(played: .notInAYear), now: now).albums == ["past"])
}

@Test func yearsTakeAnAlbumExactlyTheSpanFromTheSeedInEitherDirection() {
    for (years, span) in [(ThreadsYears.within5Years, 5), (.within10Years, 10)] {
        let threads = reply(
            [
                album("before", year: 1990 - span), album("after", year: 1990 + span),
                album("beyond", year: 1990 + span + 1), album("under", year: 1990 - span - 1),
            ], [thread(.credit, ["before", "after", "beyond", "under"])])
        #expect(
            threads.shown(by: filter(years: years), now: now).albums == ["before", "after"],
            "\(years)")
    }
}
