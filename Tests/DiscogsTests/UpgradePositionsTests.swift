import Foundation
import Testing

@testable import Discogs
@testable import Library
@testable import Recommender

/// The library's lossy copy of the staged release, its tracks as `titles` give them.
private func oldAlbum(_ titles: [String]) -> DiscogsAlbum {
    DiscogsAlbum(
        id: 5, title: "Made-Up Album", artist: "Made-Up Artist",
        tracks: titles.enumerated().map { offset, title in
            DiscogsAlbum.Track(
                fileID: Int64(11 + offset), title: title, seconds: 0, trackNumber: offset + 1,
                releaseID: "4242")
        })
}

@Test func anOldAlbumsTracksTakeTheReleasesPositions() async throws {
    let setup = try StagedSetup()
    let positions = try await upgradePositions(
        of: oldAlbum(["First Song", "Second Song", "Third Song"]), release: 4242,
        catalogAt: setup.dumps.catalog)
    #expect(positions == [11: "1", 12: "2", 13: "3"])
}

@Test func anOldTrackTheReleaseLacksHasNoPosition() async throws {
    let setup = try StagedSetup()
    let positions = try await upgradePositions(
        of: oldAlbum(["First Song", "Second Song", "Third Song", "Bonus Remix"]), release: 4242,
        catalogAt: setup.dumps.catalog)
    #expect(positions[14] == nil)
    #expect(positions[11] == "1")
}

@Test func aReleaseNotInTheCatalogIsRefused() async throws {
    let setup = try StagedSetup()
    await #expect(throws: ReleaseSnapshot.Problem.notInCatalog(releaseID: 99)) {
        try await upgradePositions(
            of: oldAlbum(["First Song"]), release: 99, catalogAt: setup.dumps.catalog)
    }
}
