import Foundation
import Library
import Log
import Settings

private let logger = moduleLogger()

/// The browser's logic, apart from AppKit: the sidebar's source, the three columns, the search
/// and the sort decide which track IDs the table shows, and in what order.
///
/// Every query runs on the `LibraryReader`, off the main thread. A change that a newer one
/// overtakes while its queries run is dropped, so the last keystroke or click wins.
@MainActor
public final class BrowserModel {
    /// The genres, artists and albums the palette lists and `PlayQuery` names, each shown by a
    /// browser column grouping as `groupings` says.
    public enum Pane: Int, CaseIterable, Sendable {
        case genre, artist, album

        /// The groupings whose column selects one of these by ID, the first when no column
        /// shows one.
        var groupings: [BrowserGrouping] {
            switch self {
            case .genre: [.genres]
            case .artist: [.artists]
            case .album: [.albums, .albumsByYear]
            }
        }
    }

    public private(set) var filter = TrackFilter()
    /// What each browser column groups by, left to right.
    public private(set) var columns = BrowserColumn.defaults.map(\.grouping)
    /// Each column's entries.
    public private(set) var entries: [[ColumnEntry]] = Array(
        repeating: [], count: BrowserColumn.count)
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
    private var pendingColumns = BrowserColumn.defaults.map(\.grouping)
    /// The leftmost column a change not yet applied reloads from, and the saved selections a
    /// load not yet applied restores.
    private var pendingPanes: Int?
    private var pendingSaved: BrowserState?
    /// Counts applied changes, so names read for one list aren't used for the next.
    private var applied = 0
    private var names: (applied: Int, list: [TrackName])?
    /// The sources the sidebar showed, for Back and Forward.
    public private(set) var history = SourceHistory()
    /// The source a change not yet applied visits, so History records only sources that showed.
    private var pendingVisit: BrowserSource?? = .none
    /// The sort the table had before a source with its own sort replaced it, to go back to.
    private var sortBeforeDefault: (column: TrackColumn, ascending: Bool)?
    /// Entries of the shown manual playlist with no track in the library, which it can't list.
    private(set) var missingTracks = 0

    /// `groupByAlbumArtist` is `library.groupByAlbumArtist`.
    public init(
        reader: LibraryReader, sortColumn: TrackColumn, ascending: Bool, groupByAlbumArtist: Bool
    ) {
        self.reader = reader
        self.sortColumn = sortColumn
        self.ascending = ascending
        pendingSort = (sortColumn, ascending)
        filter.groupByAlbumArtist = groupByAlbumArtist
        pending = filter
    }

    /// No source, panes or search, grouped as the setting says.
    private var everything: TrackFilter {
        TrackFilter(groupByAlbumArtist: pending.groupByAlbumArtist)
    }

    /// Whether the table shows, or is about to show, every track: no source, pane or search
    /// narrows it.
    var showsEverything: Bool { pending == everything }

    /// Follows a change of `library.groupByAlbumArtist`: the Artist pane lists the other kind
    /// of artist, keeping its selection where the same artist is listed.
    public func setGroupByAlbumArtist(_ on: Bool) async {
        guard on != pending.groupByAlbumArtist else { return }
        pending.groupByAlbumArtist = on
        await reload(panesFrom: 0, reason: .user)
    }

    /// The source and columns the window saves, each selection by name.
    public var state: BrowserState {
        BrowserState(
            source: filter.source,
            columns: zip(columns, entries).map { grouping, entries in
                let value = filter.selections[grouping]
                return BrowserColumn(
                    grouping: grouping,
                    selection: entries.first { $0.value == value }?.savedName)
            })
    }

    /// Loads the playlists, panes and tracks, selecting what `saved` names where it still
    /// exists.
    public func load(_ saved: BrowserState) async {
        var saved = saved
        do {
            playlists = try await reader.playlists()
            if case .playlist(let id) = saved.source, !playlists.contains(where: { $0.id == id }) {
                logger.notice("the saved playlist \(id) is gone; showing the library")
                saved.source = nil
            }
        } catch {
            // The saved source stays: a playlist that couldn't be listed may still be there.
            logger.error("couldn't read the playlists: \(error)")
            failed("couldn't read the playlists: \(error)")
        }
        history = SourceHistory(start: saved.source)
        pending = TrackFilter(
            source: saved.source, search: pending.search,
            groupByAlbumArtist: pending.groupByAlbumArtist)
        pendingColumns = saved.columns.map(\.grouping)
        await reload(panesFrom: 0, saved: saved, reason: .loaded)
    }

    /// Selects an entry of the column grouping by `grouping`, or All for nil. The columns to its
    /// right are narrowed, and lose a selection they no longer list. Ignored when a change
    /// still loading has taken the grouping out of the columns, since `value` was one of its
    /// entries, and an ID means nothing in another grouping.
    func select(_ grouping: BrowserGrouping, _ value: BrowserValue?) async {
        guard let column = pendingColumns.firstIndex(of: grouping) else { return }
        pending.selections[grouping] = value
        let next = column + 1
        await reload(panesFrom: next < BrowserColumn.count ? next : nil, reason: .user)
    }

    /// Has the column at `column` group by `grouping`, at All. A grouping another column shows
    /// trades places with the column's own, so no two columns show the same.
    func setGrouping(_ grouping: BrowserGrouping, ofColumn column: Int) async {
        let current = pendingColumns[column]
        guard grouping != current else { return }
        var first = column
        if let other = pendingColumns.firstIndex(of: grouping) {
            pendingColumns[other] = current
            first = min(first, other)
        }
        pendingColumns[column] = grouping
        pending.selections[current] = nil
        pending.selections[grouping] = nil
        await reload(panesFrom: first, reason: .user)
    }

    /// Selects All in every column, for hiding them, so nothing hidden narrows the table.
    /// Columns already at All run no query and redraw nothing.
    func clearPanes() async {
        guard !pending.selections.isEmpty else { return }
        pending.selections = [:]
        await reload(panesFrom: 0, reason: .user)
    }

    /// Shows the whole library with no pane or search narrowing it, as a step Back can undo.
    /// Returns false, running no query and redrawing nothing, when that already shows.
    func showAll() async -> Bool {
        guard pending != everything else { return false }
        showEverything()
        await reload(panesFrom: 0, reason: .user)
        return true
    }

    /// Shows a watched folder, a playlist or History, or the whole library for nil, as a step
    /// Back can undo.
    func setSource(_ source: BrowserSource?) async {
        pendingVisit = .some(source)
        await showSource(source)
    }

    /// A manual playlist opens in its own order, and History with the latest play first. Other
    /// sources keep the sort the table has, and leaving one of those two puts back the sort it
    /// replaced, unless the user chose another meanwhile.
    func defaultSort(_ source: BrowserSource?) -> (column: TrackColumn, ascending: Bool)? {
        switch source {
        case .playlist(let id):
            playlists.first { $0.id == id }?.isManual == true ? (.playlistOrder, true) : nil
        case .history: (.lastPlayed, false)
        case .timeline, .health, nil: nil
        }
    }

    /// What the table says in place of rows: History's before anything has played. Nil while
    /// it lists rows, and while a search hides them.
    var emptyText: String? {
        filter.source == .history && trackIDs.isEmpty && filter.search.isEmpty
            ? "Nothing played yet" : nil
    }

    /// The playlist the sidebar shows, if it shows one.
    public var shownPlaylist: Playlist? {
        guard case .playlist(let id) = filter.source else { return nil }
        return playlists.first { $0.id == id }
    }

    /// Whether dragging rows moves them: only in a manual playlist shown in its own order.
    var canReorder: Bool {
        shownPlaylist?.isManual == true && sortColumn == .playlistOrder && ascending
    }

    // MARK: Playlist and stats edits. Each refreshes what it changed.

    /// Reads the playlists again. If the one shown has gone, the library is shown.
    func reloadPlaylists() async throws {
        playlists = try await reader.playlists()
        let ids = Set(playlists.map(\.id))
        history.remove { source in
            if case .playlist(let id) = source { return !ids.contains(id) }
            return false
        }
        if case .playlist(let id) = pending.source, !ids.contains(id) {
            await setSource(nil)
        }
    }

    /// Makes a playlist, manual unless `rules` are given, holding the tracks `trackIDs`, and
    /// shows it.
    public func createPlaylist(named name: String, rules: SmartRules?, trackIDs: [Int64] = [])
        async throws
    {
        let id = try await reader.createPlaylist(named: name, rules: rules)
        if !trackIDs.isEmpty { _ = try await reader.addToPlaylist(id, trackIDs: trackIDs) }
        try await reloadPlaylists()
        await setSource(.playlist(id))
    }

    /// Makes a manual playlist of the tracks the playlist file at `url` names, and shows it.
    func importPlaylist(from url: URL) async throws -> PlaylistImport {
        let result = try await reader.importPlaylist(from: url)
        try await reloadPlaylists()
        await setSource(.playlist(result.playlistID))
        return result
    }

    /// What importing `library` would change.
    func importPlan(_ library: PlayerLibrary, prefix: PathPrefix?) async throws -> ImportPlan {
        try await reader.importPlan(library, prefix: prefix)
    }

    /// Writes an import, and shows what it changed.
    func applyImport(_ library: PlayerLibrary, prefix: PathPrefix?) async throws -> ImportPlan {
        let plan = try await reader.applyImport(library, prefix: prefix)
        try await reloadPlaylists()
        await refresh()
        return plan
    }

    /// Writes the playlist `id` to `url` as M3U8, in the table's sort.
    func exportPlaylist(_ id: Int64, to url: URL, relativePaths: Bool) async throws -> (
        written: Int, unwritable: [String]
    ) {
        try await reader.exportPlaylist(
            id, sortedBy: sortColumn, ascending: ascending,
            groupByAlbumArtist: filter.groupByAlbumArtist, to: url, relativePaths: relativePaths)
    }

    public func renamePlaylist(_ id: Int64, to name: String) async throws {
        try await reader.renamePlaylist(id, to: name)
        try await reloadPlaylists()
    }

    /// Copies `playlist` under the name `PlaylistName.copy` gives, and shows the copy.
    func duplicatePlaylist(_ playlist: Playlist) async throws {
        let copy = try await reader.duplicatePlaylist(
            playlist.id,
            named: PlaylistName.copy(of: playlist.name, taken: playlists.map(\.name)))
        try await reloadPlaylists()
        await setSource(.playlist(copy))
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
        let added = try await reader.addToPlaylist(playlist, trackIDs: ids)
        if shownPlaylist?.id == playlist { await refresh() }
        return added
    }

    /// The track IDs at `rows`, in table order.
    public func ids(ofRows rows: IndexSet) -> [Int64] {
        rows.filter { trackIDs.indices.contains($0) }.map { trackIDs[$0] }
    }

    /// Takes the tracks at `rows` out of the manual playlist shown.
    func removeFromShownPlaylist(rows: IndexSet) async throws {
        guard let playlist = shownPlaylist else { return }
        try await reader.removeFromPlaylist(playlist.id, trackIDs: ids(ofRows: rows))
        await refresh()
    }

    /// Moves the tracks with `ids` to just before table row `row`, or to the end of the
    /// playlist past the last row. Only while `canReorder`.
    public func move(_ ids: [Int64], toRow row: Int) async throws {
        guard canReorder, let playlist = shownPlaylist else { return }
        let target = trackIDs.indices.contains(row) ? trackIDs[row] : nil
        try await reader.movePlaylistEntries(playlist.id, trackIDs: ids, before: target)
        await refresh()
    }

    /// Rates the tracks `trackIDs`; 0 stars clears their rating.
    public func rate(_ trackIDs: [Int64], stars: Int) async throws {
        try await reader.setRating(stars, trackIDs: trackIDs)
        await refresh()
    }

    func toggle(_ opinion: TrackOpinion, _ trackIDs: [Int64]) async throws {
        try await reader.toggle(opinion, trackIDs: trackIDs)
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
        changeSort(from: pending.source, to: source)
        pending.source = source
        await reload(panesFrom: 0, reason: .user)
    }

    private func changeSort(from old: BrowserSource?, to new: BrowserSource?) {
        let leaving = defaultSort(old)
        if let leaving {
            if pendingSort == leaving, let sortBeforeDefault { pendingSort = sortBeforeDefault }
            sortBeforeDefault = nil
        }
        if let entering = defaultSort(new) {
            if sortBeforeDefault == nil { sortBeforeDefault = pendingSort }
            pendingSort = entering
        } else if pendingSort.column == .playlistOrder {
            // Playlist order means nothing here, as after the shown playlist was deleted.
            let table = AppState().trackTable.defaultValue
            pendingSort = sortBeforeDefault ?? (table.sortColumn, table.sortAscending)
            sortBeforeDefault = nil
        }
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
        showEverything()
        await reload(panesFrom: 0, reason: .user)
        return trackIDs.firstIndex(of: id)
    }

    /// Shows the whole library narrowed to one genre, artist or album, as the palette chooses
    /// one: the other columns are All and the search is cleared. False, changing nothing, when
    /// no column shows that kind of entry.
    public func showOnly(_ pane: Pane, id: Int64) async -> Bool {
        guard let grouping = shownGrouping(pane) else { return false }
        showEverything()
        pending.selections[grouping] = .id(id)
        await reload(panesFrom: 0, reason: .user)
        return true
    }

    /// The grouping of the column that shows `pane`'s entries, if one does.
    private func shownGrouping(_ pane: Pane) -> BrowserGrouping? {
        pendingColumns.first { pane.groupings.contains($0) }
    }

    /// Shows the whole library, as `showAll` does, and returns the row of the first track it
    /// lists of the genre, artist or album `id`, as the palette goes to one; nil when it lists
    /// none.
    func showFirstTrack(of pane: Pane, id: Int64) async throws -> Int? {
        if pending != everything {
            showEverything()
            await reload(panesFrom: 0, reason: .user)
        }
        var entry = everything
        narrow(&entry, pane, to: id)
        let ids = Set(try await reader.trackIDs(entry, sortedBy: sortColumn, ascending: ascending))
        return trackIDs.firstIndex(where: ids.contains)
    }

    /// Shows what `query` names in the whole library, and returns all of it to play from the
    /// top. An entry's name matches ignoring case and accents; one the library has under two
    /// artists is refused, naming them, since playing either would be a guess.
    public func show(_ query: PlayQuery) async throws -> PlayRequest {
        switch query {
        case .search(let text):
            showEverything()
            pending.search = text
        case .entry(let pane, let name):
            let matches = try await allEntries().filter {
                $0.0 == pane && TypeSelect.fold($0.1.name) == TypeSelect.fold(name)
            }.map(\.1)
            guard let entry = matches.first else { throw PlayQueryError.noEntry(pane, name) }
            guard matches.count == 1 else {
                throw PlayQueryError.several(pane, name, artists: matches.map(\.artist))
            }
            showEverything()
            narrow(&pending, pane, to: entry.id)
        }
        await reload(panesFrom: 0, reason: .user)
        guard !trackIDs.isEmpty, let request = try await playRequest(selected: [], clicked: 0)
        else { throw PlayQueryError.nothingMatches(query) }
        return request
    }

    /// The whole library, once the next reload shows it: no source, panes or search.
    private func showEverything() {
        pendingVisit = .some(nil)
        changeSort(from: pending.source, to: nil)
        pending = everything
    }

    /// Narrows `filter` to one entry of `pane`, in the column that shows that kind, or else
    /// in none.
    private func narrow(_ filter: inout TrackFilter, _ pane: Pane, to id: Int64) {
        filter.selections[shownGrouping(pane) ?? pane.groupings[0]] = .id(id)
    }

    /// Every genre, artist and album in the library, for the palette.
    public func allEntries() async throws -> [(Pane, BrowserEntry)] {
        let all = everything
        let genres = try await reader.genres(all).map { (Pane.genre, $0) }
        let artists = try await reader.artists(all).map { (Pane.artist, $0) }
        let albums = try await reader.albums(all).map { (Pane.album, $0) }
        return genres + artists + albums
    }

    /// Every track's name in the library, whatever shows, for Go to Item.
    public func allTrackNames() async throws -> [TrackName] {
        try await reader.trackNames(everything, sortedBy: .artist, ascending: true)
    }

    /// The track list changed during every read of its names.
    struct NamesKeptChanging: Error, CustomStringConvertible {
        var description: String { "the track list kept changing while it was read" }
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

    /// Text the search already holds, as Esc in an empty field sends, runs no query and redraws
    /// nothing.
    public func setSearch(_ text: String) async {
        guard text != pending.search else { return }
        pending.search = text
        await reload(panesFrom: nil, reason: .user)
    }

    public func setSort(_ column: TrackColumn, ascending: Bool) async {
        pendingSort = (column, ascending)
        await reload(panesFrom: nil, reason: .sorted)
    }

    /// Runs every query again after the library changed, keeping each selection that's still
    /// there.
    package func refresh() async {
        await reload(panesFrom: 0, reason: .libraryChanged)
    }

    /// The queue a double-click plays, as file URLs, and where in it to start. Rows whose track
    /// has gone from the index are left out.
    func playRequest(selected: IndexSet, clicked: Int) async throws -> PlayRequest? {
        let (rows, first) = playOrder(
            rowCount: trackIDs.count, selected: selected, clicked: clicked)
        return try await Self.request(ids: rows.map { trackIDs[$0] }, first: first, reader: reader)
    }

    /// What a double-click plays, split so the clicked track starts before the queue behind it
    /// is read: one file lookup now, and the rest, which is a lookup per row of the table, left
    /// to `PlayStart.request`.
    public func playStart(selected: IndexSet, clicked: Int) async throws -> PlayStart? {
        let (rows, first) = playOrder(
            rowCount: trackIDs.count, selected: selected, clicked: clicked)
        let ids = rows.map { trackIDs[$0] }
        let reader = reader
        guard let path = try await reader.paths(ids: [ids[first]])[ids[first]] else {
            // The clicked track has gone from the index: the queue says where playback starts.
            guard let request = try await Self.request(ids: ids, first: first, reader: reader)
            else { return nil }
            return PlayStart(url: request.urls[request.first]) { request }
        }
        return PlayStart(url: URL(fileURLWithPath: path, isDirectory: false)) {
            guard let request = try await Self.request(ids: ids, first: first, reader: reader)
            else { throw PlayStartError.noTracks }
            return request
        }
    }

    nonisolated static func request(ids: [Int64], first: Int, reader: LibraryReader)
        async throws -> PlayRequest?
    {
        let paths = try await reader.paths(ids: ids)
        var urls: [URL] = []
        urls.reserveCapacity(paths.count)
        var start = 0
        for (row, id) in ids.enumerated() {
            if row == first { start = urls.count }
            guard let path = paths[id] else { continue }
            urls.append(URL(fileURLWithPath: path, isDirectory: false))
        }
        return urls.isEmpty ? nil : PlayRequest(urls: urls, first: start)
    }

    /// The files of the rows at `rows`, in table order, for "Play Next".
    public func urls(ofRows rows: IndexSet) async throws -> [URL] {
        let ids = rows.filter { trackIDs.indices.contains($0) }.map { trackIDs[$0] }
        let paths = try await reader.paths(ids: ids)
        return ids.compactMap { paths[$0].map { URL(fileURLWithPath: $0, isDirectory: false) } }
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
        panesFrom pane: Int?, saved: BrowserState? = nil, reason: BrowserChange.Reason
    ) async {
        generation += 1
        let mine = generation
        if let pane { pendingPanes = min(pendingPanes ?? pane, pane) }
        if let saved { pendingSaved = saved }
        let first = pendingPanes
        let saved = pendingSaved
        let sort = pendingSort
        let columns = pendingColumns
        var next = pending
        var entries = self.entries
        // A newer change, such as a keystroke, doesn't wait behind a refresh's queries.
        let reader = reason == .libraryChanged ? reader.refreshes : reader
        do {
            // The timeline lists plays, which its own model pages through.
            let tracks = next.source != .timeline
            for column in (first ?? BrowserColumn.count)..<BrowserColumn.count {
                let grouping = columns[column]
                // The selections of this column and those to its right don't narrow it.
                entries[column] =
                    tracks
                    ? try await reader.columnEntries(
                        grouping, next, ignoring: Set(columns[column...])) : []
                next.selections[grouping] = resolve(
                    next.selections[grouping], saved?.columns[column].selection,
                    in: entries[column], grouping)
            }
            let ids =
                tracks
                ? try await reader.trackIDs(next, sortedBy: sort.column, ascending: sort.ascending)
                : []
            var missing = 0
            if case .playlist(let id) = next.source,
                playlists.first(where: { $0.id == id })?.isManual == true
            {
                missing = try await reader.missingEntryCount(id)
            }
            guard mine == generation else { return }
            if case .some(let source) = pendingVisit { history.visit(source) }
            pendingVisit = .none
            missingTracks = missing
            let previousIDs = trackIDs
            // A rescan that left every column's entries as they were leaves the panes alone.
            let panesChanged =
                first != nil
                && (reason != .libraryChanged || entries != self.entries
                    || columns != self.columns)
            filter = next
            pending = next
            sortColumn = sort.column
            ascending = sort.ascending
            pendingPanes = nil
            pendingSaved = nil
            self.columns = columns
            self.entries = entries
            trackIDs = ids
            applied += 1
            changed(BrowserChange(reason: reason, panes: panesChanged, previousIDs: previousIDs))
        } catch {
            guard mine == generation else { return }
            // What failed never showed, so the next change starts from what the views show.
            pending = filter
            pendingSort = (sortColumn, ascending)
            pendingColumns = self.columns
            pendingPanes = nil
            pendingSaved = nil
            pendingVisit = .none
            logger.error("a library query failed: \(error)")
            failed("\(error)")
        }
    }

    /// The selection to keep in a column that now lists `entries`: the saved name's entry when
    /// loading, otherwise `value` if it's still listed, otherwise All.
    private func resolve(
        _ value: BrowserValue?, _ savedName: String?, in entries: [ColumnEntry],
        _ grouping: BrowserGrouping
    ) -> BrowserValue? {
        if let savedName {
            let saved = BrowserValue.text(savedName)
            guard
                let entry = entries.first(where: {
                    $0.savedName == savedName
                        || grouping.sameEntry(.text($0.savedName), saved)
                })
            else {
                logger.notice(
                    "the saved \(grouping.header.lowercased()) \"\(savedName)\" is gone; showing all"
                )
                return nil
            }
            return entry.value
        }
        // The entry's spelling, which can change within a group that ignores case.
        guard let value else { return nil }
        return entries.first { grouping.sameEntry($0.value, value) }?.value
    }
}

/// The sources shown, oldest first, and where Back and Forward are in them. Nil is the whole
/// library.
public struct SourceHistory: Equatable, Sendable {
    private(set) var visited: [BrowserSource?]
    private(set) var position = 0

    init(start: BrowserSource? = nil) {
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

    /// Forgets the sources `gone` picks, such as deleted playlists, and the repeats that
    /// leaves, keeping the place at the nearest source before it that stays.
    mutating func remove(_ gone: (BrowserSource?) -> Bool) {
        var kept: [BrowserSource?] = []
        var place = 0
        for (index, source) in visited.enumerated() where !gone(source) {
            if kept.last != .some(source) { kept.append(source) }
            if index <= position { place = kept.count - 1 }
        }
        visited = kept.isEmpty ? [nil] : kept
        position = place
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
        /// A search, source or pane change: the table centers its selection.
        case user
        /// A new sort: the table centers its selection.
        case sorted
        /// A rescan stored or removed tracks: the table keeps its selection and scroll position.
        case libraryChanged
    }

    public var reason: Reason
    /// Whether the panes' entries were reloaded, not just the tracks.
    var panes: Bool
    /// The track IDs the views showed before, for finding the selected tracks again.
    var previousIDs: [Int64]
}

/// What the window saves of the browser: the sidebar's source, nil for the whole library, and
/// the columns with their selections.
public struct BrowserState: Equatable, Sendable {
    public var source: BrowserSource?
    public var columns: [BrowserColumn]

    public init(source: BrowserSource?, columns: [BrowserColumn] = BrowserColumn.defaults) {
        self.source = source
        self.columns = columns
    }
}

/// A track to start playing at once, and the queue it belongs to, read after it starts.
public struct PlayStart: Sendable {
    public var url: URL
    /// The whole queue, with `url` at its `first`. Runs off the main actor.
    public var request: @Sendable () async throws -> PlayRequest
}

enum PlayStartError: Error, CustomStringConvertible {
    case noTracks

    var description: String { "none of the tracks to play are in the library any more" }
}

/// Files to play as a new queue, and the index in it to start at.
public struct PlayRequest: Equatable, Sendable {
    public var urls: [URL]
    public var first: Int
}
