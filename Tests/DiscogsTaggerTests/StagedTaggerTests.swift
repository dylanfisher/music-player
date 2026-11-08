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
}

private let staged = StagedJob(
    releaseID: stagedRelease, artist: "Persuader", folder: "job-7", format: .flac, files: [])

@MainActor
private func stagedTagger(
    _ files: StagedFiles, writing: Writing = .applies,
    resolved: @escaping (AutoTagRun.Verdict) -> Void
) async -> TaggerModel {
    let release = release(stagedRelease, "The Hunter", titles: ["Sleeper", "Fire"])
    let made = TaggerModel(
        stagedJob: staged,
        effects: TaggerModel.StagedEffects(
            read: { (files.album, files.files(), []) },
            match: { album, id in
                files.match(id)
                return match(album, release, tier: .likely)
            },
            summaries: { _ in [] },
            checkCatalog: { readyCatalog },
            write: { edits in
                switch writing {
                case .applies: return try files.write(edits)
                case .ignores: return report(changed: edits.map(\.path))
                case .fails: return report(notWritten: edits.map(\.path))
                }
            }),
        mapping: DiscogsPreset.minimal.mapping, savedMappings: [], choices: defaultChoices,
        resolved: resolved)
    await made.checkCatalog()
    return made
}

private let bonusAlbum = album(-1, "The Hunter", titles: ["Sleeper", "Fire"])

@MainActor @Test func aStagedJobOpensWithItsReleaseChosen() async throws {
    let files = StagedFiles(bonusAlbum)
    let tagger = await stagedTagger(files) { _ in }
    #expect(tagger.isStaged)
    tagger.analyze()
    await tagger.finished()
    #expect(files.releases == [stagedRelease])
    #expect(tagger.albums.map(\.id) == [-1])
    #expect(tagger.albums.first?.match.releaseID == stagedRelease)
    #expect(tagger.selectedID == -1)

    // Another release would leave the tags of one the service didn't download.
    var failure: String?
    tagger.failed = { message, _ in failure = message }
    await tagger.choose(99, for: -1)
    #expect(failure == "The release couldn't be chosen")
    #expect(tagger.albums.first?.match.releaseID == stagedRelease)
}

@MainActor @Test func applyWritesThroughTheStagedWriterAndReportsItClean() async throws {
    let files = StagedFiles(bonusAlbum)
    var verdicts: [AutoTagRun.Verdict] = []
    let tagger = await stagedTagger(files) { verdicts.append($0) }
    var mainWrites = 0
    tagger.write = { _, _ in mainWrites += 1 }
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
    var verdicts: [AutoTagRun.Verdict] = []
    let tagger = await stagedTagger(files) { verdicts.append($0) }
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
    var verdicts: [AutoTagRun.Verdict] = []
    let tagger = await stagedTagger(files, writing: .ignores) { verdicts.append($0) }
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
    var verdicts: [AutoTagRun.Verdict] = []
    let tagger = await stagedTagger(files, writing: .fails) { verdicts.append($0) }
    tagger.analyze()
    await tagger.finished()
    tagger.apply(try #require(await tagger.plan([-1])))
    try await eventually { tagger.status.contains("not fully written") }
    #expect(verdicts.isEmpty)
    #expect(tagger.applicable(.likely).map(\.id) == [-1])
}
