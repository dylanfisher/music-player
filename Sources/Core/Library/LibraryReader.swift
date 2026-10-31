import Foundation
import Settings

/// The library window's queries on a connection of their own, run off the main thread so a slow
/// query never holds up typing, and the user's own edits: playlists, ratings and plays. Each call
/// waits for the one before it, so a query after an edit sees it.
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

    public func playlists() throws -> [Playlist] { try index.playlists() }

    public func createPlaylist(named name: String, rules: SmartRules?) throws -> Int64 {
        try index.createPlaylist(named: name, rules: rules)
    }

    public func renamePlaylist(_ id: Int64, to name: String) throws {
        try index.renamePlaylist(id, to: name)
    }

    public func setRules(_ rules: SmartRules, of id: Int64) throws {
        try index.setRules(rules, of: id)
    }

    public func deletePlaylist(_ id: Int64) throws { try index.deletePlaylist(id) }

    public func addToPlaylist(_ id: Int64, paths: [String]) throws -> Int {
        try index.addToPlaylist(id, paths: paths)
    }

    public func movePlaylistEntries(_ id: Int64, paths: [String], before target: String?) throws {
        try index.movePlaylistEntries(id, paths: paths, before: target)
    }

    public func removeFromPlaylist(_ id: Int64, paths: [String]) throws {
        try index.removeFromPlaylist(id, paths: paths)
    }

    public func missingEntryCount(_ id: Int64) throws -> Int {
        try index.missingEntryCount(id)
    }

    public func recordPlay(_ path: String, at seconds: Double) throws {
        try index.recordPlay(path, at: seconds)
    }

    public func recordSkip(_ path: String) throws { try index.recordSkip(path) }

    public func setRating(_ stars: Int, paths: [String]) throws {
        try index.setRating(stars, paths: paths)
    }
}
