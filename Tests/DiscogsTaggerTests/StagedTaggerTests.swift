import Foundation
import Library
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Metadata
@testable import Recommender
@testable import Settings
@testable import TagWriter

// The tagger opened on a staged job with a discrepancy, against fake staged effects: files kept
// in memory, which the staged write changes.

private let stagedRelease = 4242

/// A staged job's files in memory: what the staged write wrote, and what the tagger saw.
private final class StagedFiles: @unchecked Sendable {
    private let lock = NSLock()
    let album: DiscogsAlbum
    private var tags: [Int64: TrackTags]
    private var writes: [[String]] = []
    private var matched: [Int] = []

    init(_ album: DiscogsAlbum) {
        self.album = album
        tags = Dictionary(uniqueKeysWithValues: album.tracks.map { ($0.fileID, TrackTags()) })
    }

    var written: [[String]] { lock.withLock { writes } }
    /// The release each match was asked for.
    var releases: [Int] { lock.withLock { matched } }

    func files() -> [AlbumFile] {
        lock.withLock {
            album.tracks.indices.map {
                file(album, $0, tags[album.tracks[$0].fileID] ?? TrackTags())
            }
        }
    }

    func match(_ release: Int) { lock.withLock { matched.append(release) } }

    private var queries: [ReleaseQuery] = []
    /// What each Look Up searched for.
    var lookedUp: [ReleaseQuery] { lock.withLock { queries } }
    func lookUp(_ query: ReleaseQuery) { lock.withLock { queries.append(query) } }

    /// Writes `edits` as the staged writer would, by path.
    func write(_ edits: [(path: String, edit: TagEdit)]) throws -> TagWriteReport {
        try lock.withLock {
            writes.append(edits.map(\.path))
            for (path, edit) in edits {
                let id = try #require(
                    album.tracks.first { "/m/\(album.id)/\($0.fileID).flac" == path }?.fileID)
                tags[id] = try edit.applied(to: tags[id] ?? TrackTags())
            }
        }
        return report(changed: edits.map(\.path))
    }
}

private func report(changed: [String] = [], notWritten: [String] = []) -> TagWriteReport {
    var report = TagWriteReport()
    report.changed = changed
    report.notWritten = notWritten
    return report
}

/// What the fake staged write does.
private enum Writing {
    /// Writes the edits.
    case applies
    /// Says it wrote them, but the files read back as they were.
    case ignores
    /// Stops before any file.
    case fails
    /// Writes the first file, and stops before the rest.
    case partly
    /// Writes the edits once the gate opens.
    case waits(WriteGate)
}

/// Holds a write until the test opens it, saying when the write has started.
private final class WriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false

    var isWaiting: Bool { lock.withLock { waiting != nil } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = lock.withLock {
                if opened { return true }
                waiting = continuation
                return false
            }
            if go { continuation.resume() }
        }
    }

    func open() {
        let waiter = lock.withLock {
            opened = true
            defer { waiting = nil }
            return waiting
        }
        waiter?.resume()
    }
}

private let staged = StagedJob(
    releaseID: stagedRelease, artist: "Persuader", folder: "job-7", format: .flac, files: [])

@MainActor
private func stagedTagger(
    _ files: StagedFiles, writing: Writing = .applies, choices: TaggerChoices = defaultChoices,
    catalog: TaggerModel.CatalogState = readyCatalog,
    resolved: @escaping (AutoTagRun.Verdict?, Int) -> Void
) async -> TaggerModel {
    let made = TaggerModel(
        stagedJob: staged,
        effects: TaggerModel.StagedEffects(
            read: { (files.album, files.files(), []) },
            match: { album, id in
                files.match(id)
                let release = release(id, "The Hunter", titles: ["Sleeper", "Fire"])
                return match(album, release, tier: id == stagedRelease ? .likely : .exact)
            },
            lookUp: { query, _ in
                files.lookUp(query)
                return ReleaseLookup(releases: [], origin: .catalog, isCut: false)
            },
            summaries: { _ in [] },
            release: { _ in nil },
            checkCatalog: { catalog },
            write: { edits in
                switch writing {
                case .applies: return try files.write(edits)
                case .ignores: return report(changed: edits.map(\.path))
                case .fails: return report(notWritten: edits.map(\.path))
                case .partly:
                    _ = try files.write(Array(edits.prefix(1)))
                    return report(
                        changed: edits.prefix(1).map(\.path),
                        notWritten: edits.dropFirst().map(\.path))
                case .waits(let gate):
                    await gate.wait()
                    return try files.write(edits)
                }
            }),
        mapping: DiscogsPreset.minimal.mapping, savedMappings: [], choices: choices,
        resolved: resolved)
    await made.checkCatalog()
    return made
}

private let bonusAlbum = album(-1, "The Hunter", titles: ["Sleeper", "Fire"])

@MainActor @Test func aStagedJobOpensWithItsReleaseChosen() async throws {
    let files = StagedFiles(bonusAlbum)
    let tagger = await stagedTagger(files) { _, _ in }
    #expect(tagger.isStaged)
    tagger.analyze()
    await tagger.finished()
    #expect(files.releases == [stagedRelease])
    #expect(tagger.albums.map(\.id) == [-1])
    #expect(tagger.albums.first?.match.releaseID == stagedRelease)
    #expect(tagger.selectedID == -1)
    #expect(!tagger.canLeaveOut, "a staged job's files move into the library together")
    await tagger.setLeftOut(true, bonusAlbum.tracks[0].fileID, of: -1)
    #expect(tagger.albums.first?.leftOut == [])

}

/// The files may be another edition than the release queued, as one with a bonus track: the
/// owner chooses the release they are, and Apply reports it with the verdict (ADR 0178).
@MainActor @Test func aStagedJobCanBeTaggedAsAnotherRelease() async throws {
    let files = StagedFiles(bonusAlbum)
    var resolved: [(AutoTagRun.Verdict?, Int)] = []
    let tagger = await stagedTagger(files) { resolved.append(($0, $1)) }
    tagger.analyze()
    await tagger.finished()
    var failures: [String] = []
    tagger.failed = { message, details in failures.append(([message] + details).joined()) }
    await tagger.choose(99, for: -1)
    #expect(failures.isEmpty)
    #expect(files.releases == [stagedRelease, 99])
    #expect(tagger.albums.first?.match.releaseID == 99)
    #expect(tagger.albums.first?.review == .chosen(releaseID: 99))
    #expect(tagger.tab == .exact)

    // Analyze again keeps the release chosen.
    tagger.analyze()
    await tagger.finished()
    #expect(files.releases.last == 99)

    tagger.apply(try #require(await tagger.plan([-1])))
    try await eventually { !resolved.isEmpty }
    #expect(resolved.map(\.0) == [.clean])
    #expect(resolved.map(\.1) == [99])

    // Rejecting is Downloads' job, which deletes the staged folder.
    await tagger.setRejected(true, [-1])
    #expect(failures.last?.contains("rejected in Downloads") == true)
    #expect(tagger.albums.first?.isRejected == false)
}

@MainActor @Test func aStagedJobsApplyReportsTheQueuedReleaseWhenNoneWasChosen() async throws {
    let files = StagedFiles(bonusAlbum)
    var releases: [Int] = []
    let tagger = await stagedTagger(files) { releases.append($1) }
    tagger.analyze()
    await tagger.finished()
    tagger.apply(try #require(await tagger.plan([-1])))
    try await eventually { !releases.isEmpty }
    #expect(releases == [stagedRelease])
}

@MainActor @Test func aStagedJobCanLookUpAnotherRelease() async throws {
    let files = StagedFiles(bonusAlbum)
    let tagger = await stagedTagger(files) { _, _ in }
    tagger.analyze()
    await tagger.finished()
    #expect(tagger.canLookUp)
    _ = try await tagger.lookUp(ReleaseQuery(artist: "Persuader", title: "The Hunter"))
    #expect(files.lookedUp == [ReleaseQuery(artist: "Persuader", title: "The Hunter")])
}

@MainActor @Test func applyWritesThroughTheStagedWriterAndReportsItClean() async throws {
    let files = StagedFiles(bonusAlbum)
    var verdicts: [AutoTagRun.Verdict?] = []
    let tagger = await stagedTagger(files) { verdict, _ in verdicts.append(verdict) }
    var mainWrites = 0
    tagger.write = { _, _, _ in mainWrites += 1 }
    tagger.analyze()
    await tagger.finished()
    let plan = try #require(await tagger.plan([-1]))
    #expect(plan.files.count == 2)
    let detail = TaggerModel.confirmation(plan, staged: true).detail
    #expect(detail.contains("Edit > Undo doesn't") && !detail.contains("Undo Tag Edit"))

    tagger.apply(plan)
    try await eventually { !verdicts.isEmpty }
    #expect(verdicts == [.clean])
    #expect(files.written == [plan.files.map(\.path)])
    #expect(mainWrites == 0, "never the main writer, its undo journal or its watcher")
    #expect(tagger.status.contains("Edit > Undo doesn't"))
}

@MainActor @Test func anUntickedChangeIsTheOwnersChoiceAndStillClean() async throws {
    let files = StagedFiles(bonusAlbum)
    var verdicts: [AutoTagRun.Verdict?] = []
    let tagger = await stagedTagger(files) { verdict, _ in verdicts.append(verdict) }
    tagger.analyze()
    await tagger.finished()
    let (changes, _) = try #require(try await tagger.changeSet(for: -1))
    let kept = try #require(changes.files.first?.changes.first?.id)
    tagger.setExcluded([kept], for: -1)
    tagger.apply(try #require(await tagger.plan([-1])))
    try await eventually { !verdicts.isEmpty }
    #expect(verdicts == [.clean])
}

@MainActor @Test func filesThatReadBackUnchangedAreStillADiscrepancy() async throws {
    let files = StagedFiles(bonusAlbum)
    var verdicts: [AutoTagRun.Verdict?] = []
    let tagger = await stagedTagger(files, writing: .ignores) { verdict, _ in
        verdicts.append(verdict)
    }
    tagger.analyze()
    await tagger.finished()
    let plan = try #require(await tagger.plan([-1]))
    tagger.apply(plan)
    try await eventually { !verdicts.isEmpty }
    #expect(
        verdicts == [
            .discrepancy(["the files read back with \(plan.fieldCount) tags still to change"])
        ])
}

@MainActor @Test func aStagedWriteThatFailsReportsNothingAndCanBeAppliedAgain() async throws {
    let files = StagedFiles(bonusAlbum)
    var verdicts: [AutoTagRun.Verdict?] = []
    let tagger = await stagedTagger(files, writing: .fails) { verdict, _ in verdicts.append(verdict)
    }
    tagger.analyze()
    await tagger.finished()
    tagger.apply(try #require(await tagger.plan([-1])))
    try await eventually { tagger.status.contains("not fully written") }
    #expect(verdicts.isEmpty)
    #expect(tagger.applicable(.likely).map(\.id) == [-1])
}

@MainActor @Test func aStagedWriteTakesNoCoverWhateverTheArtworkMode() async throws {
    let files = StagedFiles(bonusAlbum)
    var choices = defaultChoices
    choices.artwork = .replace
    let tagger = await stagedTagger(files, choices: choices) { _, _ in }
    tagger.hasToken = { true }
    tagger.analyze()
    await tagger.finished()
    let plan = try #require(await tagger.plan([-1]))
    #expect(plan.coverCount == 0)
    #expect(plan.problems.isEmpty, "\(plan.problems)")
}

@MainActor @Test func aStagedJobLooksItsReleaseUpInTheCatalogOnly() async throws {
    let tagger = await stagedTagger(StagedFiles(bonusAlbum), catalog: .missing) { _, _ in }
    #expect(tagger.source == .catalog)
    #expect(tagger.runSource == .catalog)
    #expect(!tagger.canAnalyze)
    tagger.chooseSource(.api)
    #expect(tagger.source == .catalog)
}

/// Open in Tagger shows the staged album analyzed, on its tier's tab, so a discrepancy can be
/// fixed at once; a catalog that can't be used is said, not left as an empty window.
@MainActor @Test func aStagedTaggerAnalyzesItsAlbumWhenItOpens() async throws {
    let tagger = DiscogsTagger(model: await stagedTagger(StagedFiles(bonusAlbum)) { _, _ in })
    tagger.show()
    try await eventually { tagger.model.albums.count == 1 && !tagger.model.isBusy }
    #expect(tagger.model.tab == .likely)
    #expect(tagger.model.selectedID == -1)
    tagger.window?.close()

    let missing = DiscogsTagger(
        model: await stagedTagger(StagedFiles(bonusAlbum), catalog: .missing) { _, _ in })
    var failures: [[String]] = []
    missing.show()
    // After the window, which sets its own, and before the check the show starts answers.
    missing.model.failed = { message, details in failures.append([message] + details) }
    try await eventually { !failures.isEmpty }
    #expect(
        failures == [
            ["The staged album wasn't analyzed", "there's no Discogs catalog on this Mac"]
        ])
    #expect(missing.model.albums.isEmpty)
    missing.window?.close()
}

/// A write that reaches some of the files leaves them as the release chosen, so that release
/// is passed on to be kept, with no verdict, and the rest can be applied again (ADR 0178).
@MainActor @Test func aPartialStagedWritePassesOnItsReleaseWithNoVerdict() async throws {
    let files = StagedFiles(bonusAlbum)
    var resolved: [(AutoTagRun.Verdict?, Int)] = []
    let tagger = await stagedTagger(files, writing: .partly) { resolved.append(($0, $1)) }
    tagger.analyze()
    await tagger.finished()
    await tagger.choose(99, for: -1)
    tagger.apply(try #require(await tagger.plan([-1])))
    try await eventually { tagger.status.contains("not fully written") }
    #expect(resolved.count == 1)
    #expect(resolved.first?.0 == nil)
    #expect(resolved.first?.1 == 99)
    #expect(tagger.applicable(.exact).map(\.id) == [-1], "the rest can be applied again")
}

/// The window doesn't lock while a staged write runs, so a release chosen meanwhile isn't the
/// one the files were written as.
@MainActor @Test func aStagedWriteReportsTheReleaseItsPlanWasMadeWith() async throws {
    let files = StagedFiles(bonusAlbum)
    let gate = WriteGate()
    var resolved: [(AutoTagRun.Verdict?, Int)] = []
    let tagger = await stagedTagger(files, writing: .waits(gate)) { resolved.append(($0, $1)) }
    tagger.analyze()
    await tagger.finished()
    await tagger.choose(99, for: -1)
    tagger.apply(try #require(await tagger.plan([-1])))
    try await eventually { gate.isWaiting }
    await tagger.choose(77, for: -1)
    #expect(tagger.albums.first?.match.releaseID == 77)
    gate.open()
    try await eventually { !resolved.isEmpty }
    #expect(resolved.map(\.1) == [99])
}

@MainActor @Test func aStagedPlanWithNoMatchedAlbumWritesNothing() async throws {
    let files = StagedFiles(bonusAlbum)
    var resolved = 0
    let tagger = await stagedTagger(files) { _, _ in resolved += 1 }
    var failures: [[String]] = []
    tagger.failed = { failures.append([$0] + $1) }
    tagger.apply(
        TaggerModel.ApplyPlan(
            albumIDs: [-5], files: [(path: "/m/-1/1.flac", edit: TagEdit())], fieldCount: 1,
            problems: []))
    try await eventually { !failures.isEmpty }
    #expect(
        failures == [["The staged files weren't written", "the album has no release to write"]])
    #expect(files.written.isEmpty)
    #expect(resolved == 0)
}
