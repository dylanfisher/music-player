import Foundation
import Metadata
import Recommender
import Settings
import TagWriter

/// What AutoTag found for a staged job (ADR 0138): whether its tags can be written unasked,
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
}

/// Matches `job`'s staged files under `stagingRoot` against its release in the catalog at
/// `catalog`, and works out the edits `mapping` makes with every field replaced (ADR 0138).
/// Writes nothing. Blocks on the file reads, so call it off the main actor.
package func autoTag(
    _ job: StagedJob, stagingRoot: String, catalogAt catalog: URL, mapping: DiscogsMapping
) async throws -> AutoTagRun {
    let staged = StagedAlbum(job, stagingRoot: stagingRoot)
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
    let name = { (id: Int64?) in id.flatMap { staged.staged[$0]?.name } ?? "a file" }

    var reasons: [String] = []
    if staged.files.count != match.releaseTrackCount {
        reasons.append("\(staged.files.count) files, release has \(match.releaseTrackCount)")
    }
    for row in match.comparison(of: staged.album) {
        guard let index = row.track else {
            reasons.append("\(name(row.fileID)) fits no track")
            continue
        }
        let track = positions[index]
        switch row.state {
        case .matched: break
        case .missing: reasons.append("track \(track) has no file")
        case .different:
            if let title = row.releaseTitle,
                TitleSimilarity([row.fileTitle]).similarities(to: title)[0]
                    < MatchThreshold.sameTitle
            {
                reasons.append(
                    "track \(track) is titled \(row.fileTitle ?? "nothing"), not \(title)")
            }
            if let expected = row.releaseSeconds, let seconds = row.fileSeconds,
                !ReleaseScore.agrees(seconds, expected)
            {
                reasons.append(
                    "track \(track) is \(Int(abs(seconds - Double(expected)).rounded())) s off")
            }
        }
    }
    for file in staged.files {
        let player = match.mapping[file.id].map { positions[$0] }
        let service = staged.staged[file.id]?.position
        if let player, player != service {
            let said = service.map { "the service said \($0)" } ?? "the service left it out"
            reasons.append("\(name(file.id)) is track \(player), \(said)")
        }
        if let expected = codec(job.format), file.metadata.audio.codec != expected {
            reasons.append(
                "\(name(file.id)) is \(codecName(file.metadata.audio.codec)), not \(job.format.rawValue.uppercased())"
            )
        } else if codec(job.format) == nil {
            reasons.append("\(name(file.id)) is \(job.format.rawValue), which can't be checked")
        }
    }
    for file in changes.files {
        if let unwritable = file.unwritable {
            reasons.append("\(name(file.fileID)): \(unwritable)")
        }
    }
    if reasons.isEmpty, match.tier != .exact {
        reasons.append("the match is \(match.tier.rawValue), not exact")
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
        changes: changes, edits: reasons.isEmpty ? edits : [])
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
