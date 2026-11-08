import Foundation
import Library
import Recommender

/// The release position of each of `album`'s tracks, by file id, as the matcher places them on
/// the release `release` in the catalog at `catalog`: what an upgrade's old files map to its new
/// ones through (ADR 0147). A track the match leaves out has none. Reads the catalog off the
/// calling thread.
package func upgradePositions(of album: DiscogsAlbum, release: Int, catalogAt catalog: URL)
    async throws -> [Int64: String]
{
    let matches = try await matchAlbums(
        [album], catalogAt: catalog, choosing: [album.id: release], skippingVideo: false,
        progress: { _ in })
    // A chosen release the catalog lacks leaves the matcher to pick its own.
    guard let match = matches.first, match.releaseID == release else {
        throw ReleaseSnapshot.Problem.notInCatalog(releaseID: release)
    }
    // Named as the snapshot names them, which the new files' positions are.
    guard let positions = ReleaseSnapshot.positions(match.tracks) else {
        throw ReleaseSnapshot.Problem.positions(releaseID: release)
    }
    return match.mapping.mapValues { positions[$0] }
}
