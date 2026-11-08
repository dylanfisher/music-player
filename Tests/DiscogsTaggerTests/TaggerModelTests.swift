import Foundation
import Library
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Metadata
@testable import Settings
@testable import TagWriter

private let stockholm = ["Östermalm", "Gamla Stan", "Kungsholmen"]
private let one = album(1, "Stockholm", titles: stockholm)
private let two = album(2, "Second", artist: "Abba", titles: ["A", "B"])
private let tagged = album(3, "Tagged", titles: ["X"], releaseID: "30")

/// Each album its own release: Stockholm Exact as 10, Second Likely as 20, Tagged Matched; a
/// chosen release makes it Likely.
private let matches: @Sendable (DiscogsAlbum, Int?) -> AlbumMatch = { album, chosen in
    if let chosen {
        return match(album, release(chosen, "Chosen", titles: stockholm), tier: .likely)
    }
    switch album.id {
    case 1:
        return match(
            album, release(10, "Stockholm", titles: stockholm), tier: .exact,
            candidates: [11, 12])
    case 2: return match(album, release(20, "Second", titles: ["A", "B"]), tier: .likely)
    default: return match(album, release(30, "Tagged", titles: ["X"]), tier: .matched)
    }
}

@MainActor
@Test func analyzeMatchesTheScopesAlbumsWithTheirReviewsAndReportsProgress() async throws {
    let seen = Seen()
    let gate = Gate()
    let tagger = await model(
        seen, albums: [one, two, tagged], matches: matches,
        reviews: [1: .chosen(releaseID: 11), 2: .rejected], gate: gate)
    tagger.analyze()
    #expect(tagger.isBusy)
    #expect(!tagger.canAnalyze, "one run at a time")
    gate.open()
    try await eventually { tagger.activity == .analyzing(done: 1, total: 3) }
    for _ in 0..<2 { gate.open() }
    await tagger.finished()
    #expect(seen.matched == [[1: 11]], "the chosen release is the match")
    #expect(tagger.count(.likely) == 2)
    #expect(tagger.count(.matched) == 1)
    #expect(tagger.albums(in: .likely).map(\.id) == [2, 1], "by artist, then title")
    #expect(tagger.albums.first { $0.id == 2 }?.isRejected == true)
    #expect(tagger.activity == .idle)
    #expect(tagger.status.hasPrefix("Analyzed 3 albums"))

    tagger.scope = .unmatched
    tagger.analyze()
    for _ in 0..<2 { gate.open() }
    await tagger.finished()
    #expect(Set(tagger.albums.map(\.id)) == [1, 2], "no track of theirs has a release id")

    tagger.scope = .selection
    tagger.selectedTracks = { [two.tracks[1].fileID] }
    tagger.analyze()
    gate.open()
    await tagger.finished()
    #expect(tagger.albums.map(\.id) == [2])
}

@MainActor
@Test func aSelectionScopeWithNothingSelectedSaysSoAndStopping() async throws {
    let seen = Seen()
    let gate = Gate()
    let tagger = await model(seen, albums: [one, two], matches: matches, gate: gate)
    var failures: [String] = []
    tagger.failed = { message, _ in failures.append(message) }
    tagger.scope = .selection
    tagger.analyze()
    #expect(failures == ["No tracks are selected"])
    #expect(!tagger.isBusy)

    tagger.scope = .library
    tagger.analyze()
    tagger.stop()
    gate.open()
    gate.open()
    await tagger.finished()
    #expect(tagger.albums.isEmpty, "a stopped run shows the last run's albums")
    #expect(tagger.status.hasPrefix("Analyze stopped"))
    #expect(!tagger.isBusy)
}

@MainActor
@Test func withoutACatalogNothingIsAnalyzed() async {
    let seen = Seen()
    let tagger = await model(seen, albums: [one], matches: matches, catalog: .missing)
    await tagger.checkCatalog()
    #expect(tagger.catalog == .missing)
    #expect(!tagger.canAnalyze)
    tagger.analyze()
    #expect(seen.matched.isEmpty)
}

@MainActor
@Test func choosingAReleaseRescoresTheAlbumAndRemembersIt() async throws {
    let seen = Seen()
    let tagger = await model(seen, albums: [one, two], matches: matches)
    tagger.analyze()
    await tagger.finished()
    tagger.selectedID = 1
    let candidates = try await tagger.candidates()
    #expect(candidates.map(\.summary.id) == [10, 11, 12], "the chosen one first")
    #expect(candidates.map(\.score) == [nil, 0.7, 0.7])

    await tagger.choose(12, for: 1)
    #expect(tagger.selected?.match.releaseID == 12)
    #expect(tagger.selected?.review == .chosen(releaseID: 12))
    #expect(tagger.tab == .likely, "the tab its new tier is in")
    #expect(seen.reviews.last?.0 == .chosen(releaseID: 12))
    #expect(seen.reviews.last?.1 == one.tracks.map(\.fileID))

    await tagger.setRejected(true, 1)
    #expect(tagger.selected?.isRejected == true)
    await tagger.setRejected(false, 1)
    #expect(tagger.selected?.review == .chosen(releaseID: 12), "the choice comes back")
    await tagger.setRejected(true, 2)
    await tagger.setRejected(false, 2)
    #expect(
        seen.reviews.map(\.0) == [
            .chosen(releaseID: 12), .rejected, .chosen(releaseID: 12), .rejected, nil,
        ])
}

@MainActor
@Test func onlyAGuessedMatchsRowsCanBeRemapped() async {
    let seen = Seen()
    let tagger = await model(seen, albums: [one, two], matches: matches)
    tagger.analyze()
    await tagger.finished()
    tagger.selectedID = 1
    #expect(!tagger.canRemap, "Exact")
    tagger.assign(100, to: 2)
    #expect(tagger.selected?.match.mapping[100] == 0)
    tagger.selectedID = 2
    #expect(tagger.canRemap, "Likely")
    tagger.assign(200, to: 1)
    #expect(tagger.selected?.match.mapping == [200: 1, 201: 0])
}

@MainActor
@Test func applyToAllPlansTheReviewedChangesAndWritesOnlyOnceConfirmed() async throws {
    let seen = Seen()
    let albums = [
        one, album(4, "Another", titles: stockholm), album(5, "Rejected", titles: stockholm),
    ]
    let tagger = await model(
        seen, albums: albums,
        matches: { album, _ in
            match(album, release(Int(album.id) * 10, album.title, titles: stockholm), tier: .exact)
        },
        reviews: [5: .rejected],
        files: { ids in
            albums.flatMap { album in album.tracks.indices.map { file(album, $0) } }
                .filter { ids.contains($0.id) }
        })
    var written: [[(path: String, edit: TagEdit)]] = []
    var completion: (Set<String>) -> Void = { _ in }
    tagger.write = { files, done in
        written.append(files)
        completion = done
    }
    tagger.analyze()
    await tagger.finished()
    #expect(tagger.applicable(.exact).map(\.id) == [4, 1], "not the rejected album")

    // View Changes unticked album 4's release id on its first file.
    let (set, problems) = try #require(try await tagger.changeSet(for: 4))
    #expect(problems.isEmpty)
    let releaseID = try #require(
        set.files[0].changes.first { $0.field == .releaseID }?.id)
    tagger.setExcluded([releaseID], for: 4)

    let plan = try #require(await tagger.plan(tagger.applicable(.exact).map(\.id)))
    #expect(written.isEmpty, "nothing is written before the confirmation")
    #expect(seen.reads.last?.count == 6, "the two albums' files")
    #expect(plan.albumIDs.sorted() == [1, 4])
    #expect(plan.files.count == 6)
    // Minimal writes the release id, label, catalog number and year to each file.
    #expect(plan.fieldCount == 6 * 4 - 1)
    let first = try #require(plan.files.first { $0.path.hasSuffix("/400.flac") })
    #expect(first.edit.custom[DiscogsKey.releaseID] == nil)
    let (message, detail) = TaggerModel.confirmation(plan)
    #expect(message == "Change 23 tags in 6 files of 2 albums?")
    #expect(detail.contains("Undo Tag Edit"))

    tagger.apply(plan)
    #expect(written.count == 1)
    #expect(written[0].count == 6)
    #expect(tagger.applicable(.exact).isEmpty, "each album is written once a session")

    // A file of album 4 that wasn't written puts that album back, and only that one.
    completion([try #require(plan.files.first { $0.path.hasSuffix("/400.flac") }).path])
    #expect(tagger.applicable(.exact).map(\.id) == [4], "a failed write can be applied again")
}

@MainActor
@Test func viewChangesSaysWhenAFileIsGone() async throws {
    let seen = Seen()
    let tagger = await model(
        seen, albums: [one],
        matches: { album, _ in
            match(album, release(10, album.title, titles: stockholm), tier: .exact)
        },
        files: { ids in
            [file(one, 0)].filter { ids.contains($0.id) }
        })
    tagger.analyze()
    await tagger.finished()
    let (_, problems) = try #require(try await tagger.changeSet(for: one.id))
    #expect(problems == ["\(one.tracks.count - 1) files no longer in the library"])
}

@MainActor
@Test func stoppingApplysReadWritesNothing() async throws {
    let seen = Seen()
    let gate = Gate()
    let tagger = TaggerModel(
        effects: .init(
            albums: { [one] }, reviews: { [:] }, review: { _, _ in },
            match: { albums, _, _ in albums.map { matches($0, nil) } },
            summaries: { _ in [] },
            read: { ids, _ in
                seen.read(ids)
                gate.wait()
                try Task.checkCancellation()
                return ([], [])
            },
            checkCatalog: { .ready }, unfinishedImport: { nil },
            importCatalog: { _, _, _ in throw CatalogImportError.stopped }),
        mapping: DiscogsPreset.minimal.mapping, savedMappings: [])
    await tagger.checkCatalog()
    tagger.analyze()
    await tagger.finished()
    let planning = Task { await tagger.plan([1]) }
    try await eventually { tagger.activity == .reading(done: 0, total: 3) }
    tagger.stop()
    gate.open()
    #expect(await planning.value == nil)
    #expect(tagger.status.hasPrefix("Stopped reading"))
    #expect(!tagger.isBusy)
}

@MainActor
@Test func anImportReportsItsProgressAndChecksTheCatalogAfter() async throws {
    let checks = Seen()
    let gate = Gate()
    let tagger = TaggerModel(
        effects: .init(
            albums: { [] }, reviews: { [:] }, review: { _, _ in },
            match: { _, _, _ in [] }, summaries: { _ in [] }, read: { _, _ in ([], []) },
            checkCatalog: {
                checks.read([])
                return .ready
            },
            unfinishedImport: { UnfinishedImport(dumpDate: "20261101", fraction: 0.42) },
            importCatalog: { _, _, _ in
                gate.wait()
                throw CatalogImportError.stopped
            }),
        mapping: DiscogsPreset.minimal.mapping, savedMappings: [])
    tagger.importDump(from: URL(fileURLWithPath: "/dumps", isDirectory: true))
    #expect(tagger.activity == .importing(nil))
    #expect(!tagger.canAnalyze)
    gate.open()
    // checkCatalog sets the catalog, then awaits the unfinished import.
    try await eventually {
        checks.reads.count == 1 && tagger.catalog == .ready && tagger.unfinished != nil
    }
    #expect(tagger.status == "Import stopped; Resume Import carries on from here")
    #expect(tagger.unfinished == UnfinishedImport(dumpDate: "20261101", fraction: 0.42))
    #expect(tagger.activity == .idle)
}
