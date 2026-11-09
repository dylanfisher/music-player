import Foundation
import Library

/// What Look Up Release searches for (ADR 0157): any of an artist, a title and a catalog
/// number, or a release by its id.
public struct ReleaseQuery: Equatable, Sendable {
    public var artist: String
    public var title: String
    public var catalogNumber: String
    /// A release id as typed: "1001", "r1001", or a release page's address.
    public var release: String

    public init(
        artist: String = "", title: String = "", catalogNumber: String = "", release: String = ""
    ) {
        self.artist = artist
        self.title = title
        self.catalogNumber = catalogNumber
        self.release = release
    }

    /// The id `release` holds; nil when it holds none.
    public var releaseID: Int? { pastedReleaseID(release) }

    /// Whether a release id is given beside other fields, which it's looked up without.
    public var ignoresOtherFields: Bool {
        releaseID != nil
            && [artist, title, catalogNumber].contains {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
    }

    /// Whether there's nothing to search for.
    public var isEmpty: Bool {
        releaseID == nil
            && [artist, title, catalogNumber].allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).isEmpty
            }
    }
}

/// What Look Up Release found: each release with how well its tracklist fits the album's
/// files, best first, and where they came from.
public struct ReleaseLookup: Sendable {
    public var releases: [(summary: ReleaseSummary, score: Double)]
    public var origin: MatchOrigin
    /// Whether more were found than are listed.
    public var isCut: Bool
}

/// The most releases Look Up lists from the catalog; a master can have hundreds.
let lookedUpCatalogReleases = 200
/// The most releases Look Up reads from the catalog for one search, before the fields given
/// filter them: each is a row read and decoded.
let lookedUpCatalogReads = 5_000

/// Looks `query` up in the catalog at `catalog`, and in `api` only when the catalog finds
/// nothing or there's no catalog to read (ADR 0157). The catalog finds a release by its id,
/// releases by catalog number, else by artist and title through their folded keys; every
/// field given must then hold for each release found. Discogs is asked by id, which needs no
/// token, else searched, which does. Each release is scored against `album`'s files.
public func lookUpReleases(
    _ query: ReleaseQuery, for album: DiscogsAlbum, catalogAt catalog: URL, api: DiscogsAPI?
) async throws -> ReleaseLookup {
    let reading = Task.detached(priority: .userInitiated) {
        () throws -> (releases: [CatalogRelease], isCut: Bool) in
        let opened: Catalog
        do {
            opened = try Catalog(at: catalog)
        } catch CatalogError.missing {
            // No catalog on this Mac: the API is asked instead. One that can't be read is
            // thrown, for the sheet to say so.
            return ([], false)
        }
        return try catalogReleases(query, in: opened)
    }
    // The detached read doesn't hear this task's cancel unless it's passed on.
    let found = try await withTaskCancellationHandler {
        try await reading.value
    } onCancel: {
        reading.cancel()
    }
    try Task.checkCancellation()
    guard found.releases.isEmpty, let api else {
        return scored(found.releases, album, origin: .catalog, isCut: found.isCut)
    }
    let releases: [CatalogRelease]
    var isCut = false
    if let id = query.releaseID {
        do {
            releases = [try await api.release(id: id).release]
        } catch .notFound {
            releases = []
        }
    } else {
        let ids = try await api.search(
            artist: query.artist, title: query.title, catalogNumber: query.catalogNumber)
        let fetched = try await ApiCandidates.fetch(ids, api: api)
        releases = ids.compactMap { fetched[$0] }
        isCut = ids.count > ApiCandidates.maximumReleases
    }
    return scored(releases, album, origin: .api, isCut: isCut)
}

/// The catalog's releases for `query`, each holding every field given, at most
/// `lookedUpCatalogReleases` of the first `lookedUpCatalogReads` found. A release id is
/// looked up alone, whatever else is typed.
private func catalogReleases(_ query: ReleaseQuery, in catalog: Catalog) throws -> (
    releases: [CatalogRelease], isCut: Bool
) {
    if let id = query.releaseID {
        return (try catalog.release(id: id).map { [$0] } ?? [], false)
    }
    let limit = lookedUpCatalogReads
    let artist = query.artist.trimmingCharacters(in: .whitespaces)
    let title = query.title.trimmingCharacters(in: .whitespaces)
    var ids: [Int] = []
    var seen: Set<Int> = []
    func add(_ found: [Int]) {
        for id in found where seen.insert(id).inserted { ids.append(id) }
    }
    if !query.catalogNumber.trimmingCharacters(in: .whitespaces).isEmpty {
        add(try catalog.releaseIDs(catalogNumber: query.catalogNumber, limit: limit + 1))
    } else if !artist.isEmpty || !title.isEmpty {
        var matches: [Catalog.TitleMatch] = []
        if artist.isEmpty {
            matches = try catalog.titleMatches(artist: nil, title: title, limit: limit + 1)
        } else {
            for name in artistNames(artist) {
                if title.isEmpty {
                    matches += try catalog.titleMatches(artist: name, title: nil, limit: limit + 1)
                } else {
                    for variant in [title] + CatalogKey.titleVariants(title) {
                        matches += try catalog.titleMatches(artist: name, title: variant)
                    }
                }
            }
        }
        for match in matches where ids.count <= limit {
            switch match {
            case .master(let id): add(try catalog.releaseIDs(master: id))
            case .release(let id): add([id])
            }
        }
    }
    // Filtered before they're cut, so the release wanted isn't dropped for others the fields
    // rule out.
    var kept: [CatalogRelease] = []
    for id in ids.prefix(limit) where kept.count <= lookedUpCatalogReleases {
        try Task.checkCancellation()
        if let release = try catalog.release(id: id), holds(query, release) {
            kept.append(release)
        }
    }
    return (
        Array(kept.prefix(lookedUpCatalogReleases)),
        kept.count > lookedUpCatalogReleases || ids.count > limit
    )
}

/// Whether `release` holds every field of `query` given: the artist and title within its own,
/// folded, and the catalog number as one of its labels'.
private func holds(_ query: ReleaseQuery, _ release: CatalogRelease) -> Bool {
    let artist = CatalogKey.fold(query.artist)
    if !artist.isEmpty {
        let names = release.artists.map(\.name)
        let credited = CatalogKey.artistKeys(names).union([CatalogKey.fold(release.summary.artist)])
        guard credited.contains(where: { $0.contains(artist) }) else { return false }
    }
    let title = CatalogKey.fold(query.title, title: true)
    if !title.isEmpty, !CatalogKey.fold(release.title, title: true).contains(title) {
        return false
    }
    if let number = CatalogKey.catalogNumber(query.catalogNumber) {
        let numbers = release.labels.compactMap {
            $0.catalogNumber.flatMap(CatalogKey.catalogNumber)
        }
        guard numbers.contains(number) else { return false }
    }
    return true
}

/// The releases with their fit to `album`'s files, best first, found order between equals.
private func scored(
    _ releases: [CatalogRelease], _ album: DiscogsAlbum, origin: MatchOrigin, isCut: Bool
) -> ReleaseLookup {
    let titles = TitleSimilarity(album.tracks.map(\.title))
    let seconds = album.tracks.map(\.seconds)
    let fits = releases.enumerated().map { index, release in
        (
            index, release.summary,
            ReleaseScore.best(release, seconds: seconds, titles: titles).tracklist
        )
    }
    let sorted = fits.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
    return ReleaseLookup(
        releases: sorted.map { (summary: $0.1, score: $0.2) }, origin: origin, isCut: isCut)
}
