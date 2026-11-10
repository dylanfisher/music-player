import Library

/// The releases an album might be, in the order they're found (ADR 0131): the release ids its
/// tracks carry, the releases with its barcode, those with its label and catalog number, then
/// the releases of the masters, and the master-less releases, with its artist and title. Each
/// release once, with the way it was first found. Without a catalog, only the tagged ids.
func candidateIDs(for album: DiscogsAlbum, in catalog: Catalog?) throws
    -> [(id: Int, foundBy: CandidateKey)]
{
    var found: [(id: Int, foundBy: CandidateKey)] = []
    var seen: Set<Int> = []
    func add(_ ids: [Int], _ key: CandidateKey = .title) {
        for id in ids where seen.insert(id).inserted { found.append((id, key)) }
    }
    add(taggedReleaseIDs(album), .taggedID)
    guard let catalog else { return found }
    if let barcode = album.barcode { add(try catalog.releaseIDs(barcode: barcode), .barcode) }
    if let number = album.catalogNumber, let label = album.label {
        for name in labelNames(label) {
            add(try catalog.releaseIDs(label: name, catalogNumber: number), .labelAndCatalogNumber)
        }
    }
    add(try releaseIDs(of: titleMatches(album.artist, album.title, in: catalog), in: catalog))
    return found
}

/// The masters and master-less releases of `title` and its variants by each name `artist`
/// can be credited as, in that order.
func titleMatches(_ artist: String?, _ title: String, in catalog: Catalog) throws
    -> [Catalog.TitleMatch]
{
    var matches: [Catalog.TitleMatch] = []
    for name in artistNames(artist) {
        for variant in [title] + CatalogKey.titleVariants(title) {
            matches += try catalog.titleMatches(artist: name, title: variant)
        }
    }
    return matches
}

/// The releases `matches` stand for, in order: each master's releases, a master once, and each
/// release with no master.
func releaseIDs(of matches: [Catalog.TitleMatch], in catalog: Catalog) throws -> [Int] {
    var masters: Set<Int> = []
    var ids: [Int] = []
    for match in matches {
        switch match {
        case .master(let id):
            if masters.insert(id).inserted { ids += try catalog.releaseIDs(master: id) }
        case .release(let id): ids.append(id)
        }
    }
    return ids
}

/// The release ids `album`'s tracks carry, in track order, each once.
func taggedReleaseIDs(_ album: DiscogsAlbum) -> [Int] {
    var seen: Set<Int> = []
    return album.tracks.compactMap { $0.releaseID.flatMap { Int($0) } }.filter {
        seen.insert($0).inserted
    }
}

/// What found a candidate release: the release id its tracks carry, its barcode, its label and
/// catalog number, or its artist and title.
public enum CandidateKey: Equatable, Sendable {
    case taggedID, barcode, labelAndCatalogNumber, title
}

/// The label as tagged, then each label of a " & " list, as YATE joins a release's labels
/// (ADR 0128); a label whose own name has " & " in it is found by the whole.
func labelNames(_ label: String) -> [String] {
    let parts = label.components(separatedBy: " & ").filter { !$0.isEmpty }
    return parts.count > 1 ? [label] + parts : [label]
}

/// The album's artist as tagged, then the first of a list of artists, which Discogs credits
/// apart; a compilation's, or Various Artists, as Discogs's "Various".
func artistNames(_ artist: String?) -> [String] {
    guard let artist, CatalogKey.fold(artist) != CatalogKey.fold(variousArtists) else {
        return [discogsVarious]
    }
    var names = [artist]
    let lowered = artist.lowercased()
    let first = artistSeparators.compactMap { lowered.range(of: $0)?.lowerBound }.min()
    if let first {
        let name = String(artist[..<first]).trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { names.append(name) }
    }
    return names
}

/// What Discogs credits a compilation of many artists to.
let discogsVarious = "Various"

/// What a library's artist tag puts between the artists of a credit, lowercased.
private let artistSeparators = [
    " feat. ", " feat ", " ft. ", " featuring ", " & ", " and ", ", ", " vs. ", " vs ", " x ",
    " / ", " with ",
]
