import Discogs
import Foundation
import Library
import Metadata
import Settings
import TagWriter

extension TaggerModel {
    /// What a tagger opened on a staged job does instead of reading the index and writing
    /// through the library's writer (ADR 0146): it reads the job's files in the staging
    /// folder, matches them with the job's release only, and writes through `StagedWriter`,
    /// whose journal is its own and which no watcher hears.
    struct StagedEffects: Sendable {
        /// The job's files read as AutoTag reads them, each with its synthetic id: the album
        /// the matcher compares, the files, and why any couldn't be read.
        var read:
            @Sendable () async -> (album: DiscogsAlbum, files: [AlbumFile], problems: [String])
        /// Matches the album with the release by id.
        var match: @Sendable (DiscogsAlbum, Int) async throws -> AlbumMatch
        var summaries: @Sendable ([Int]) async throws -> [ReleaseSummary]
        var release: @Sendable (Int) async throws -> ReleaseDetail?
        var checkCatalog: @Sendable () async -> CatalogState
        /// `StagedWriter.write(_:)`, which refuses a path outside the staging folder.
        var write: @Sendable ([(path: String, edit: TagEdit)]) async throws -> TagWriteReport
    }

    /// A staged job the tagger is open on, and where its verdict goes.
    struct Staged {
        var job: StagedJob
        var effects: StagedEffects
        /// Hears the verdict once Apply has written and the files read back.
        var resolved: (AutoTagRun.Verdict) -> Void
    }

    /// The tagger for one staged job with a discrepancy, so the owner can resolve it: its
    /// release is chosen and can't be changed, and Apply writes through `effects`, never the
    /// library's writer. `resolved` hears clean once the files read back with nothing left to
    /// change but what the owner unticked, and is for the coordinator to report.
    convenience init(
        stagedJob job: StagedJob, effects staged: StagedEffects, mapping: DiscogsMapping,
        savedMappings: [NamedDiscogsMapping], choices: TaggerChoices,
        resolved: @escaping (AutoTagRun.Verdict) -> Void
    ) {
        let release = job.releaseID
        self.init(
            effects: Effects(
                albums: {
                    let read = await staged.read()
                    guard read.problems.isEmpty else { throw StagedReadFailure(read.problems) }
                    return [read.album]
                },
                reviews: {
                    [StagedAlbum.albumID: .chosen(releaseID: release)]
                },
                review: { review, _ in
                    guard review == .chosen(releaseID: release) else {
                        throw StagedReleaseFixed(release: release)
                    }
                },
                // One album: there's no progress to show.
                match: { albums, _, _, _, _ in
                    var matches: [AlbumMatch] = []
                    for album in albums { matches.append(try await staged.match(album, release)) }
                    return matches
                },
                summaries: staged.summaries,
                release: staged.release,
                read: { ids, progress in
                    let read = await staged.read()
                    let wanted = Set(ids)
                    let files = read.files.filter { wanted.contains($0.id) }
                    progress(files.count)
                    return (files, read.problems)
                },
                checkCatalog: staged.checkCatalog,
                unfinishedImport: { nil },
                importCatalog: { _, _, _ in throw StagedImportRefused() }),
            mapping: mapping, savedMappings: savedMappings, choices: choices,
            staged: Staged(job: job, effects: staged, resolved: resolved))
    }

    var isStaged: Bool { staged != nil }

    /// Writes the plan through the staged writer, then reads the files back: clean when the
    /// mapping would change nothing but what the owner unticked, else a discrepancy. A write
    /// that fails reports nothing, and Apply can try again.
    func applyStaged(_ plan: ApplyPlan, _ staged: Staged) {
        let read = staged.effects.read
        let write = staged.effects.write
        Task {
            let report: TagWriteReport
            do {
                report = try await write(plan.files)
            } catch {
                reopen(plan, unwritten: Set(plan.files.map(\.path)))
                failed("The staged files weren't written", ["\(error)"])
                return
            }
            let unwritten = Set(report.failures.map(\.path) + report.notWritten)
            guard unwritten.isEmpty else {
                reopen(plan, unwritten: unwritten)
                return
            }
            let back = await read()
            guard back.problems.isEmpty else {
                staged.resolved(.error(back.problems))
                return
            }
            var left = 0
            for album in albums where plan.albumIDs.contains(album.id) {
                left += changeSet(back.files, album).files.flatMap(\.changes).count {
                    !album.excluded.contains($0.id)
                }
            }
            staged.resolved(StagedWriter.verdict(readingBack: left))
        }
    }
}

/// The staged files that couldn't be read, each with why.
struct StagedReadFailure: Error, CustomStringConvertible {
    var problems: [String]

    init(_ problems: [String]) { self.problems = problems }

    var description: String { problems.joined(separator: "; ") }
}

/// A staged job is tagged from the release it was downloaded for, and no other.
struct StagedReleaseFixed: Error, CustomStringConvertible {
    var release: Int

    var description: String {
        "this album was downloaded for release \(release); reject it in Downloads to queue another"
    }
}

/// The catalog is imported from the library's Discogs Tagger, not a staged job's.
struct StagedImportRefused: Error, CustomStringConvertible {
    var description: String { "import the catalog from the library's Discogs Tagger" }
}
