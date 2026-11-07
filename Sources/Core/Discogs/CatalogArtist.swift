/// An artist: the name Discogs links credits to, and the other names it's credited as.
struct CatalogArtist: Equatable, Sendable {
    var id: Int
    var name: String
    var nameVariations: [String]

    init(id: Int, name: String, nameVariations: [String] = []) {
        self.id = id
        self.name = name
        self.nameVariations = nameVariations
    }
}
