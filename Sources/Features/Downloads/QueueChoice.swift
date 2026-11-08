import Foundation
import Library
import Recommender

/// One album a queue sheet offers: a library album with its release, an upgrade candidate, or
/// a pasted release. One that can't be queued says why and has no box.
struct QueueChoice: Equatable, Sendable {
    var title: String
    var detail: String
    var releaseID: Int?
    /// For an upgrade, what it replaces.
    var upgrade: DownloadJob.Upgrade?
    /// Why it can't be queued; nil when it can.
    var refusal: String?

    /// The upgrade candidates, as the Upgrades sheet lists them: each with the quality it has.
    static func upgrades(_ candidates: [UpgradeCandidate]) -> [QueueChoice] {
        candidates.map { candidate in
            QueueChoice(
                title: albumTitle(candidate.artist, candidate.title),
                detail: "\(candidate.quality), release \(candidate.releaseID)",
                releaseID: candidate.releaseID,
                upgrade: DownloadJob.Upgrade(
                    currentQuality: candidate.quality, oldPaths: candidate.sharePaths),
                refusal: nil)
        }
    }

    /// The albums of the selected tracks `selected`, each once, in the order of `albums`: one
    /// whose every track has the same numeric release id can be queued, any other says to tag
    /// it first, since a download is always of one release.
    static func selection(_ selected: [Int64], albums: [DiscogsAlbum]) -> [QueueChoice] {
        let wanted = Set(selected)
        return albums.filter { album in album.tracks.contains { wanted.contains($0.fileID) } }
            .map { album in
                let releases = Set(album.tracks.map(\.releaseID))
                let release = releases.count == 1 ? releases.first.flatMap { $0.flatMap(Int.init) } : nil
                return QueueChoice(
                    title: albumTitle(album.artist, album.title),
                    detail: release.map(DownloadRow.releaseName) ?? "",
                    releaseID: release, upgrade: nil,
                    refusal: release == nil
                        ? "Tag first: its tracks don't all carry one Discogs release id" : nil)
            }
    }

    /// The order to create the job with: an upgrade's takes only a lossless policy, so nil
    /// for a lossy one.
    func order(_ policy: FormatPolicy) -> JobOrder? {
        guard let upgrade else { return .manual(policy) }
        return JobOrder.LosslessPolicy.allCases.first { $0.formatPolicy == policy }.map {
            .upgrade(upgrade, $0)
        }
    }

    /// "Artist - Title", or the title alone for a compilation with no artist.
    static func albumTitle(_ artist: String?, _ title: String) -> String {
        artist.map { "\($0) - \(title)" } ?? title
    }

    /// The release id in what the owner pasted: a number, or a Discogs release URL
    /// (`…/release/<id>`, with or without a slug after the id). Nil for anything else.
    static func pastedReleaseID(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int(trimmed.hasPrefix("r") ? String(trimmed.dropFirst()) : trimmed) {
            return id > 0 ? id : nil
        }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(),
            host == "discogs.com" || host.hasSuffix(".discogs.com")
        else { return nil }
        let parts = url.pathComponents
        guard let at = parts.firstIndex(of: "release"), at + 1 < parts.count else { return nil }
        let digits = parts[at + 1].prefix(while: \.isNumber)
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }
}
