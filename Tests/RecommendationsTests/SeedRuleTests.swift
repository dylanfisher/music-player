import Testing

@testable import Recommendations
@testable import Recommender

private let tagged: SeedAlbum = ("Made-Up Album", "Made-Up Artist", 4242)
private let untagged: SeedAlbum = ("Untagged", "Made-Up Artist", nil)
private let other: SeedAlbum = ("Other Album", "Gus Other", 17)

@Test func anAlbumSeedIsTheSelectionsOneAlbumWithItsRelease() {
    #expect(
        seed(.album, of: [tagged]) == .success(.album(releaseID: 4242, title: "Made-Up Album")))
    for albums in [[], [untagged], [tagged, other]] {
        guard case .failure(let problem) = seed(.album, of: albums) else {
            Issue.record("\(albums) gave a seed")
            continue
        }
        #expect(problem.text.hasPrefix("Recommendations for Album: "))
    }
}

@Test func anArtistSeedIsTheSelectionsOneAlbumArtist() {
    #expect(seed(.artist, of: [tagged, untagged]) == .success(.artist("Made-Up Artist")))
    #expect(
        seed(.artist, of: [tagged, other])
            == .failure(
                SeedProblem(
                    text: "Recommendations for Artist: the selection holds albums by 2 artists;"
                        + " select one")))
}
