import Recommender

/// A row of the Recommendations window: an album, or on the Artists view an artist with its
/// best album, whose columns the row shows beside the artist's.
struct RecommendationRow: Equatable {
    var album: RecommendationPage.Album
    var artist: RecommendationPage.Artist?

    /// The rows of `page`, whichever view it is of.
    static func rows(of page: RecommendationPage) -> [RecommendationRow] {
        (page.albums ?? []).map { RecommendationRow(album: $0) }
            + (page.artists ?? []).map { RecommendationRow(album: $0.best, artist: $0) }
    }
}
