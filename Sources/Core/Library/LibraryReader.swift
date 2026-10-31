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

    public func trackNames(_ filter: TrackFilter, sortedBy column: TrackColumn, ascending: Bool)
        throws -> [TrackName]
    {
        try index.trackNames(filter, sortedBy: column, ascending: ascending)
    }

    public func genres(_ filter: TrackFilter) throws -> [BrowserEntry] {
        try index.genres(filter)
    }

    public func artists(_ filter: TrackFilter) throws -> [BrowserEntry] {
        try index.artists(filter)
    }

    public func albums(_ filter: TrackFilter) throws -> [BrowserEntry] {
        try index.albums(filter)
    }

    public func paths(ids: [Int64]) throws -> [Int64: String] {
        try index.paths(ids: ids)
    }

    public func fileIssues() throws -> [FileIssue] {
        try index.fileIssues()
    }
}
