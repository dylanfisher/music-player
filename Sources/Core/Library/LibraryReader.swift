import DisplayText
import Foundation
import Log
import Settings

/// The library window's queries on a connection of their own, run off the main thread so a slow
/// query never holds up typing, and the user's own edits: playlists, ratings and plays. Each call
/// waits for the one before it, so a query after an edit sees it.
public actor LibraryReader {
    private let index: LibraryIndex
    private let databaseURL: URL
    private let refreshConnection: LibraryReader?

    public init(databaseURL: URL) throws {
        index = try LibraryIndex(at: databaseURL)
        self.databaseURL = databaseURL
        refreshConnection = try LibraryReader(refreshing: databaseURL)
    }

    /// Read-only, so nothing written on it can race the edits on the first connection.
    private init(refreshing databaseURL: URL) throws {
        index = try LibraryIndex(at: databaseURL)
        try index.database.execute(queryOnlySQL)
        self.databaseURL = databaseURL
        refreshConnection = nil
    }

    /// For tests, which hold the connection busy as a long query would.
    func run(_ body: @Sendable () -> Void) { body() }

    /// The same queries on a second connection, for what a change to the library rereads. While
    /// a scan runs, those reads take hundreds of milliseconds on two cores, and a search typed
    /// meanwhile would wait for them in this actor (ADR 0086).
    public nonisolated var refreshes: LibraryReader { refreshConnection ?? self }

    /// Builds the health report on a connection of its own, so the window's queries don't wait
    /// for it.
    public nonisolated func healthReport(
        measuredChecks: @escaping @Sendable (FileMeasures) -> [HealthCheck]
    ) async throws -> HealthReport {
        let url = databaseURL
        return try await Task.detached {
            try LibraryIndex(at: url).healthReport(measuredChecks: measuredChecks)
        }.value
    }

    /// Every album as the Discogs matcher compares it (ADR 0131), on a connection of its own,
    /// so the window's queries don't wait for the whole library's tracks.
    public nonisolated func discogsAlbums() async throws -> [DiscogsAlbum] {
        let url = databaseURL
        return try await Task.detached { try LibraryIndex(at: url).discogsAlbums() }.value
    }

    /// Writes the library's profile for music-recommender to `url` (ADR 0198), on a connection
    /// of its own, as `discogsAlbums` reads, and returns how many albums it holds.
    public nonisolated func writeLibraryProfile(to url: URL) async throws -> Int {
        let databaseURL = databaseURL
        return try await Task.detached {
            try LibraryIndex(at: databaseURL).writeLibraryProfile(to: url)
        }.value
    }

    /// The Discogs tagger's reviews, by album ID (ADR 0133).
    public func discogsReviews() throws -> [Int64: DiscogsReview] { try index.discogsReviews() }

    /// Records `review` for an album's tracks, `fileIDs`; nil forgets it.
    public func setDiscogsReview(_ review: DiscogsReview?, files fileIDs: [Int64]) throws {
        try index.setDiscogsReview(review, files: fileIDs)
    }

    /// The Discogs API's cached entry for `id` of `kind`, and when it was fetched (ADR 0138).
    public func discogsCached(kind: String, id: Int) throws -> (fetchedAt: Double, json: String)? {
        try index.discogsCached(kind: kind, id: id)
    }

    /// Keeps the Discogs API's `json` for `id` of `kind`, replacing any entry before.
    public func storeDiscogs(kind: String, id: Int, fetchedAt: Double, json: String) throws {
        try index.storeDiscogs(kind: kind, id: id, fetchedAt: fetchedAt, json: json)
    }

    /// Removes the Discogs API's entries of `kind` for `ids`.
    public func removeDiscogs(kind: String, ids: [Int]) throws {
        try index.removeDiscogs(kind: kind, ids: ids)
    }

    /// A connection for Listening Stats' reads, opened off the main thread.
    public nonisolated func statsReader() async throws -> StatsReader {
        let url = databaseURL
        return try await Task.detached { try StatsReader(databaseURL: url) }.value
    }

    /// Lists `report`'s tracks for the `.health` sources.
    public func showHealth(_ report: HealthReport) throws { try index.showHealth(report) }

    public func trackIDs(_ filter: TrackFilter, sortedBy column: TrackColumn, ascending: Bool)
        throws -> [Int64]
    {
        try signposted(.query) {
            try index.trackIDs(filter, sortedBy: column, ascending: ascending)
        }
    }

    public func trackTotals(ids: [Int64]) throws -> TrackTotals {
        try signposted(.query) { try index.trackTotals(ids: ids) }
    }

    public func trackNames(_ filter: TrackFilter, sortedBy column: TrackColumn, ascending: Bool)
        throws -> [TrackName]
    {
        try signposted(.query) {
            try index.trackNames(filter, sortedBy: column, ascending: ascending)
        }
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

    public func columnEntries(
        _ grouping: BrowserGrouping, _ filter: TrackFilter, ignoring: Set<BrowserGrouping>
    ) throws -> [ColumnEntry] {
        try signposted(.query) { try index.columnEntries(grouping, filter, ignoring: ignoring) }
    }

    public func paths(ids: [Int64]) throws -> [Int64: String] {
        try index.paths(ids: ids)
    }

    public func albumIDs(ids: [Int64]) throws -> [Int64: Int64] {
        try index.albumIDs(ids: ids)
    }

    /// The rows of the tracks with `ids`, in that order, leaving out those that are gone.
    public func rows(ids: [Int64]) throws -> [TrackRow] {
        try index.rows(ids: ids)
    }

    /// The track ID of each path, or nil where the library has none.
    public func trackIDs(atPaths paths: [String]) throws -> [Int64?] {
        try index.trackIDs(atPaths: paths)
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

    public func movePlaylistEntries(
        _ id: Int64, trackIDs: [Int64], before target: Int64?, inOrderGiven: Bool = false
    )
        throws
    {
        try index.movePlaylistEntries(
            id, trackIDs: trackIDs, before: target, inOrderGiven: inOrderGiven)
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

    /// Sets the play count of the tracks at `paths` by hand; a path the index has no track
    /// for is left out.
    public func setPlayCount(_ count: Int, paths: [String]) throws {
        let ids = try index.trackIDs(atPaths: paths).compactMap { $0 }
        try index.setPlayCount(count, trackIDs: ids)
    }

    public func toggle(_ opinion: TrackOpinion, trackIDs: [Int64]) throws {
        try index.toggle(opinion, trackIDs: trackIDs)
    }

    public func timeline(before id: Int64?, limit: Int, in span: PlaySpan? = nil) throws
        -> [PlayEntry]
    {
        try index.timeline(before: id, limit: limit, in: span)
    }

    public func timeline(after id: Int64, limit: Int, in span: PlaySpan? = nil) throws
        -> [PlayEntry]
    {
        try index.timeline(after: id, limit: limit, in: span)
    }

    /// How many plays the timeline lists: every logged play, or those in `span`.
    public func playCount(in span: PlaySpan?) throws -> Int {
        try span.map { try index.playCount(in: $0) } ?? index.loggedPlayCount()
    }

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

    /// `folders` where their paths were last, each share folder at its last mount (ADR 0028).
    public func lastKnownFolders(_ folders: [WatchedFolder]) throws -> [WatchedFolder] {
        try index.lastKnownFolders(folders)
    }

    public func dismissProblems(_ lines: [String]) throws { try index.dismissProblems(lines) }

    public func dismissedProblems() throws -> Set<String> { try index.dismissedProblems() }

    public func discards() throws -> [DiscardNotice] { try index.discards() }

    public func forgetDiscards(_ ids: [Int64]) throws { try index.forgetDiscards(ids) }
}

/// Makes a connection read-only, so nothing written on it can race another's edits.
let queryOnlySQL = "PRAGMA query_only = ON"
