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
    /// Called after each change is applied.
    public var changed: (BrowserChange) -> Void = { _ in }
    /// Called when a query fails. What the browser showed stays.
    public var failed: (String) -> Void = { _ in }

    private let reader: LibraryReader
    /// Counts changes, so a change's results are applied only if no newer one started.
    private var generation = 0

    public init(reader: LibraryReader, sortColumn: TrackColumn, ascending: Bool) {
        self.reader = reader
        self.sortColumn = sortColumn
        self.ascending = ascending
    }

    /// The selections the window saves, by name.
    public var state: BrowserState {
        BrowserState(
            source: filter.folder, genre: name(filter.genre, in: genres),
            artist: name(filter.artist, in: artists), album: name(filter.album, in: albums))
    }

    /// Loads the panes and tracks, selecting what `saved` names where it still exists.
    public func load(_ saved: BrowserState) async {
        var next = TrackFilter(folder: saved.source)
        next.search = filter.search
        await reload(next, panesFrom: .genre, saved: saved, reason: .loaded)
    }

    /// Selects an entry of `pane` by ID, or All for nil. The panes to its right are narrowed, and
    /// lose a selection they no longer list.
    public func select(_ pane: Pane, id: Int64?) async {
        var next = filter
        switch pane {
        case .genre: next.genre = id
        case .artist: next.artist = id
        case .album: next.album = id
        }
        let following = Pane(rawValue: pane.rawValue + 1)
        await reload(next, panesFrom: following, reason: .user)
    }

    /// Shows one watched folder, or the whole library for nil.
    public func setSource(_ folder: String?) async {
        var next = filter
        next.folder = folder
        await reload(next, panesFrom: .genre, reason: .user)
    }

    public func setSearch(_ text: String) async {
        var next = filter
        next.search = text
        await reload(next, panesFrom: nil, reason: .user)
    }

    public func setSort(_ column: TrackColumn, ascending: Bool) async {
        sortColumn = column
        self.ascending = ascending
        await reload(filter, panesFrom: nil, reason: .user)
    }

    /// Runs every query again after the library changed, keeping each selection that's still
    /// there.
    public func refresh() async {
        await reload(filter, panesFrom: .genre, reason: .libraryChanged)
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

    private func reload(
        _ proposed: TrackFilter, panesFrom first: Pane?, saved: BrowserState? = nil,
        reason: BrowserChange.Reason
    ) async {
        generation += 1
        let mine = generation
        var next = proposed
        var genres = self.genres
        var artists = self.artists
        var albums = self.albums
        do {
            if let first, first <= .genre {
                genres = try await reader.genres(next)
                next.genre = resolve(next.genre, saved?.genre, in: genres, "genre")
            }
            if let first, first <= .artist {
                artists = try await reader.artists(next)
                next.artist = resolve(next.artist, saved?.artist, in: artists, "artist")
            }
            if let first, first <= .album {
                albums = try await reader.albums(next)
                next.album = resolve(next.album, saved?.album, in: albums, "album")
            }
            let ids = try await reader.trackIDs(
                next, sortedBy: sortColumn, ascending: ascending)
            guard mine == generation else { return }
            filter = next
            self.genres = genres
            self.artists = artists
            self.albums = albums
            trackIDs = ids
            changed(BrowserChange(reason: reason, panes: first != nil))
        } catch {
            guard mine == generation else { return }
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
}

/// The selections the window saves: the sidebar's watched folder, and each pane's entry by name,
/// since IDs change when the index is rebuilt. Nil is the whole library, or All.
public struct BrowserState: Equatable, Sendable {
    public var source: String?
    public var genre: String?
    public var artist: String?
    public var album: String?

    public init(source: String?, genre: String?, artist: String?, album: String?) {
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
