import Foundation
import Metadata
import Recommender
import Settings
import TagWriter

/// What AutoTag found for a staged job (ADR 0146): whether its tags can be written unasked,
/// and the edits that would be.
package struct AutoTagRun: Sendable {
    package enum Verdict: Equatable, Sendable {
        /// Tier Exact, every file mapped as the service mapped it, in the format it said, and
        /// every file writable: `edits` can be written without asking.
        case clean
        /// Something to resolve in the tagger first, each reason a line for the window.
        case discrepancy([String])
        /// A file that can't be read or isn't what was staged, or a release the catalog lacks.
        case error([String])
    }

    package var verdict: Verdict
    package var staged: StagedAlbum
    /// Nil when a file couldn't be read.
    var match: AlbumMatch?
    /// The fixed overwrite mapping's changes for the match, whatever the verdict, for the
    /// tagger to show.
    var changes: AlbumChangeSet?
    /// What `StagedWriter` writes: the changes' edits when the run is clean, else none.
    var edits: [(path: String, edit: TagEdit)]
    /// For a discrepancy, whether another peer's copy might be clean: a reason is about these
    /// files (their count, a file that fits no track or a track with none, a title or a length
    /// that differs, the wrong codec), and none would come back with every copy (a file the
    /// writer can't tag, a format AutoTag can't check). A match only below exact, or a position
    /// the service gave otherwise, doesn't say the copy is wrong (ADR 0211). False when the
    /// files fit another release (`fits`): another copy would only replace them.
    package var anotherCopyMightFix = false
    /// For a discrepancy in how the files fit their release's tracklist, the first other
    /// release the matcher found that they fit with no reason, which a reason names
    /// (ADR 0224); nil for none.
    package var fits: ReleaseSummary? = nil
}

/// Matches `job`'s staged files under `stagingRoot` against its release in the catalog at
/// `catalog`, and works out the edits `mapping` makes with every field replaced (ADR 0146).
/// Writes nothing. Blocks on the file reads, so call it off the main actor.
package func autoTag(
    _ job: StagedJob, stagingRoot: String, catalogAt catalog: URL, mapping: DiscogsMapping
) async throws -> AutoTagRun {
    let staged = await blockingFileWork { StagedAlbum(job, stagingRoot: stagingRoot) }
    guard staged.problems.isEmpty else {
        return AutoTagRun(
            verdict: .error(staged.problems), staged: staged, match: nil, changes: nil, edits: [])
    }
    let matches = try await matchAlbums(
        [staged.album], catalogAt: catalog, choosing: [StagedAlbum.albumID: job.releaseID],
        skippingVideo: false, progress: { _ in })
    // A release the catalog lacks isn't chosen, and the matcher then picks the best it finds.
    guard let match = matches.first, match.releaseID == job.releaseID else {
        let problem = ReleaseSnapshot.Problem.notInCatalog(releaseID: job.releaseID)
        return AutoTagRun(
            verdict: .error([problem.description]), staged: staged, match: nil, changes: nil,
            edits: [])
    }
    // The tracks as the snapshot named them, which the service's positions are.
    guard let positions = ReleaseSnapshot.positions(match.tracks) else {
        let problem = ReleaseSnapshot.Problem.positions(releaseID: job.releaseID)
        return AutoTagRun(
            verdict: .error([problem.description]), staged: staged, match: match, changes: nil,
            edits: [])
    }
    let changes = changeSet(for: staged.files, match: match, mapping: mapping.overwriting())
    let checked = check(job, staged, match, positions: positions, changes: changes)
    var reasons = checked.reasons
    // Files that don't fit their release's tracklist may fit another's; only the releases the
    // matcher found are tried (ADR 0224). No release fixes a wrong codec, or a reason every
    // copy would have.
    var fits: ReleaseSummary?
    if !reasons.isEmpty, checked.tracklist, !checked.codec, !checked.withEveryCopy {
        fits = try await fittingRelease(job, staged, match, catalogAt: catalog, mapping: mapping)
        if let fits { reasons.append("release \(fits.id) (\(fits.edition)) fits every file") }
    }

    let edits: [(path: String, edit: TagEdit)]
    do throws(TagValueError) {
        edits = try changes.edits()
    } catch {
        return AutoTagRun(
            verdict: .error([error.description]), staged: staged, match: match, changes: changes,
            edits: [])
    }
    return AutoTagRun(
        verdict: reasons.isEmpty ? .clean : .discrepancy(reasons), staged: staged, match: match,
        changes: changes, edits: reasons.isEmpty ? edits : [],
        anotherCopyMightFix: fits == nil && (checked.tracklist || checked.codec)
            && !checked.withEveryCopy,
        fits: fits)
}

/// What the checks of one match found: the reasons, and which kinds they are.
private struct Checks {
    var reasons: [String] = []
    /// A reason is about how the files fit the tracklist: their count, a file that fits no
    /// track or a track with none, a title or a length that differs.
    var tracklist = false
    /// A file isn't the codec the service said.
    var codec = false
    /// A reason would come back with every copy: a file the writer can't tag, or a format
    /// AutoTag can't check.
    var withEveryCopy = false
}

/// Why `staged`'s files, matched as `match` with its tracks at `positions`, can't be written
/// as `changes` unasked; no reason for a clean match. The service's positions are checked only
/// for the release the job was queued for, which they were given for (ADR 0224).
private func check(
    _ job: StagedJob, _ staged: StagedAlbum, _ match: AlbumMatch, positions: [String],
    changes: AlbumChangeSet
) -> Checks {
    let name = { (id: Int64?) in id.flatMap { staged.staged[$0]?.name } ?? "a file" }
    var checks = Checks()
    if staged.files.count != match.releaseTrackCount {
        checks.reasons.append("\(staged.files.count) files, release has \(match.releaseTrackCount)")
        checks.tracklist = true
    }
    for row in match.comparison(of: staged.album) {
        guard let index = row.track else {
            checks.reasons.append("\(name(row.fileID)) fits no track")
            checks.tracklist = true
            continue
        }
        let track = positions[index]
        switch row.state {
        case .matched: break
        case .missing:
            checks.reasons.append("track \(track) has no file")
            checks.tracklist = true
        case .different:
            if let title = row.releaseTitle,
                TitleSimilarity([row.fileTitle]).similarities(to: title)[0]
                    < MatchThreshold.sameTitle
            {
                checks.reasons.append(
                    "track \(track) is titled \(row.fileTitle ?? "nothing"), not \(title)")
                checks.tracklist = true
            }
            if let expected = row.releaseSeconds, let seconds = row.fileSeconds,
                !ReleaseScore.agrees(seconds, expected)
            {
                checks.reasons.append(
                    "track \(track) is \(Int(abs(seconds - Double(expected)).rounded())) s off")
                checks.tracklist = true
            }
        }
    }
    for file in staged.files {
        let player = match.mapping[file.id].map { positions[$0] }
        let service = staged.staged[file.id]?.position
        if job.releaseID == job.queuedReleaseID, let player, player != service {
            let said = service.map { "the service said \($0)" } ?? "the service left it out"
            checks.reasons.append("\(name(file.id)) is track \(player), \(said)")
        }
        if let expected = codec(job.format), file.metadata.audio.codec != expected {
            checks.reasons.append(
                "\(name(file.id)) is \(codecName(file.metadata.audio.codec)), not \(job.format.rawValue.uppercased())"
            )
            checks.codec = true
        } else if codec(job.format) == nil {
            checks.reasons.append(
                "\(name(file.id)) is \(job.format.rawValue), which can't be checked")
            checks.withEveryCopy = true
        }
    }
    for file in changes.files {
        if let unwritable = file.unwritable {
            checks.reasons.append("\(name(file.fileID)): \(unwritable)")
            checks.withEveryCopy = true
        }
    }
    if checks.reasons.isEmpty, match.tier != .exact {
        checks.reasons.append("the match is \(match.tier.rawValue), not exact")
    }
    return checks
}

/// The first of `match`'s other releases, best first, that `staged`'s files fit with no
/// reason, as they would for a job queued for it; nil for none. Only a release whose score
/// fits the tracklist and the lengths can be exact, so only those are read again.
private func fittingRelease(
    _ job: StagedJob, _ staged: StagedAlbum, _ match: AlbumMatch, catalogAt catalog: URL,
    mapping: DiscogsMapping
) async throws -> ReleaseSummary? {
    for candidate in match.candidates
    where candidate.score.fitsTracklist && candidate.score.durationsAgree {
        let other = try await chooseRelease(
            candidate.releaseID, for: staged.album, after: match, catalogAt: catalog,
            source: .catalog, api: nil)
        guard let release = other.release, let positions = ReleaseSnapshot.positions(other.tracks)
        else { continue }
        var queuedAsIt = job
        queuedAsIt.releaseID = release.id
        let changes = changeSet(for: staged.files, match: other, mapping: mapping.overwriting())
        let checked = check(queuedAsIt, staged, other, positions: positions, changes: changes)
        if checked.reasons.isEmpty { return release.summary }
    }
    return nil
}

/// The codec a file of the service's `format` holds, as the reader names it; nil for a format
/// the reader can't open. The service takes every `.m4a` for ALAC, so an AAC one shows here.
private func codec(_ format: DownloadJob.Candidate.Format) -> TrackAudio.Codec? {
    switch format {
    case .flac: .flac
    case .alac: .alac
    case .mp3: .mp3
    case .wav: .pcm
    case .ogg, .opus, .ape, .wv: nil
    }
}

/// "AAC", "FLAC", "PCM": a codec as a reason names it.
private func codecName(_ codec: TrackAudio.Codec) -> String { codec.rawValue.uppercased() }
