import Foundation
import Settings

/// The library window's queries on a connection of their own, run off the main thread so a slow
/// query never holds up typing. Each call waits for the one before it.
public actor LibraryReader {
    private let index: LibraryIndex

    public init(databaseURL: URL) throws {
        index = try LibraryIndex(at: databaseURL)
    }

    public func trackIDs(_ filter: TrackFilter, sortedBy column: TrackColumn, ascending: Bool)
        throws -> [Int64]
    {
        try index.trackIDs(filter, sortedBy: column, ascending: ascending)
    }

    /// The three panes for `filter`, each narrowed by the panes to its left.
    public func panes(_ filter: TrackFilter) throws -> BrowserPanes {
        BrowserPanes(
            genres: try index.genres(filter), artists: try index.artists(filter),
            albums: try index.albums(filter))
    }

    public func artists(_ filter: TrackFilter) throws -> [BrowserEntry] {
        try index.artists(filter)
    }

    public func albums(_ filter: TrackFilter) throws -> [BrowserEntry] {
        try index.albums(filter)
    }

    public func paths(ids: [Int64]) throws -> [String] {
        try index.paths(ids: ids)
    }

    public func fileIssues() throws -> [FileIssue] {
        try index.fileIssues()
    }
}

/// The genre, artist and album panes' entries.
public struct BrowserPanes: Equatable, Sendable {
    public var genres: [BrowserEntry]
    public var artists: [BrowserEntry]
    public var albums: [BrowserEntry]

    public init(genres: [BrowserEntry], artists: [BrowserEntry], albums: [BrowserEntry]) {
        self.genres = genres
        self.artists = artists
        self.albums = albums
    }
}
