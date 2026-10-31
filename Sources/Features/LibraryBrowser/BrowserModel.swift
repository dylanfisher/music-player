import Foundation
import Library
import Log
import Settings

private let logger = moduleLogger()

/// The browser's logic, apart from AppKit: the sidebar's source, the three panes, the search and
/// the sort decide which track IDs the table shows, and in what order.
///
/// Every query runs on the `LibraryReader`, off the main thread. A change that a newer one
/// overtakes while its queries run is dropped, so the last keystroke or click wins.
@MainActor
public final class BrowserModel {
    /// The panes, left to right. Each narrows the ones after it.
    public enum Pane: Int, CaseIterable, Comparable, Sendable {
        case genre, artist, album

        public static func < (a: Pane, b: Pane) -> Bool { a.rawValue < b.rawValue }
    }

    public private(set) var filter = TrackFilter()
    public private(set) var genres: [BrowserEntry] = []
    public private(set) var artists: [BrowserEntry] = []
    public private(set) var albums: [BrowserEntry] = []
    public private(set) var trackIDs: [Int64] = []
    public private(set) var sortColumn: TrackColumn
    public private(set) var ascending: Bool
    /// Every playlist, by name, as the sidebar lists them.
    public private(set) var playlists: [Playlist] = []
    /// Called after each change is applied.
    public var changed: (BrowserChange) -> Void = { _ in }
    /// Called when a query fails. What the browser showed stays.
    public var failed: (String) -> Void = { _ in }

    private let reader: LibraryReader
    /// Counts changes, so a change's results are applied only if no newer one started.
    private var generation = 0
    /// The newest change's filter and sort, applied or still running. Each change builds on
    /// these, so one that overtakes another carries it along instead of losing it.
    private var pending = TrackFilter()
    private var pendingSort: (column: TrackColumn, ascending: Bool)
    /// The leftmost pane a change not yet applied reloads from, and the saved selections a load
    /// not yet applied restores.
    private var pendingPanes: Pane?
    private var pendingSaved: BrowserState?
    /// Counts applied changes, so names read for one list aren't used for the next.
    private var applied = 0
    private var names: (applied: Int, list: [TrackName])?
    /// The sources the sidebar showed, for Back and Forward.
    public private(set) var history = SourceHistory()

    public init(reader: LibraryReader, sortColumn: TrackColumn, ascending: Bool) {
        self.reader = reader
        self.sortColumn = sortColumn
        self.ascending = ascending
        pendingSort = (sortColumn, ascending)
    }

    /// The selections the window saves, by name.
    public var state: BrowserState {
        BrowserState(
            source: filter.source, genre: name(filter.genre, in: genres),
            artist: name(filter.artist, in: artists), album: name(filter.album, in: albums))
    }

    /// Loads the playlists, panes and tracks, selecting what `saved` names where it still
    /// exists.
    public func load(_ saved: BrowserState) async {
        var saved = saved
        do {
            playlists = try await reader.playlists()
        } catch {
            logger.error("couldn't read the playlists: \(error)")
            failed("couldn't read the playlists: \(error)")
        }
        if case .playlist(let id) = saved.source, !playlists.contains(where: { $0.id == id }) {
            logger.notice("the saved playlist \(id) is gone; showing the library")
            saved.source = nil
        }
        history = SourceHistory(start: saved.source)
        pending = TrackFilter(source: saved.source, search: pending.search)
        await reload(panesFrom: .genre, saved: saved, reason: .loaded)
    }

    /// Selects an entry of `pane` by ID, or All for nil. The panes to its right are narrowed, and
    /// lose a selection they no longer list.
    public func select(_ pane: Pane, id: Int64?) async {
        switch pane {
        case .genre: pending.genre = id
        case .artist: pending.artist = id
        case .album: pending.album = id
        }
        await reload(panesFrom: Pane(rawValue: pane.rawValue + 1), reason: .user)
    }

    /// Shows a watched folder, a playlist or History, or the whole library for nil, as a step
    /// Back can undo.
    public func setSource(_ source: BrowserSource?) async {
        history.visit(source)
        if let sort = defaultSort(source) { pendingSort = sort }
        await showSource(source)
    }

    /// A manual playlist opens in its own order, and History with the latest play first. Other
    /// sources keep the sort the table has.
    func defaultSort(_ source: BrowserSource?) -> (column: TrackColumn, ascending: Bool)? {
        switch source {
        case .playlist(let id):
            playlists.first { $0.id == id }?.isManual == true ? (.playlistOrder, true) : nil
        case .history: (.lastPlayed, false)
        case .folder, nil: nil
        }
    }

    /// The playlist the sidebar shows, if it shows one.
    public var shownPlaylist: Playlist? {
        guard case .playlist(let id) = filter.source else { return nil }
        return playlists.first { $0.id == id }
    }

    /// Whether dragging rows moves them: only in a manual playlist shown in its own order.
    public var canReorder: Bool {
        shownPlaylist?.isManual == true && sortColumn == .playlistOrder && ascending
    }

    // MARK: Playlist and stats edits. Each refreshes what it changed.

    /// Reads the playlists again. If the one shown has gone, the library is shown.
    public func reloadPlaylists() async throws {
        playlists = try await reader.playlists()
        if case .playlist(let id) = pending.source, !playlists.contains(where: { $0.id == id }) {
            await setSource(nil)
        }
    }

    /// Makes a playlist, manual unless `rules` are given, holding the tracks at `rows`, and
    /// shows it.
    public func createPlaylist(named name: String, rules: SmartRules?, rows: IndexSet = [])
        async throws
    {
        let paths = try await self.paths(ofRows: rows)
        let id = try await reader.createPlaylist(named: name, rules: rules)
        if !paths.isEmpty { _ = try await reader.addToPlaylist(id, paths: paths) }
        try await reloadPlaylists()
        await setSource(.playlist(id))
    }

    public func renamePlaylist(_ id: Int64, to name: String) async throws {
        try await reader.renamePlaylist(id, to: name)
        try await reloadPlaylists()
    }

    public func deletePlaylist(_ id: Int64) async throws {
        try await reader.deletePlaylist(id)
        try await reloadPlaylists()
    }

    public func setRules(_ rules: SmartRules, of id: Int64) async throws {
        try await reader.setRules(rules, of: id)
        try await reloadPlaylists()
        if shownPlaylist?.id == id { await refresh() }
    }

    /// Adds the tracks with `ids` to a manual playlist and returns how many it didn't have.
    public func add(_ ids: [Int64], to playlist: Int64) async throws -> Int {
        let paths = try await reader.paths(ids: ids)
        let added = try await reader.addToPlaylist(
            playlist, paths: ids.compactMap { paths[$0] })
        if shownPlaylist?.id == playlist { await refresh() }
        return added
    }

    /// The track IDs at `rows`, in table order.
    public func ids(ofRows rows: IndexSet) -> [Int64] {
        rows.filter { trackIDs.indices.contains($0) }.map { trackIDs[$0] }
    }

    /// Takes the tracks at `rows` out of the manual playlist shown.
    public func removeFromShownPlaylist(rows: IndexSet) async throws {
        guard let playlist = shownPlaylist else { return }
        try await reader.removeFromPlaylist(playlist.id, paths: try await paths(ofRows: rows))
        await refresh()
    }

    /// Moves the tracks with `ids` to just before table row `row`, or to the end of the
    /// playlist past the last row. Only while `canReorder`.
    public func move(_ ids: [Int64], toRow row: Int) async throws {
        guard canReorder, let playlist = shownPlaylist else { return }
        let target = trackIDs.indices.contains(row) ? trackIDs[row] : nil
        let paths = try await reader.paths(ids: ids + (target.map { [$0] } ?? []))
        try await reader.movePlaylistEntries(
            playlist.id, paths: ids.compactMap { paths[$0] }, before: target.flatMap { paths[$0] })
        await refresh()
    }

    /// Rates the tracks at `rows`; 0 stars clears their rating.
    public func rate(rows: IndexSet, stars: Int) async throws {
        try await reader.setRating(stars, paths: try await paths(ofRows: rows))
        await refresh()
    }

    public func recordPlay(_ path: String, at seconds: Double) async throws {
        try await reader.recordPlay(path, at: seconds)
        await refresh()
    }

    public func recordSkip(_ path: String) async throws {
        try await reader.recordSkip(path)
        await refresh()
    }

    private func paths(ofRows rows: IndexSet) async throws -> [String] {
        try await urls(ofRows: rows).map(\.path)
    }

    /// Shows the source before the current one; false when there is none.
    public func back() async -> Bool {
        guard let source = history.back() else { return false }
        await showSource(source)
        return true
    }

    public func forward() async -> Bool {
        guard let source = history.forward() else { return false }
        await showSource(source)
        return true
    }

    private func showSource(_ source: BrowserSource?) async {
        pending.source = source
        await reload(panesFrom: .genre, reason: .user)
    }

    /// Sorts by `column`, ascending, unless the table already sorts by it.
    public func sort(by column: TrackColumn) async {
        guard column != pendingSort.column else { return }
        await setSort(column, ascending: true)
    }

    public func reverseSort() async {
        await setSort(pendingSort.column, ascending: !pendingSort.ascending)
    }

    /// The row of track `id`, clearing the source, panes and search first when they hide it.
    /// Nil when the library has no such track.
    public func reveal(_ id: Int64) async -> Int? {
        if let row = trackIDs.firstIndex(of: id) { return row }
        history.visit(nil)
        pending = TrackFilter()
        await reload(panesFrom: .genre, reason: .user)
        return trackIDs.firstIndex(of: id)
    }

    /// Shows the whole library narrowed to one genre, artist or album, as the palette chooses
    /// one: the other panes are All and the search is cleared.
    public func showOnly(_ pane: Pane, id: Int64) async {
        history.visit(nil)
        pending = TrackFilter()
        switch pane {
        case .genre: pending.genre = id
        case .artist: pending.artist = id
        case .album: pending.album = id
        }
        await reload(panesFrom: .genre, reason: .user)
    }

    /// Every genre, artist and album in the library, for the palette.
    public func allEntries() async throws -> [(Pane, BrowserEntry)] {
        let all = TrackFilter()
        let genres = try await reader.genres(all).map { (Pane.genre, $0) }
        let artists = try await reader.artists(all).map { (Pane.artist, $0) }
        let albums = try await reader.albums(all).map { (Pane.album, $0) }
        return genres + artists + albums
    }

    /// The track list changed during every read of its names.
    public struct NamesKeptChanging: Error, CustomStringConvertible {
        public var description: String { "the track list kept changing while it was read" }
    }

    /// How many times `trackNames` reads before it gives up on a list that keeps changing.
    static let nameReads = 3

    /// The shown tracks' names in table order, read once per change of the list. A list that
    /// changed while they were read is read again.
    public func trackNames() async throws -> [TrackName] {
        for _ in 0..<Self.nameReads {
            if let names, names.applied == applied { return names.list }
            let mine = applied
            let list = try await reader.trackNames(
                filter, sortedBy: sortColumn, ascending: ascending)
            guard mine == applied else { continue }
            names = (mine, list)
            return list
        }
        throw NamesKeptChanging()
    }

    public func setSearch(_ text: String) async {
        pending.search = text
        await reload(panesFrom: nil, reason: .user)
    }

    public func setSort(_ column: TrackColumn, ascending: Bool) async {
        pendingSort = (column, ascending)
        await reload(panesFrom: nil, reason: .user)
    }

    /// Runs every query again after the library changed, keeping each selection that's still
    /// there.
    public func refresh() async {
        await reload(panesFrom: .genre, reason: .libraryChanged)
    }

    /// The queue a double-click plays, as file URLs, and where in it to start. Rows whose track
    /// has gone from the index are left out.
    public func playRequest(selected: IndexSet, clicked: Int) async throws -> PlayRequest? {
        let (rows, first) = playOrder(
            rowCount: trackIDs.count, selected: selected, clicked: clicked)
        let ids = rows.map { trackIDs[$0] }
        let paths = try await reader.paths(ids: ids)
        let firstID = ids[first]
        var urls: [URL] = []
        var start = 0
        for id in ids {
            guard let path = paths[id] else { continue }
            if id == firstID { start = urls.count }
            urls.append(URL(fileURLWithPath: path))
        }
        return urls.isEmpty ? nil : PlayRequest(urls: urls, first: start)
    }

    /// The files of the rows at `rows`, in table order, for "Play Next".
    public func urls(ofRows rows: IndexSet) async throws -> [URL] {
        let ids = rows.filter { trackIDs.indices.contains($0) }.map { trackIDs[$0] }
        let paths = try await reader.paths(ids: ids)
        return ids.compactMap { paths[$0].map(URL.init(fileURLWithPath:)) }
    }

    /// The rows now holding `ids`, for keeping a selection across a reload.
    public func rows(holding ids: Set<Int64>) -> IndexSet {
        guard !ids.isEmpty else { return [] }
        var rows = IndexSet()
        for (row, id) in trackIDs.enumerated() where ids.contains(id) { rows.insert(row) }
        return rows
    }

    /// Runs the queries for the pending filter and sort, reloading the panes from the leftmost
    /// one any pending change needs, and applies the results unless a newer change started.
    private func reload(
        panesFrom pane: Pane?, saved: BrowserState? = nil, reason: BrowserChange.Reason
    ) async {
        generation += 1
        let mine = generation
        if let pane { pendingPanes = min(pendingPanes ?? pane, pane) }
        if let saved { pendingSaved = saved }
        let first = pendingPanes
        let saved = pendingSaved
        let sort = pendingSort
        var next = pending
        var genres = self.genres
        var artists = self.artists
        var albums = self.albums
        do {
            if first == .genre {
                genres = try await reader.genres(next)
                next.genre = resolve(next.genre, saved?.genre, in: genres, "genre")
            }
            if let first, first <= .artist {
                artists = try await reader.artists(next)
                next.artist = resolve(next.artist, saved?.artist, in: artists, "artist")
            }
            if first != nil {
                albums = try await reader.albums(next)
                next.album = resolve(next.album, saved?.album, in: albums, "album")
            }
            let ids = try await reader.trackIDs(
                next, sortedBy: sort.column, ascending: sort.ascending)
            guard mine == generation else { return }
            let previousIDs = trackIDs
            filter = next
            pending = next
            sortColumn = sort.column
            ascending = sort.ascending
            pendingPanes = nil
            pendingSaved = nil
            self.genres = genres
            self.artists = artists
            self.albums = albums
            trackIDs = ids
            applied += 1
            changed(BrowserChange(reason: reason, panes: first != nil, previousIDs: previousIDs))
        } catch {
            guard mine == generation else { return }
            // What failed never showed, so the next change starts from what the views show.
            pending = filter
            pendingSort = (sortColumn, ascending)
            pendingPanes = nil
            pendingSaved = nil
            logger.error("a library query failed: \(error)")
            failed("\(error)")
        }
    }

    /// The selection to keep in a pane that now lists `entries`: the saved name's entry when
    /// loading, otherwise `id` if it's still listed, otherwise All.
    private func resolve(
        _ id: Int64?, _ savedName: String?, in entries: [BrowserEntry], _ pane: String
    ) -> Int64? {
        if let savedName {
            guard let entry = entries.first(where: { $0.name == savedName }) else {
                logger.notice("the saved \(pane) \"\(savedName)\" is gone; showing all")
                return nil
            }
            return entry.id
        }
        guard let id, entries.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func name(_ id: Int64?, in entries: [BrowserEntry]) -> String? {
        id.flatMap { id in entries.first { $0.id == id }?.name }
    }
}

/// The sources shown, oldest first, and where Back and Forward are in them. Nil is the whole
/// library.
public struct SourceHistory: Equatable, Sendable {
    private(set) var visited: [BrowserSource?]
    private(set) var position = 0

    public init(start: BrowserSource? = nil) {
        visited = [start]
    }

    public var canGoBack: Bool { position > 0 }
    public var canGoForward: Bool { position < visited.count - 1 }

    /// A new source drops the ones Forward would have gone to; the source already shown adds
    /// nothing.
    mutating func visit(_ source: BrowserSource?) {
        guard source != visited[position] else { return }
        visited = Array(visited[...position]) + [source]
        position += 1
    }

    /// The source to show, or nil at the start.
    mutating func back() -> BrowserSource?? {
        guard canGoBack else { return nil }
        position -= 1
        return .some(visited[position])
    }

    mutating func forward() -> BrowserSource?? {
        guard canGoForward else { return nil }
        position += 1
        return .some(visited[position])
    }
}

/// What a `BrowserModel` change touched, so the views reload only what they must.
public struct BrowserChange: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case loaded
        /// A search, sort, source or pane change: the table scrolls to its selection.
        case user
        /// A rescan stored or removed tracks: the table keeps its selection and scroll position.
        case libraryChanged
    }

    public var reason: Reason
    /// Whether the panes' entries were reloaded, not just the tracks.
    public var panes: Bool
    /// The track IDs the views showed before, for finding the selected tracks again.
    public var previousIDs: [Int64]
}

/// The selections the window saves: the sidebar's source, and each pane's entry by name, since
/// IDs change when the index is rebuilt. Nil is the whole library, or All.
public struct BrowserState: Equatable, Sendable {
    public var source: BrowserSource?
    public var genre: String?
    public var artist: String?
    public var album: String?

    public init(source: BrowserSource?, genre: String?, artist: String?, album: String?) {
        self.source = source
        self.genre = genre
        self.artist = artist
        self.album = album
    }
}

/// Files to play as a new queue, and the index in it to start at.
public struct PlayRequest: Equatable, Sendable {
    public var urls: [URL]
    public var first: Int
}
