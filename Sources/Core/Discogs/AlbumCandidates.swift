import Library

/// The releases an album might be, in the order they're found (ADR 0131): the release ids its
/// tracks carry, the releases with its barcode, those with its label and catalog number (or one
/// its title names, ADR 0174), then
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
    if let label = album.label {
        for number in catalogNumbers(album) {
            for name in labelNames(label) {
                add(
                    try catalog.releaseIDs(label: name, catalogNumber: number),
                    .labelAndCatalogNumber)
            }
        }
    }
    add(try releaseIDs(of: titleMatches(album.artist, album.title, in: catalog), in: catalog))
    return found
}

/// The masters and master-less releases of `title` and its variants by each name `artist`
/// can be credited as, in that order. The variants drop `artist`'s name before a dash.
func titleMatches(_ artist: String?, _ title: String, in catalog: Catalog) throws
    -> [Catalog.TitleMatch]
{
    var matches: [Catalog.TitleMatch] = []
    for name in artistNames(artist) {
        for variant in [title] + CatalogKey.titleVariants(title, artist: artist) {
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

/// The catalog numbers to look `album` up by: its tags', else those its title names in
/// brackets (ADR 0174).
func catalogNumbers(_ album: DiscogsAlbum) -> [String] {
    album.catalogNumber.map { [$0] } ?? CatalogKey.catalogNumbers(inTitle: album.title)
}

/// What found a candidate release: the release id its tracks carry, its barcode, its label and
/// catalog number, its artist and title, or its artist alone, when nothing else found a release
/// that fits (ADR 0174).
public enum CandidateKey: Equatable, Sendable {
    case taggedID, barcode, labelAndCatalogNumber, title, artist
}

/// The main releases of the masters, and the master-less releases, credited to `artist`, at
/// most `artistOnlyTitles` of each under each name it can be credited as, for an album no
/// search found a fitting release for (ADR 0174). None for a compilation, whose "Various"
/// credits every album, or for a credit Discogs gives albums of no known artist.
func artistOnlyReleases(_ artist: String?, in catalog: Catalog) throws -> [(
    master: Int?, release: Int
)] {
    let names = artistNames(artist)
    guard names != [discogsVarious], !names.contains(where: isCatchAllArtist) else { return [] }
    return try names.flatMap { try catalog.mainReleases(byArtist: $0, limit: artistOnlyTitles) }
}

/// Whether Discogs credits albums of no known artist to `name`, so its releases share nothing.
private func isCatchAllArtist(_ name: String) -> Bool {
    catchAllArtists.contains(CatalogKey.fold(name))
}

/// The folded credits Discogs gives albums of no known artist.
private let catchAllArtists = Set(
    "unknownartist unknownartists unknown noartist none".split(separator: " ").map(String.init))

/// The most masters, and master-less releases, an artist-only search reads, and the most
/// releases it scores. Tuned on the owner's library: 100 masters found 3% more albums than 50
/// and took twice as long, 7 ms an album to 3.
let artistOnlyTitles = 50
let artistOnlyScored = 600
/// The most releases a run keeps from its artist-only searches, about 20 MB.
let artistOnlyCached = 5000
/// The tracklist score a master's main release needs for an artist-only search to score the
/// master's other releases: its titles must pair with some of the album's.
let artistOnlyMainRelease = 0.3

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
