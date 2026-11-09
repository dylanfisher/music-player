import Foundation
import Library
import Log
import Playback
import Settings

private let logger = moduleLogger()

/// The browser's logic, apart from AppKit: the sidebar's source, the columns, the search
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
        repeating: [], count: BrowserColumn.defaults.count)
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
    /// The list the last play from the table queued, as its track IDs in play order, its
    /// queue, and the library change it was read after, so a play from the same list can keep
    /// the queue the engine plays (ADR 0097, 0104).
    private var lastQueued: (ids: [Int64], queue: ListQueue, readAt: Int)?
    /// Counts library changes. A kept queue read before the latest one is read again, and
    /// a play keeps it only once its files are found where they were.
    private var queuedGeneration = 0
    /// The sources the sidebar showed and the plays from the browser, for Back and Forward.
    private(set) var history = StepHistory(start: WindowPlace(filter: TrackFilter()))
    /// The source the track of the play state saved at quit was played from, which stands for
    /// a play's until the history has one (ADR 0095).
    var resumedFrom: TrackFilter?
    /// The track table's selections, for Undo Selection and Redo Selection.
    private(set) var selections = SelectionHistory()
    /// The wait that makes the pending selection a step.
    private var settling: Task<Void, Never>?
    /// The shown list's selected tracks and scroll, which a step keeps with the filter.
    var listPlace: () -> (selection: Set<Int64>, scroll: WindowPlace.Scroll?) = { ([], nil) }
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
    private var everything: TrackFilter { Self.everything(like: pending) }

    /// No source, panes or search, grouped as `filter` is.
    private static func everything(like filter: TrackFilter) -> TrackFilter {
        TrackFilter(groupByAlbumArtist: filter.groupByAlbumArtist)
    }

    /// Whether the table shows, or is about to show, every track: no source, pane or search
    /// narrows it.
    var showsEverything: Bool { pending == everything }

    private static func isEverything(_ filter: TrackFilter) -> Bool {
        filter == everything(like: filter)
    }

    /// Follows a change of `library.groupByAlbumArtist`: the Artist pane lists the other kind
    /// of artist, keeping its selection where the same artist is listed.
    public func setGroupByAlbumArtist(_ on: Bool) async {
        guard on != pending.groupByAlbumArtist else { return }
        pending.groupByAlbumArtist = on
        await reload(panesFrom: 0, reason: .user)
    }

    /// The source, columns and search the window saves, each selection by name, and the sort
    /// chosen in a source with its own.
    public var state: BrowserState {
        let source = filter.source
        let ownSort = defaultSort(source)
        return BrowserState(
            source: source,
            columns: zip(columns, entries).map { grouping, entries in
                let value = filter.selections[grouping]
                return BrowserColumn(
                    grouping: grouping,
                    selection: entries.first { $0.value == value }?.savedName)
            },
            sourceSort: source.flatMap { source in
                guard let ownSort, ownSort != (sortColumn, ascending) else { return nil }
                return SourceSort(source: source, column: sortColumn, ascending: ascending)
            }, search: filter.search)
    }

    /// The sort of the sources without one of their own: the table's, which a source with its
    /// own replaced while it shows. The window saves this one with the columns.
    var tableSort: (column: TrackColumn, ascending: Bool) {
        sortBeforeDefault ?? (sortColumn, ascending)
    }

    /// Loads the playlists, panes and tracks, selecting what `saved` names where it still
    /// exists. A saved health check shows the library: Library Health opens from its command,
    /// not at launch (ADR 0099).
    public func load(_ saved: BrowserState) async {
        var saved = saved
        if case .health = saved.source {
            logger.notice("the saved source is a health check; showing the library")
            saved.source = nil
        }
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
        history = StepHistory(
            start: WindowPlace(
                filter: TrackFilter(
                    source: saved.source, groupByAlbumArtist: pending.groupByAlbumArtist)))
        // The source opens in its own sort, as a click on it does, or in the one chosen in it.
        changeSort(from: pending.source, to: saved.source)
        if let sort = saved.sourceSort, sort.source == saved.source, defaultSort(sort.source) != nil
        {
            pendingSort = (sort.column, sort.ascending)
        }
        pending = TrackFilter(
            source: saved.source, search: saved.search,
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
        await reload(panesFrom: next < pendingColumns.count ? next : nil, reason: .user)
    }

    /// Has the column at `column` group by `grouping`, at All. A grouping another column shows
    /// trades places with the column's own, so no two columns show the same.
    func setGrouping(_ grouping: BrowserGrouping, ofColumn column: Int) async {
        await setGroupings(groupings(choosing: grouping, ofColumn: column))
    }

    /// The columns' groupings once the column at `column` groups by `grouping`: one another
    /// column shows trades places with the column's own.
    func groupings(choosing grouping: BrowserGrouping, ofColumn column: Int) -> [BrowserGrouping] {
        var next = pendingColumns
        if let other = next.firstIndex(of: grouping) { next[other] = next[column] }
        next[column] = grouping
        return next
    }

    /// The columns' groupings with a column added right of `column`, grouping by the first
    /// grouping no column shows; nil when the browser has as many columns as it may.
    func groupings(addingAfter column: Int) -> [BrowserGrouping]? {
        guard pendingColumns.count < BrowserColumn.counts.upperBound,
            let grouping = BrowserGrouping.allCases.first(where: { !pendingColumns.contains($0) })
        else { return nil }
        var next = pendingColumns
        next.insert(grouping, at: min(column + 1, next.count))
        return next
    }

    /// The columns' groupings without the column at `column`; nil when it's the only one.
    func groupings(removing column: Int) -> [BrowserGrouping]? {
        guard pendingColumns.count > BrowserColumn.counts.lowerBound,
            pendingColumns.indices.contains(column)
        else { return nil }
        var next = pendingColumns
        next.remove(at: column)
        return next
    }

    /// Has the columns group by `groupings`, as the config file says (ADR 0106). Each column
    /// whose grouping changes, or that's added or taken away, goes to All, and the columns
    /// from the first of them reload.
    func setGroupings(_ groupings: [BrowserGrouping]) async {
        let changed = (0..<max(groupings.count, pendingColumns.count)).filter {
            groupings.indices.contains($0) != pendingColumns.indices.contains($0)
                || groupings[$0] != pendingColumns[$0]
        }
        guard let first = changed.first else { return }
        for column in changed {
            if pendingColumns.indices.contains(column) {
                pending.selections[pendingColumns[column]] = nil
            }
            if groupings.indices.contains(column) { pending.selections[groupings[column]] = nil }
        }
        pendingColumns = groupings
        // Past the last column, as when it was taken away, the last reloads, so the panes do.
        await reload(panesFrom: max(0, min(first, groupings.count - 1)), reason: .user)
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

    /// Whether `source` can still be shown: a playlist that hasn't been deleted, or any other.
    func exists(_ source: BrowserSource?) -> Bool {
        guard case .playlist(let id) = source else { return true }
        return playlists.contains { $0.id == id }
    }

    /// A manual playlist opens in its own order, and History with the latest play first. Other
    /// sources keep the sort the table has, and leaving one of those two puts back the sort it
    /// replaced, unless the user chose another meanwhile.
    func defaultSort(_ source: BrowserSource?) -> (column: TrackColumn, ascending: Bool)? {
        switch source {
        case .playlist(let id):
            playlists.first { $0.id == id }?.isManual == true ? (.playlistOrder, true) : nil
        case .history: (.lastPlayed, false)
        // The tracks played most first, as the panel ranks them.
        case .stats: (.playCount, false)
        case .timeline, .plays, .health, nil: nil
        }
    }

    /// What the browser showed when the playback in place started, which Show Current Track
    /// goes back to: the history's latest play at or before its place, else the resumed one's.
    var playSource: TrackFilter? { history.playSource ?? resumedFrom }

    /// The order `source` lists its tracks in for a queue: its own sort, or else the table's,
    /// never the playlist order a playlist shown now has.
    func queueSort(for source: BrowserSource?) -> (column: TrackColumn, ascending: Bool) {
        if let sort = defaultSort(source) { return sort }
        let sort = tableSort
        guard sort.column == .playlistOrder else { return sort }
        let table = AppState().trackTable.defaultValue
        return (table.sortColumn, table.sortAscending)
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
        let gone = { (source: BrowserSource?) in
            if case .playlist(let id) = source { return !ids.contains(id) }
            return false
        }
        history.remove(gone)
        selections.remove(gone)
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
        await refreshEdited()
    }

    func toggle(_ opinion: TrackOpinion, _ trackIDs: [Int64]) async throws {
        try await reader.toggle(opinion, trackIDs: trackIDs)
        await refreshEdited()
    }

    public func recordPlay(_ path: String, at seconds: Double) async throws {
        try await reader.recordPlay(path, at: seconds)
        await refreshEdited()
    }

    public func recordSkip(_ path: String) async throws {
        try await reader.recordSkip(path)
        await refreshEdited()
    }

    /// The window as it is now, as a step keeps it.
    var place: WindowPlace {
        let list = listPlace()
        return WindowPlace(filter: filter, selection: list.selection, scroll: list.scroll)
    }

    /// Takes a step for a play started from the window, replacing `replaced`.
    func recordPlay(_ played: PlaybackSpot, replacing replaced: PlaybackSpot) {
        history.play(played, replacing: replaced, from: place)
    }

    /// Notes the window as the selection that becomes a step once it stays put for
    /// `SelectionHistory.settleDelay`, after the track table's selection changed.
    func recordSelection() {
        selections.note(place)
        settling?.cancel()
        settling = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(SelectionHistory.settleDelay * 1e9))
            } catch {
                return
            }
            self?.settleSelection()
        }
    }

    /// Makes the pending selection a step now, as the delay does.
    func settleSelection() {
        settling?.cancel()
        settling = nil
        selections.settle()
    }

    var canUndoSelection: Bool { selections.canUndo(from: place) }

    /// The selection step to show for Undo Selection, nil when there's none.
    func undoSelection() -> WindowPlace? { selections.undo(from: place) }

    func redoSelection() -> WindowPlace? { selections.redo(from: place) }

    /// Moves to the step before, leaving the current one as the window and `playing` have it.
    /// Nil at the first step. `show` then shows the move's window.
    func back(playing: PlaybackSpot?) -> StepHistory.Move? {
        history.back(leaving: place, playing: playing)
    }

    func forward(playing: PlaybackSpot?) -> StepHistory.Move? {
        history.forward(leaving: place, playing: playing)
    }

    /// Shows a step's source, search and column selections, leaving out the selections of
    /// groupings no column shows now, which would narrow the table unseen. `visiting` makes
    /// a new source a step Back can undo, as the sidebar's does.
    func show(_ window: WindowPlace, visiting: Bool = false) async {
        if visiting { pendingVisit = .some(window.filter.source) }
        changeSort(from: pending.source, to: window.filter.source)
        pending.source = window.filter.source
        pending.search = window.filter.search
        pending.stats = window.filter.stats
        pending.statsSpan = window.filter.statsSpan
        pending.selections = window.filter.selections.filter { pendingColumns.contains($0.key) }
        await reload(panesFrom: 0, reason: .user)
    }

    private func showSource(_ source: BrowserSource?) async {
        enter(source)
        await reload(panesFrom: 0, reason: .user)
    }

    /// Makes `source` the pending one. A panel takes the columns' place, and hidden columns
    /// would narrow its table with nothing on screen saying why. A Stats row's filter stays
    /// from one period to another; a bar's, which is in one period, doesn't.
    private func enter(_ source: BrowserSource?) {
        changeSort(from: pending.source, to: source)
        switch source {
        case .health, .stats: pending.selections = [:]
        case .playlist, .history, .timeline, .plays, nil: break
        }
        switch (pending.source, source, pending.stats?.item) {
        case (.stats, .stats, .entry): break
        default: pending.stats = nil
        }
        if pending.source != source { pending.statsSpan = nil }
        pending.source = source
    }

    /// Keeps Stats' table for `period` to `span`, the days of the report its panel shows, and
    /// lists it again when those aren't the days it was listed for (ADR 0109). A reload under
    /// way is dropped for this one, since it would write over the span with the filter it
    /// started from.
    func showStatsSpan(_ span: PlaySpan?, of period: StatsPeriod) async {
        guard pending.source == .stats(period), pending.statsSpan != span else { return }
        let listed = pending.statsSpan ?? period.span()
        pending.statsSpan = span
        // The usual case: the table was just listed for these days, by the period's.
        guard listed != span else { return }
        await reload(panesFrom: 0, reason: .libraryChanged)
    }

    /// Shows Stats for `period`, its table narrowed to `filter`, or listing every track
    /// played in the period for nil (ADR 0105). Showing Stats from another source is a step
    /// Back can undo; narrowing it isn't.
    func filterStats(_ filter: StatsFilter?, in period: StatsPeriod) async {
        if pending.source != .stats(period) {
            pendingVisit = .some(.stats(period))
            enter(.stats(period))
        }
        pending.stats = filter
        await reload(panesFrom: 0, reason: .user)
    }

    private func changeSort(from old: BrowserSource?, to new: BrowserSource?) {
        let leaving = defaultSort(old)
        // From one source with its own sort to another, the table's sort stays the one from
        // before the first, not one chosen inside it.
        if leaving != nil, let entering = defaultSort(new) {
            pendingSort = entering
            return
        }
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
        // The tracks' files may have moved, so the kept queue waits for its check.
        queuedGeneration += 1
        await reload(panesFrom: 0, reason: .libraryChanged)
        await checkKept()
    }

    /// Runs every query again after an edit that moves no file (a rating, an opinion, a
    /// counted play or skip), so the kept queue stays usable: a skip is counted as Enter plays
    /// the next track, and a play partway through each track.
    private func refreshEdited() async {
        await reload(panesFrom: 0, reason: .libraryChanged)
    }

    /// Keeps `queue` as the queue of the list `ids`, read after library change `readAt`, and
    /// checks it when a library change came since.
    private func keep(_ ids: [Int64], _ queue: ListQueue, readAt: Int) {
        lastQueued = (ids, queue, readAt)
        if readAt != queuedGeneration { Task { await checkKept() } }
    }

    /// Reads the kept list's files again after a library change. The list stays kept when
    /// each track's file is where it was, and is forgotten otherwise.
    private func checkKept() async {
        guard let kept = lastQueued, kept.readAt != queuedGeneration else { return }
        let generation = queuedGeneration
        let fresh: ListQueue?
        do {
            fresh = try await Self.queue(ids: kept.ids, reader: reader.refreshes)
        } catch {
            logger.error("couldn't read the kept queue's files again: \(error)")
            fresh = nil
        }
        // Another play may have kept another list meanwhile, or a later check this one.
        guard let now = lastQueued, now.ids == kept.ids, now.readAt < generation else { return }
        if let fresh, fresh.urls == now.queue.urls, fresh.entries == now.queue.entries {
            lastQueued?.readAt = generation
        } else {
            lastQueued = nil
        }
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
        // The same list in the same order as the last play: its queue is known, and the
        // engine may still be playing it.
        if let queued = lastQueued, queued.ids == ids, queued.readAt == queuedGeneration,
            let request = Self.request(queued.queue, first: first),
            request.urls.indices.contains(request.first)
        {
            return PlayStart(url: request.urls[request.first], queue: request) { request }
        }
        let reader = reader
        let remember = { @MainActor [weak self, queuedGeneration] (queue: ListQueue) in
            self?.keep(ids, queue, readAt: queuedGeneration)
        }
        guard let path = try await reader.paths(ids: [ids[first]])[ids[first]] else {
            // The clicked track has gone from the index: the queue says where playback starts.
            let queue = try await Self.queue(ids: ids, reader: reader)
            guard let request = Self.request(queue, first: first) else { return nil }
            remember(queue)
            return PlayStart(url: request.urls[request.first]) { request }
        }
        return PlayStart(url: URL(fileURLWithPath: path, isDirectory: false)) {
            let queue = try await Self.queue(ids: ids, reader: reader)
            guard let request = Self.request(queue, first: first)
            else { throw PlayStartError.noTracks }
            await remember(queue)
            return request
        }
    }

    /// The queue of `ids` from `first`, for the play state resumed at launch, kept as a
    /// play's would be: a play from the same list, as the table lists it unfiltered, then
    /// plays in the restored queue (ADR 0104).
    func resumedQueue(ids: [Int64], first: Int) async throws -> PlayRequest? {
        let generation = queuedGeneration
        let queue = try await Self.queue(ids: ids, reader: reader)
        keep(ids, queue, readAt: generation)
        return Self.request(queue, first: first)
    }

    nonisolated static func request(ids: [Int64], first: Int, reader: LibraryReader)
        async throws -> PlayRequest?
    {
        request(try await queue(ids: ids, reader: reader), first: first)
    }

    /// The files of `ids`, in their order, and the index in them of each ID's file; nil for an
    /// ID gone from the index, which is left out.
    nonisolated static func queue(ids: [Int64], reader: LibraryReader) async throws -> ListQueue {
        let paths = try await reader.paths(ids: ids)
        var urls: [URL] = []
        urls.reserveCapacity(paths.count)
        var entries: [Int?] = []
        entries.reserveCapacity(ids.count)
        for id in ids {
            guard let path = paths[id] else {
                entries.append(nil)
                continue
            }
            entries.append(urls.count)
            urls.append(URL(fileURLWithPath: path, isDirectory: false))
        }
        return (urls, entries)
    }

    /// `queue` played from the row `first`, or from the next row whose track is still in the
    /// index when that one's isn't; nil for an empty queue.
    nonisolated static func request(_ queue: ListQueue, first: Int) -> PlayRequest? {
        guard !queue.urls.isEmpty else { return nil }
        let start = queue.entries[first...].lazy.compactMap { $0 }.first ?? queue.urls.count
        return PlayRequest(urls: queue.urls, first: start)
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
        // As many as the columns, which a change may have added or taken away.
        var entries = columns.indices.map {
            self.entries.indices.contains($0) ? self.entries[$0] : []
        }
        // A newer change, such as a keystroke, doesn't wait behind a refresh's queries.
        let reader = reason == .libraryChanged ? reader.refreshes : reader
        do {
            // The timeline lists plays, which its own model pages through.
            let tracks = next.source?.listsPlays != true
            for column in (first ?? columns.count)..<columns.count {
                let grouping = columns[column]
                // The selections of this column and those to its right don't narrow it.
                entries[column] =
                    tracks
                    ? try await reader.columnEntries(
                        grouping, next, ignoring: Set(columns[column...])) : []
                next.selections[grouping] = resolve(
                    next.selections[grouping],
                    saved.flatMap {
                        $0.columns.indices.contains(column) ? $0.columns[column] : nil
                    }?
                    .selection,
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
            if case .some = pendingVisit {
                history.visit(WindowPlace(filter: next), leaving: place)
            }
            pendingVisit = .none
            missingTracks = missing
            let previousIDs = trackIDs
            let widened =
                reason == .user && !Self.isEverything(filter) && Self.isEverything(next)
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
            changed(
                BrowserChange(
                    reason: reason, panes: panesChanged, previousIDs: previousIDs,
                    showsEverythingAgain: widened))
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
    /// The user went from a source, a pane or a search back to the whole library.
    var showsEverythingAgain: Bool
}

/// What the window saves of the browser: the sidebar's source, nil for the whole library, and
/// the columns with their selections.
public struct BrowserState: Equatable, Sendable {
    public var source: BrowserSource?
    public var columns: [BrowserColumn]
    /// The sort chosen in `source`, when it has its own and another was chosen.
    public var sourceSort: SourceSort?
    public var search: String

    public init(
        source: BrowserSource?, columns: [BrowserColumn] = BrowserColumn.defaults,
        sourceSort: SourceSort? = nil, search: String = ""
    ) {
        self.source = source
        self.columns = columns
        self.sourceSort = sourceSort
        self.search = search
    }
}

/// A track to start playing at once, and the queue it belongs to, read after it starts.
public struct PlayStart: Sendable {
    public var url: URL
    /// The whole queue when it's known already: the one the last play from the same list in
    /// the same order queued, which the engine may still be playing as it was set.
    public var queue: PlayRequest? = nil
    /// The whole queue, with `url` at its `first`. Runs off the main actor.
    public var request: @Sendable () async throws -> PlayRequest
}

enum PlayStartError: Error, CustomStringConvertible {
    case noTracks

    var description: String { "none of the tracks to play are in the library any more" }
}

/// A list's files in its order, and the index in them of each row's file; nil for a row whose
/// track is gone from the index.
typealias ListQueue = (urls: [URL], entries: [Int?])

/// Files to play as a new queue, and the index in it to start at.
public struct PlayRequest: Equatable, Sendable {
    public var urls: [URL]
    public var first: Int
}
