import Foundation
import Library

/// Where `DiscogsAPI` keeps what it fetched by id, as JSON text: the index's `discogs_cache`
/// table in the app, a dictionary in tests (ADR 0138). Searches aren't kept, since their
/// answer changes, except what an Analyze's searches found for an album until the run ends
/// (ADR 0190).
public struct DiscogsCache: Sendable {
    public enum Kind: String, Sendable {
        case release, master
        /// The candidates the searches found for an album, by album ID.
        case found
    }

    /// An entry and when it was fetched, in seconds since 1970.
    public typealias Entry = (fetchedAt: Double, json: String)

    public var read: @Sendable (Kind, Int) async throws -> Entry?
    public var store: @Sendable (Kind, Int, Entry) async throws -> Void
    public var remove: @Sendable (Kind, [Int]) async throws -> Void

    public init(
        read: @escaping @Sendable (Kind, Int) async throws -> Entry?,
        store: @escaping @Sendable (Kind, Int, Entry) async throws -> Void,
        remove: @escaping @Sendable (Kind, [Int]) async throws -> Void
    ) {
        self.read = read
        self.store = store
        self.remove = remove
    }

    /// The index's cache, through `reader`'s connection.
    public static func index(_ reader: LibraryReader) -> DiscogsCache {
        DiscogsCache(
            read: { kind, id in try await reader.discogsCached(kind: kind.rawValue, id: id) },
            store: { kind, id, entry in
                try await reader.storeDiscogs(
                    kind: kind.rawValue, id: id, fetchedAt: entry.fetchedAt, json: entry.json)
            },
            remove: { kind, ids in try await reader.removeDiscogs(kind: kind.rawValue, ids: ids) })
    }
}

/// A fetched release as the cache keeps it: the catalog's columns and lists, with their
/// one-letter keys, and the primary image, so a hit needs no second conversion.
struct CachedRelease: Codable {
    var id: Int
    var masterID: Int?
    var title: String
    var country: String?
    var released: String?
    var lists: CatalogRelease.Lists
    var primaryImage: URL?

    private enum CodingKeys: String, CodingKey {
        case id = "i"
        case masterID = "m"
        case title = "t"
        case country = "c"
        case released = "r"
        case lists = "l"
        case primaryImage = "p"
    }

    init(_ fetched: FetchedRelease) {
        let release = fetched.release
        id = release.id
        masterID = release.masterID
        title = release.title
        country = release.country
        released = release.released
        lists = release.lists
        primaryImage = fetched.primaryImage
    }

    var fetched: FetchedRelease {
        FetchedRelease(
            release: CatalogRelease(
                id: id, masterID: masterID, title: title, artists: lists.artists,
                labels: lists.labels, formats: lists.formats, country: country,
                released: released, genres: lists.genres, styles: lists.styles,
                barcodes: lists.barcodes, credits: lists.credits, tracks: lists.tracks),
            primaryImage: primaryImage)
    }
}

/// A fetched master as the cache keeps it: only its main release, which the tie-break reads.
struct CachedMaster: Codable {
    var mainReleaseID: Int?

    private enum CodingKeys: String, CodingKey {
        case mainReleaseID = "r"
    }
}
