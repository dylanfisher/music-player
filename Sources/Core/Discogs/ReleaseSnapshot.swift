import Foundation
import Recommender
import Settings

extension ReleaseSnapshot {
    /// Why a release can't be queued for download.
    package enum Problem: Error, Equatable, CustomStringConvertible {
        /// The Mac's catalog doesn't have it, so there's no tracklist to send; the service has
        /// no catalog of its own.
        case notInCatalog(releaseID: Int)
        /// No artist or no title, which the service needs to search by.
        case unnamed(releaseID: Int)
        /// A tracklist with a track that has no position, or two with the same one, so the
        /// service couldn't say which file is which track.
        case positions(releaseID: Int)
        /// A tracklist of none or more than `ReleaseSnapshot.trackCap` tracks.
        case trackCount(releaseID: Int, Int)

        package var description: String {
            switch self {
            case .notInCatalog(let id): "release \(id) is not in the local catalog"
            case .unnamed(let id): "release \(id) has no artist or no title"
            case .positions(let id):
                "release \(id) has tracks without a position, or two with the same one"
            case .trackCount(let id, let count):
                "release \(id) has \(count) tracks; a download takes 1 to"
                    + " \(ReleaseSnapshot.trackCap)"
            }
        }
    }

    /// The snapshot of the release `releaseID` in the catalog at `catalog`, for a new job.
    /// Throws `Problem.notInCatalog` when the catalog doesn't have it, so a pasted release is
    /// refused when it's queued, never after a download. Reads the catalog on this thread.
    package static func queueable(releaseID: Int, catalogAt catalog: URL) throws -> ReleaseSnapshot {
        guard let release = try Catalog(at: catalog).release(id: releaseID) else {
            throw Problem.notInCatalog(releaseID: releaseID)
        }
        return try ReleaseSnapshot(release)
    }

    /// `release` as the service takes it: its artist with Discogs's join words and no `(2)`,
    /// its title, its year, and each of `ReleaseTracklist.flattenings`, the one with index
    /// tracks as their parts first.
    init(_ release: CatalogRelease) throws(Problem) {
        let artist =
            MappedValue.artists(release.artists).text(
                DiscogsFieldFormat(suffixes: .drop), tagFormat: .vorbis) ?? ""
        guard !artist.isEmpty, !release.title.isEmpty else {
            throw .unnamed(releaseID: release.id)
        }
        var tracklists: [[Track]] = []
        for flattening in ReleaseTracklist.flattenings(release.tracks) {
            guard (1...Self.trackCap).contains(flattening.count) else {
                throw .trackCount(releaseID: release.id, flattening.count)
            }
            guard let positions = Self.positions(flattening) else {
                throw .positions(releaseID: release.id)
            }
            tracklists.append(
                zip(flattening, positions).map { track, position in
                    Track(
                        position: position, title: track.title,
                        seconds: ReleaseTracklist.seconds(track))
                })
        }
        self.init(
            releaseID: release.id, artist: artist, title: release.title,
            year: release.released.flatMap { Int($0.prefix(4)) }.flatMap { $0 > 0 ? $0 : nil },
            tracklists: tracklists)
    }

    /// Each track's position as the snapshot sends it, which the service reports each file's
    /// track by, so the player's mapping has to name tracks the same way: the track's own; for
    /// an index track without one, its parts' joined with "+"; and for a list where no track
    /// has one, its place from 1. Nil when one is still missing or two are the same.
    static func positions(_ tracks: [CatalogTrack]) -> [String]? {
        func own(_ track: CatalogTrack) -> String? {
            track.position.flatMap { $0.isEmpty ? nil : $0 }
        }
        let positions: [String?]
        if tracks.allSatisfy({ own($0) == nil && $0.subTracks.allSatisfy { own($0) == nil } }) {
            positions = tracks.indices.map { String($0 + 1) }
        } else {
            positions = tracks.map { track in
                if let position = own(track) { return position }
                let parts = track.subTracks.map(own)
                guard track.kind == .index, !parts.isEmpty, !parts.contains(nil) else {
                    return nil
                }
                return parts.compactMap { $0 }.joined(separator: "+")
            }
        }
        let found = positions.compactMap { $0 }
        return found.count == tracks.count && Set(found).count == found.count ? found : nil
    }
}
