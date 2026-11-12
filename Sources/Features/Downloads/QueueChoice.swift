import Commands
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

    /// The upgrade candidates, as the Upgrades sheet lists them: each with the quality it has,
    /// and those whose release is in `never` marked Never Upgrade, which only the automatic
    /// upgrades leave out.
    static func upgrades(_ candidates: [UpgradeCandidate], never: Set<Int> = [])
        -> [QueueChoice]
    {
        candidates.map { candidate in
            QueueChoice(
                title: albumTitle(candidate.artist, candidate.title),
                detail: "\(candidate.quality), release \(candidate.releaseID)"
                    + (never.contains(candidate.releaseID) ? ", \(neverUpgradeTitle)" : ""),
                releaseID: candidate.releaseID,
                upgrade: DownloadJob.Upgrade(
                    currentQuality: candidate.quality, oldPaths: candidate.sharePaths),
                refusal: nil)
        }
    }

    /// The Never Upgrade mark, as the Upgrades sheet's button and its rows name it: the track
    /// menu's command.
    static let neverUpgradeTitle = AppCommands.title(of: .toggleNeverUpgrade)

    /// The candidates set aside after their misses, as the Not Found sheet lists them, with
    /// how many there were; queuing one again clears them.
    static func setAside(_ candidates: [UpgradeCandidate], misses: [Int: UpgradeMiss])
        -> [QueueChoice]
    {
        candidates.compactMap { candidate in
            guard let miss = misses[candidate.releaseID], miss.isSetAside else { return nil }
            return QueueChoice(
                title: albumTitle(candidate.artist, candidate.title),
                detail: "\(miss.misses) searches found no clean copy, release"
                    + " \(candidate.releaseID)",
                releaseID: candidate.releaseID, upgrade: nil, refusal: nil)
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
                let release =
                    releases.count == 1 ? releases.first.flatMap { $0.flatMap(Int.init) } : nil
                return QueueChoice(
                    title: albumTitle(album.artist, album.title),
                    detail: release.map(DownloadRow.releaseName) ?? "",
                    releaseID: release, upgrade: nil,
                    refusal: release == nil
                        ? "Tag first: its tracks don't all carry one Discogs release id" : nil)
            }
    }

    /// The Recommendations window's albums (phase 86, ADR 0205), each downloaded as the release
    /// that stands for it, a master's main release; one without a release says so.
    static func recommended(_ albums: [RecommendationPage.Album]) -> [QueueChoice] {
        albums.map { album in
            let artists = album.artists.compactMap(\.name).joined(separator: ", ")
            return QueueChoice(
                title: albumTitle(artists.isEmpty ? nil : artists, album.title),
                detail: album.releaseID.map(DownloadRow.releaseName) ?? "",
                releaseID: album.releaseID, upgrade: nil,
                refusal: album.releaseID == nil
                    ? "The service has no release for this master in its catalog" : nil)
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
}
