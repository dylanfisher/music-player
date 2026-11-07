/// A master: the release group a release belongs to, which the matcher looks albums up by.
struct CatalogMaster: Equatable, Sendable {
    var id: Int
    var mainReleaseID: Int?
    var title: String
    var year: Int?
    var artists: [CatalogArtistCredit]
    var genres: [String]
    var styles: [String]

    init(
        id: Int, mainReleaseID: Int? = nil, title: String, year: Int? = nil,
        artists: [CatalogArtistCredit] = [], genres: [String] = [], styles: [String] = []
    ) {
        self.id = id
        self.mainReleaseID = mainReleaseID
        self.title = title
        self.year = year
        self.artists = artists
        self.genres = genres
        self.styles = styles
    }
}

extension CatalogMaster {
    /// What the catalog keeps of a master beyond its row's columns, as one JSON object.
    struct Lists: Codable {
        var artists: [CatalogArtistCredit]
        var genres: [String]
        var styles: [String]
    }
}
