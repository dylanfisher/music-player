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
        /// Look Up Release's search, in the local catalog only, where every staged match is
        /// made (ADR 0178).
        var lookUp: @Sendable (ReleaseQuery, DiscogsAlbum) async throws -> ReleaseLookup
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
        /// Hears the verdict once Apply has written and the files read back, with the release
        /// the files were written as; a nil verdict when only some files were written, whose
        /// release is still to be recorded but which has nothing to report.
        var resolved: (AutoTagRun.Verdict?, _ releaseID: Int) -> Void
    }

    /// The tagger for one staged job with a discrepancy, so the owner can resolve it: it opens
    /// on the job's release, and Other Releases… and Look Up… can choose another in the local
    /// catalog (ADR 0178). Apply writes through `effects`, never the library's writer.
    /// `resolved` hears clean once the files read back with nothing left to change but what
    /// the owner unticked, with the release written, and is for the coordinator to report.
    convenience init(
        stagedJob job: StagedJob, effects staged: StagedEffects, mapping: DiscogsMapping,
        savedMappings: [NamedDiscogsMapping], choices: TaggerChoices,
        resolved: @escaping (AutoTagRun.Verdict?, _ releaseID: Int) -> Void
    ) {
        let chosen = StagedChoice(job.releaseID)
        // A staged write is the fixed mapping's tags only, with no cover (ADR 0146).
        var choices = choices
        choices.artwork = .off
        self.init(
            effects: Effects(
                albums: {
                    let read = await staged.read()
                    guard read.problems.isEmpty else { throw StagedReadFailure(read.problems) }
                    return [read.album]
                },
                reviews: {
                    [StagedAlbum.albumID: .chosen(releaseID: chosen.release)]
                },
                // Kept for the session only: what lasts is the release Apply writes.
                review: { review, _ in
                    guard case .chosen(let release) = review else { throw StagedRejectRefused() }
                    chosen.release = release
                },
                // One album: there's no progress to show.
                match: { albums, _, _, _, _ in
                    var matches: [AlbumMatch] = []
                    for album in albums {
                        matches.append(try await staged.match(album, chosen.release))
                    }
                    return matches
                },
                choose: { album, _, release, _ in try await staged.match(album, release) },
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
                importCatalog: { _, _, _ in throw StagedImportRefused() },
                lookUp: staged.lookUp),
            mapping: mapping, savedMappings: savedMappings, choices: choices,
            staged: Staged(job: job, effects: staged, resolved: resolved))
    }

    var isStaged: Bool { staged != nil }

    /// Why Analyze can't start, for a staged job's tagger that opens unable to.
    var catalogProblem: String {
        switch catalog {
        case .missing: "there's no Discogs catalog on this Mac"
        case .unusable(let why): "the Discogs catalog can't be used: \(why)"
        case .checking, .ready: "the tagger is busy"
        }
    }

    /// Writes the plan through the staged writer, then reads the files back: clean when the
    /// mapping would change nothing but what the owner unticked, else a discrepancy. A write
    /// that fails reports nothing, and Apply can try again; one that wrote some of the files
    /// passes on only the release they now carry.
    /// `wrote` hears that the write has finished, before the read back.
    func applyStaged(_ plan: ApplyPlan, _ staged: Staged, wrote: @escaping () -> Void) {
        let read = staged.effects.read
        let write = staged.effects.write
        // The release the plan was made with, which the files are written as. Taken now: the
        // window doesn't lock while the write runs, so the owner can choose another meanwhile.
        let release = plan.albumIDs.lazy.compactMap { id in
            self.albums.first { $0.id == id }?.match.releaseID
        }.first
        Task {
            guard let release else {
                wrote()
                reopen(plan, unwritten: Set(plan.files.map(\.path)))
                failed("The staged files weren't written", ["the album has no release to write"])
                return
            }
            let report: TagWriteReport
            do {
                report = try await write(plan.files)
                wrote()
            } catch {
                wrote()
                reopen(plan, unwritten: Set(plan.files.map(\.path)))
                failed("The staged files weren't written", ["\(error)"])
                return
            }
            let unwritten = Set(report.failures.map(\.path) + report.notWritten)
            guard unwritten.isEmpty else {
                // The files written carry the release now, whatever happens to the rest.
                if unwritten.count < plan.files.count { staged.resolved(nil, release) }
                reopen(plan, unwritten: unwritten)
                return
            }
            let back = await read()
            guard back.problems.isEmpty else {
                staged.resolved(.error(back.problems), release)
                return
            }
            var left = 0
            for album in albums where plan.albumIDs.contains(album.id) {
                left += changeSet(back.files, album).files.flatMap(\.changes).count {
                    !album.excluded.contains($0.id)
                }
            }
            staged.resolved(StagedWriter.verdict(readingBack: left), release)
        }
    }
}

/// The staged files that couldn't be read, each with why.
struct StagedReadFailure: Error, CustomStringConvertible {
    var problems: [String]

    init(_ problems: [String]) { self.problems = problems }

    var description: String { problems.joined(separator: "; ") }
}

/// A staged job is rejected in Downloads, where the service deletes its staged folder.
struct StagedRejectRefused: Error, CustomStringConvertible {
    var description: String {
        "a download is rejected in Downloads, which deletes its staged folder"
    }
}

/// The release a staged job's tagger matches, which Other Releases… and Look Up… change.
private final class StagedChoice: @unchecked Sendable {
    // `chosen` is guarded by `lock`.
    private let lock = NSLock()
    private var chosen: Int

    init(_ release: Int) { chosen = release }

    var release: Int {
        get { lock.withLock { chosen } }
        set { lock.withLock { chosen = newValue } }
    }
}

/// The catalog is imported from the library's Discogs Tagger, not a staged job's.
struct StagedImportRefused: Error, CustomStringConvertible {
    var description: String { "import the catalog from the library's Discogs Tagger" }
}
