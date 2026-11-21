import Recommender

/// The Discogs artists Show Discography offers for a release or master this catalog has
/// (ADR 0217).
extension Catalog {
    /// The main artists of release `id` that Discogs links, in its order; nil when this
    /// catalog doesn't have the release.
    package func discographyArtists(release id: Int) throws -> [RecommendationPage.Named]? {
        try release(id: id).map { discographyArtists($0.artists) }
    }

    /// The main artists of master `id`, as for a release.
    package func discographyArtists(master id: Int) throws -> [RecommendationPage.Named]? {
        try master(id: id).map { discographyArtists($0.artists) }
    }

    /// Artist `id`'s name without its `(2)` suffix; nil when this catalog doesn't have it.
    package func artistName(_ id: Int) throws -> String? {
        try artist(id: id).map { CatalogKey.withoutNumberSuffix($0.name) }
    }

    private func discographyArtists(_ credits: [CatalogArtistCredit])
        -> [RecommendationPage.Named]
    {
        credits.compactMap { credit in
            credit.id.map {
                RecommendationPage.Named(id: $0, name: CatalogKey.withoutNumberSuffix(credit.name))
            }
        }
    }
}
