import DisplayText
import Foundation
import Settings

/// The library window's queries on a connection of their own, run off the main thread so a slow
/// query never holds up typing, and the user's own edits: playlists, ratings and plays. Each call
/// waits for the one before it, so a query after an edit sees it.
public actor LibraryReader {
    private let index: LibraryIndex
    private let databaseURL: URL

    public init(databaseURL: URL) throws {
        index = try LibraryIndex(at: databaseURL)
        self.databaseURL = databaseURL
    }

    /// Builds the health report on a connection of its own, so the window's queries don't wait
    /// for it.
    public nonisolated func healthReport() async throws -> HealthReport {
        let url = databaseURL
        return try await Task.detached { try LibraryIndex(at: url).healthReport() }.value
    }

    /// Lists `report`'s tracks for the `.health` sources.
    public func showHealth(_ report: HealthReport) throws { try index.showHealth(report) }

    public func trackIDs(_ filter: TrackFilter, sortedBy column: TrackColumn, ascending: Bool)
        throws -> [Int64]
    {
        try index.trackIDs(filter, sortedBy: column, ascending: ascending)
    }

    public func trackTotals(ids: [Int64]) throws -> TrackTotals { try index.trackTotals(ids: ids) }

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

    public func duplicatePlaylist(_ id: Int64, named name: String) throws -> Int64 {
        try index.duplicatePlaylist(id, named: name)
    }

    public func setRules(_ rules: SmartRules, of id: Int64) throws {
        try index.setRules(rules, of: id)
    }

    public func deletePlaylist(_ id: Int64) throws { try index.deletePlaylist(id) }

    public func addToPlaylist(_ id: Int64, trackIDs: [Int64]) throws -> Int {
        try index.addToPlaylist(id, trackIDs: trackIDs)
    }

    public func movePlaylistEntries(_ id: Int64, trackIDs: [Int64], before target: Int64?)
        throws
    {
        try index.movePlaylistEntries(id, trackIDs: trackIDs, before: target)
    }

    public func removeFromPlaylist(_ id: Int64, trackIDs: [Int64]) throws {
        try index.removeFromPlaylist(id, trackIDs: trackIDs)
    }

    public func missingEntryCount(_ id: Int64) throws -> Int {
        try index.missingEntryCount(id)
    }

    /// Reads the playlist file at `url` and makes a manual playlist named after it.
    public func importPlaylist(from url: URL) throws -> PlaylistImport {
        // A file name can hold a line break, which the sidebar and the report would show as two.
        let name = terminalSafe(
            url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping)
        return try index.importPlaylist(
            named: name, try PlaylistFile(contentsOf: url), from: url.path)
    }

    /// Writes a playlist's tracks, sorted as given, to `url` as M3U8, and returns how many were
    /// written and the paths that couldn't be.
    public func exportPlaylist(
        _ id: Int64, sortedBy column: TrackColumn, ascending: Bool, groupByAlbumArtist: Bool,
        to url: URL, relativePaths: Bool
    ) throws -> (written: Int, unwritable: [String]) {
        let tracks = try index.playlistFileTracks(
            id, sortedBy: column, ascending: ascending, groupByAlbumArtist: groupByAlbumArtist)
        let unwritable = try writeM3U8(tracks, to: url, relativePaths: relativePaths)
        return (tracks.count - unwritable.count, unwritable)
    }

    /// What importing another player's library would change, without writing.
    public func importPlan(_ library: PlayerLibrary, prefix: PathPrefix?) throws -> ImportPlan {
        try index.importPlan(library, prefix: prefix)
    }

    /// Writes an import in one transaction, and returns what it wrote.
    public func applyImport(_ library: PlayerLibrary, prefix: PathPrefix?) throws -> ImportPlan {
        try index.applyImport(library, prefix: prefix)
    }

    public func recordPlay(_ path: String, at seconds: Double) throws {
        try index.recordPlay(path, at: seconds)
    }

    public func recordSkip(_ path: String) throws { try index.recordSkip(path) }

    public func setRating(_ stars: Int, trackIDs: [Int64]) throws {
        try index.setRating(stars, trackIDs: trackIDs)
    }

    public func toggle(_ opinion: TrackOpinion, trackIDs: [Int64]) throws {
        try index.toggle(opinion, trackIDs: trackIDs)
    }

    public func timeline(before id: Int64?, limit: Int) throws -> [PlayEntry] {
        try index.timeline(before: id, limit: limit)
    }

    public func timeline(after id: Int64, limit: Int) throws -> [PlayEntry] {
        try index.timeline(after: id, limit: limit)
    }

    public func loggedPlayCount() throws -> Int { try index.loggedPlayCount() }

    public func lostFiles() throws -> [LostFile] { try index.lostFiles() }

    public func moveStats(from lost: Int64, to track: Int64) throws -> Bool {
        try index.moveStats(from: lost, to: track)
    }

    public func dismissLost(_ ids: [Int64]) throws { try index.dismissLost(ids) }

    public func removeFromLibrary(trackIDs: [Int64]) throws {
        try index.removeFromLibrary(trackIDs: trackIDs)
    }

    public func forgetTrashed(trackIDs: [Int64]) throws {
        try index.forgetTrashed(trackIDs: trackIDs)
    }

    public func removedPaths() throws -> [RemovedPath] { try index.removedPaths() }

    public func restoreRemoved(_ ids: [Int64]) throws -> [String] {
        try index.restoreRemoved(ids)
    }

    public func discards() throws -> [DiscardNotice] { try index.discards() }

    public func forgetDiscards(_ ids: [Int64]) throws { try index.forgetDiscards(ids) }
}
