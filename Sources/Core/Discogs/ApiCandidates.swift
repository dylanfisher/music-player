import Library
import Log

private let logger = moduleLogger()

/// The releases the Discogs API finds for an album (ADR 0139), in the order `candidateIDs`
/// finds the catalog's: the release the user chose and the ids its tracks carry, then the
/// releases with its barcode, then with its label and catalog number, then by its artist and
/// title, each way spelled as the catalog's are tried. Without a token only the ids are looked
/// up, since nothing else can be searched.
enum ApiCandidates {
    /// The most releases fetched for one album; the first found are fetched first.
    static let maximumReleases = 8

    /// The candidates found, each once with how it was first found. A search that fails on its
    /// own reply is logged and the next is tried; any error that stops the run is thrown.
    static func found(for album: DiscogsAlbum, choosing choice: Int?, api: DiscogsAPI)
        async throws(DiscogsAPIError) -> [(id: Int, foundBy: CandidateKey)]
    {
        var found: [(id: Int, foundBy: CandidateKey)] = []
        var seen: Set<Int> = []
        func add(_ ids: [Int], _ key: CandidateKey) {
            for id in ids where seen.insert(id).inserted { found.append((id, key)) }
        }
        add((choice.map { [$0] } ?? []) + taggedReleaseIDs(album), .taggedID)
        guard api.hasToken else { return found }
        let tagged = found.count
        if let barcode = album.barcode {
            add(
                try await searching(album) { () async throws(DiscogsAPIError) -> [Int] in
                    try await api.search(barcode: barcode)
                }, .barcode)
        }
        if found.count == tagged, let number = album.catalogNumber, let label = album.label {
            for name in labelNames(label) where found.count == tagged {
                add(
                    try await searching(album) { () async throws(DiscogsAPIError) -> [Int] in
                        try await api.search(catalogNumber: number, label: name)
                    }, .labelAndCatalogNumber)
            }
        }
        guard found.count == tagged else { return found }
        for artist in artistNames(album.artist) where found.count == tagged {
            for title in [album.title] + CatalogKey.titleVariants(album.title)
            where found.count == tagged {
                add(
                    try await searching(album) { () async throws(DiscogsAPIError) -> [Int] in
                        try await api.search(artist: artist, title: title)
                    },
                    .title)
            }
        }
        return found
    }

    /// What `run` finds, or nothing when it fails on its own reply, which is logged.
    private static func searching(
        _ album: DiscogsAlbum, _ run: () async throws(DiscogsAPIError) -> [Int]
    ) async throws(DiscogsAPIError) -> [Int] {
        do {
            return try await run()
        } catch {
            guard !error.stopsRun else { throw error }
            logger.error("a Discogs search for album \(album.id) failed: \(error)")
            return []
        }
    }

    /// The releases `ids` from the API, at most `maximumReleases`, by id. A release that's
    /// missing or unusable is logged and left out. When two or more share a master, the
    /// master is asked once which of them is its main release, which the tie-break prefers.
    static func fetch(_ ids: [Int], api: DiscogsAPI) async throws(DiscogsAPIError)
        -> [Int: CatalogRelease]
    {
        var fetched: [Int: CatalogRelease] = [:]
        for id in ids.prefix(maximumReleases) {
            do {
                fetched[id] = try await api.release(id: id).release
            } catch {
                guard !error.stopsRun else { throw error }
                logger.error("Discogs release \(id) was left out: \(error)")
            }
        }
        let byMaster = Dictionary(grouping: fetched.values.filter { $0.masterID != nil }) {
            $0.masterID!
        }
        for (master, releases) in byMaster.sorted(by: { $0.key < $1.key }) where releases.count > 1
        {
            let main: Int?
            do {
                main = try await api.mainRelease(master: master)
            } catch {
                guard !error.stopsRun else { throw error }
                logger.error("Discogs master \(master) was left out: \(error)")
                continue
            }
            for release in releases { fetched[release.id]?.isMainRelease = release.id == main }
        }
        return fetched
    }
}
