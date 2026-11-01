import AppKit
import Commands
import DisplayText
import KeyChord
import Library
import Log
import Settings

private let logger = moduleLogger()

/// The library half of the window: the sidebar, the genre, artist and album panes over the track
/// table, the search field, and the status line. The app places the views and handles what they
/// report; the logic is in `BrowserModel`.
@MainActor
public final class LibraryBrowser: NSObject, NSSplitViewDelegate, NSSearchFieldDelegate {
    /// The longest the window waits between refreshes while a scan stores rows.
    static let refreshIntervalSeconds = 2.0

    private let model: BrowserModel
    public let sidebar: NSViewController
    /// The panes over the track table, with the status line under them.
    public let content: NSViewController
    public let searchField = NSSearchField()
    /// Takes the watcher's events on any thread and hands them to the browser in the order they
    /// were sent, so a late progress report never lands after its scan's outcome.
    public let watcherEvents: @Sendable (WatcherEvent) -> Void

    /// Play these files as a new queue.
    public var play: (PlayRequest) -> Void = { _ in }
    /// Queue these files after the current track.
    public var playNext: ([URL]) -> Void = { _ in }
    public var tableLayoutChanged: (TrackTableLayout) -> Void = { _ in }
    public var browserHeightChanged: (Int) -> Void = { _ in }
    public var stateChanged: (BrowserState) -> Void = { _ in }
    /// Called after each refresh for a library change, so other views can read their rows again.
    public var libraryRefreshed: () -> Void = {}
    public var addFolder: () -> Void = {}
    public var removeFolder: (String) -> Void = { _ in }
    /// Runs the command a key press in one of the browser's lists is bound to.
    public var keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome = { _ in .unbound }
    /// Called once, when the table or the timeline first draws rows, or once loading finds none
    /// to draw.
    public var firstRowsDrawn: (() -> Void)? {
        get { table.firstRowsDrawn }
        set { table.firstRowsDrawn = newValue }
    }

    private let reader: LibraryReader
    private let index: LibraryIndex
    private let table: TrackTableController
    let timelineModel: TimelineModel
    /// Shown in place of the panes and the track table while the timeline is the source.
    private let timeline: TimelineController
    private let panes: PanesController
    private let sidebarController: SidebarController
    private let split = NSSplitView()
    private let statusBar = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let problemsButton = NSButton()
    private(set) var status = LibraryStatus()
    private var browserHeight: Int
    private var folders: [WatchedFolder]
    private var lastRefresh = Date.distantPast
    private var refreshPending = false
    private var problems: ProblemsWindow?
    /// Counts folder tree reads, so only the newest is shown.
    private var treeReads = 0
    let health: HealthModel
    /// Set from the read of another player's library until its preview sheet closes.
    private var isImporting = false
    private(set) var importSheet: PlayerImportSheet?
    /// True from Resolve Lost Stats until its last sheet closes, so one is open at a time.
    private var isResolvingLostStats = false
    private(set) var lostStatsSheet: LostStatsSheet?

    /// `index` is a connection for the main thread, which fetches the table's rows a page at a
    /// time: a page is one primary-key lookup per row and takes well under a millisecond.
    public init(
        reader: LibraryReader, index: LibraryIndex, layout: TrackTableLayout, browserHeight: Int,
        folders: [WatchedFolder], groupByAlbumArtist: Bool
    ) {
        self.reader = reader
        self.index = index
        self.browserHeight = browserHeight
        self.folders = folders
        model = BrowserModel(
            reader: reader, sortColumn: layout.sortColumn, ascending: layout.sortAscending,
            groupByAlbumArtist: groupByAlbumArtist)
        let model = self.model
        // The views report to this object, which exists only after its stored properties do.
        weak var owner: LibraryBrowser?
        let cache = RowCache { ids in try index.rows(ids: ids) }
        let actions = BrowserActions(
            play: { rows, clicked in owner?.playRows(rows, clicked: clicked) },
            playNext: { rows in owner?.queueNext(rows) },
            reveal: { rows in owner?.reveal { model.ids(ofRows: rows) } },
            move: { ids, row in
                owner?.edit("couldn't move the tracks") { try await model.move(ids, toRow: row) }
            },
            sort: { column, ascending in
                Task { await model.setSort(column, ascending: ascending) }
            },
            layoutChanged: { layout in owner?.tableLayoutChanged(layout) },
            failed: { message in owner?.show(failure: message) },
            keyCommand: { chords in owner?.keyCommand(chords) ?? .unbound })
        table = TrackTableController(model: model, cache: cache, layout: layout, actions: actions)
        let timelineModel = TimelineModel(reader: reader) { ids in try index.playedTracks(ids: ids)
        }
        self.timelineModel = timelineModel
        timeline = TimelineController(
            model: timelineModel,
            play: { rows, clicked in
                do {
                    guard
                        let request = try timelineModel.playRequest(
                            selected: rows, clicked: clicked)
                    else { return }
                    owner?.play(request)
                } catch {
                    owner?.reportCommand("couldn't play the selection", error)
                }
            },
            playNext: { rows in
                do {
                    owner?.playNext(try timelineModel.urls(ofRows: rows))
                } catch {
                    owner?.reportCommand("couldn't queue the selection", error)
                }
            },
            reveal: { rows in owner?.reveal { try timelineModel.trackIDs(ofRows: rows) } },
            keyCommand: { chords in owner?.keyCommand(chords) ?? .unbound },
            failed: { message in owner?.show(failure: message) })
        panes = PanesController(
            model: model, select: { pane, id in Task { await model.select(pane, id: id) } },
            keyCommand: { chords in owner?.keyCommand(chords) ?? .unbound })
        sidebarController = SidebarController(
            // The sidebar shows the model's source after, which stays put when it fails.
            selectSource: { source in
                Task {
                    await model.setSource(source)
                    owner?.showSource()
                }
            },
            addFolder: { owner?.addFolder() },
            removeFolder: { path in owner?.removeFolder(path) },
            keyCommand: { chords in owner?.keyCommand(chords) ?? .unbound })
        sidebar = sidebarController
        sidebarController.dropTracks = { playlist, ids in
            owner?.edit("couldn't add the tracks to the playlist", entriesChange: true) {
                _ = try await model.add(ids, to: playlist)
            }
        }
        sidebarController.dropPlaylistFiles = { urls in owner?.importPlaylists(from: urls) }
        content = NSViewController()
        health = HealthModel(
            build: { try await reader.healthReport() }, show: { try await reader.showHealth($0) })
        let (events, continuation) = AsyncStream.makeStream(of: WatcherEvent.self)
        watcherEvents = { continuation.yield($0) }
        super.init()
        owner = self
        Task { [weak self, events] in
            for await event in events { self?.libraryChanged(event) }
        }
        content.view = makeContent()
        content.addChild(table)
        content.addChild(panes)
        content.addChild(timeline)

        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self

        model.changed = { [weak self] change in self?.apply(change) }
        model.failed = { [weak self] message in self?.show(failure: message) }
        timelineModel.changed = { [weak self] previous in
            self?.timeline.reload(previousIDs: previous)
            self?.showStatus()
        }
        timelineModel.failed = { [weak self] message in self?.show(failure: message) }
        health.changed = { [weak self] in self?.healthChanged() }
        health.failed = { [weak self] message in self?.report(message) }
    }

    private func makeContent() -> NSView {
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(panes.view)
        split.addArrangedSubview(table.view)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        problemsButton.title = "Show Problems"
        problemsButton.bezelStyle = .inline
        problemsButton.controlSize = .small
        problemsButton.target = self
        problemsButton.action = #selector(showProblems)
        problemsButton.isHidden = true
        let bar = statusBar
        for view in [statusLabel, problemsButton] { bar.addArrangedSubview(view) }
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeline.view.isHidden = true
        let stack = NSStackView(views: [split, timeline.view, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.detachesHiddenViews = true
        for view in [split, timeline.view, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// Lays out the panes at their saved height. Call once the window has its size.
    public func restoreSplit() {
        split.adjustSubviews()
        split.setPosition(CGFloat(browserHeight), ofDividerAt: 0)
    }

    /// Loads everything, selecting what `saved` names where it still exists.
    public func load(_ saved: BrowserState) async {
        await model.load(saved)
        // Handed over before anything else waits, so no row can draw first.
        if let firstRowsDrawn {
            if showsTimeline {
                self.firstRowsDrawn = nil
                timeline.firstRowsDrawn = firstRowsDrawn
            } else if model.trackIDs.isEmpty {
                self.firstRowsDrawn = nil
                firstRowsDrawn()
            }
        }
        do {
            // Forgotten only once shown, so a crash before then shows them next time.
            let discards = try await reader.discards()
            status.notices += discards.map(\.text)
            showStatus()
            try await reader.forgetDiscards(discards.map(\.id))
        } catch {
            report("couldn't read or forget what a stats rebuild discarded: \(error)")
        }
        // Before the sidebar shows the source, which may be a subfolder.
        await loadFolderTree()
        showSource()
        await countIssues()
    }

    /// Scrolls the table through every row, drawing each screenful, and passes each row to
    /// `visit`. For measuring memory once the whole library has been on screen.
    public func scrollThroughEveryRow(_ visit: (TrackRow) -> Void) {
        table.scrollThroughEveryRow(visit)
    }

    /// Lists a changed set of watched folders. If the shown folder went, the library is shown.
    public func setFolders(_ folders: [WatchedFolder]) async {
        self.folders = folders
        var source = model.filter.source
        if case .folder(let path) = source,
            !FolderTree.isFolder(path, under: folders.map(\.path))
        {
            source = nil
        }
        sidebarController.show(folders: folders, playlists: model.playlists, source: source)
        if source != model.filter.source { await model.setSource(source) }
        await loadFolderTree()
    }

    /// Reads the subfolders of the watched folders from the index and lists them.
    private func loadFolderTree() async {
        treeReads += 1
        let mine = treeReads
        do {
            let tree = try await reader.folderTree(roots: folders.map(\.path))
            guard mine == treeReads else { return }
            sidebarController.show(tree: tree)
        } catch {
            report("couldn't read the folders from the library: \(error)")
        }
    }

    /// What the watcher reported. Refreshes as rows arrive, at most every
    /// `refreshIntervalSeconds` during a scan and at once when one ends.
    private func libraryChanged(_ event: WatcherEvent) {
        status.apply(event)
        showStatus()
        switch event {
        case .scanning:
            scheduleRefresh()
        case .scanned(_, let summary):
            let changed = summary.read > 0 || summary.removed > 0
            if changed { refreshNow() }
            // A network folder's scans come from polling, so one that changed nothing doesn't
            // run the report again; the first scan's end runs it once.
            if changed || (health.report == nil && !health.isRunning) { runHealth() }
        case .scanFailed:
            refreshNow()
        case .removed:
            refreshNow()
            runHealth()
        case .folders(let folders):
            // The rewrite gave the tracks under them new paths.
            refreshNow()
            Task { await setFolders(folders) }
        }
    }

    // MARK: Library health

    /// Runs the health report again, from Check Library Health, and opens its rows.
    public func checkHealth() {
        sidebarController.openHealth()
        show(failure: "Checking the library's health…")
        runHealth()
    }

    /// Opens Lost Stats over `window`, one lost file at a time, to give each one's stats to a
    /// track that matches it or dismiss it.
    public func resolveLostStats(over window: NSWindow) {
        guard !isResolvingLostStats else {
            NSSound.beep()
            return
        }
        isResolvingLostStats = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let lost = try await reader.lostFiles()
                guard !lost.isEmpty else {
                    isResolvingLostStats = false
                    return show(failure: "No lost stats to resolve")
                }
                let session = LostStatsSession(
                    lost: lost,
                    paths: try await reader.paths(ids: Array(Set(lost.flatMap(\.candidates)))),
                    move: { [reader] in try await reader.moveStats(from: $0, to: $1) },
                    dismiss: { [reader] in try await reader.dismissLost($0) })
                let sheet = LostStatsSheet(session: session)
                sheet.changed = { [weak self] in
                    self?.refreshNow()
                    self?.runHealth()
                }
                sheet.failed = { [weak self] message in self?.report(message) }
                sheet.closed = { [weak self] in
                    self?.lostStatsSheet = nil
                    self?.isResolvingLostStats = false
                }
                lostStatsSheet = sheet
                sheet.begin(over: window)
            } catch {
                isResolvingLostStats = false
                report("couldn't read the lost stats: \(error)")
            }
        }
    }

    private func runHealth() {
        Task { await health.run() }
    }

    /// A newer report: the sidebar counts it, and a check shown lists it.
    private func healthChanged() {
        guard let report = health.report else { return }
        sidebarController.show(health: report)
        if case .health = model.filter.source {
            Task { await model.refresh() }
        } else {
            showStatus()
        }
    }

    /// A check shown before any report has run starts one.
    private func runHealthIfShownFirst() {
        guard case .health = model.filter.source, health.report == nil, !health.isRunning
        else { return }
        runHealth()
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        let wait = max(0, Self.refreshIntervalSeconds - Date().timeIntervalSince(lastRefresh))
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.refreshNow()
        }
    }

    private func refreshNow() {
        refreshPending = false
        lastRefresh = Date()
        Task {
            await model.refresh()
            if showsTimeline { timelineModel.refresh() }
            await loadFolderTree()
            libraryRefreshed()
            await countIssues()
        }
    }

    private func countIssues() async {
        do {
            status.fileIssueCount = Set(try await reader.fileIssues().map(\.path)).count
        } catch {
            report(problemsUnreadable(error))
        }
        showStatus()
    }

    private func apply(_ change: BrowserChange) {
        if change.panes { panes.reload() }
        table.reload(change)
        showTimelineIfItIsTheSource()
        runHealthIfShownFirst()
        showStatus()
        stateChanged(model.state)
    }

    /// Whether the sidebar shows the play timeline, which lists plays instead of tracks.
    var showsTimeline: Bool { model.filter.source == .timeline }

    /// Whether the sort commands apply: not on the timeline, whose order is the log's.
    public var canSort: Bool { !showsTimeline }

    /// Swaps the timeline in for the panes and the track table, or back, as the source
    /// changes. The timeline loads afresh each time it shows.
    private func showTimelineIfItIsTheSource() {
        let shows = showsTimeline
        guard timeline.view.isHidden == shows else { return }
        let hadKeys = focusedList != nil
        split.isHidden = shows
        timeline.view.isHidden = !shows
        searchField.isEnabled = !shows
        if shows {
            Task { await timelineModel.load() }
        } else {
            timelineModel.clear()
        }
        if hadKeys { focusTracks() }
    }

    private func showStatus() {
        let found: HealthFindings? =
            if case .health(let check) = model.filter.source { health.report?[check] } else { nil }
        status.healthLines = found?.lines ?? []
        status.healthOtherCount = found?.otherCount ?? 0
        statusLabel.stringValue = status.text(
            trackCount: model.trackIDs.count, missingCount: model.missingTracks,
            playCount: showsTimeline ? timelineModel.playCount : nil)
        statusLabel.toolTip = status.problemLines.joined(separator: "\n")
        problemsButton.isHidden = !status.hasProblems
    }

    /// Logs a failure and shows it in the status bar.
    public func report(_ message: String) {
        logger.error("\(message)")
        show(failure: message)
    }

    /// Reports a command that failed. One with no track to act on also beeps, as a menu item
    /// that doesn't apply would.
    public func reportCommand(_ failure: String, _ error: any Error) {
        if error is OnlyMissingFiles { beep() }
        report("\(failure): \(error)")
    }

    /// Shows files in Finder; tests record them instead.
    var revealFiles: ([String]) -> Void = revealInFinder

    /// Reveals the files of the tracks `ids` gives, for the context menu's rows.
    private func reveal(_ read: () throws -> [Int64]) {
        let failure = "couldn't reveal the tracks"
        let ids: [Int64]
        do {
            ids = try read()
        } catch {
            reportCommand(failure, error)
            return
        }
        Task {
            do {
                let paths = try await reader.paths(ids: ids)
                revealFiles(ids.compactMap { paths[$0] })
            } catch {
                reportCommand(failure, error)
            }
        }
    }

    /// The system beep; tests count it instead.
    var beep: () -> Void = { NSSound.beep() }

    /// What the status bar says, for tests.
    var statusText: String { statusLabel.stringValue }

    private func show(failure message: String) {
        statusLabel.stringValue = message
        statusLabel.toolTip = message
    }

    @objc private func searchChanged() {
        let text = searchField.stringValue
        Task { await model.setSearch(text) }
    }

    private func playRows(_ rows: IndexSet, clicked: Int) {
        Task {
            do {
                if let request = try await model.playRequest(selected: rows, clicked: clicked) {
                    play(request)
                }
            } catch {
                report("couldn't read the tracks to play: \(error)")
            }
        }
    }

    private func queueNext(_ rows: IndexSet) {
        Task {
            do {
                playNext(try await model.urls(ofRows: rows))
            } catch {
                report("couldn't read the tracks to queue: \(error)")
            }
        }
    }

    @objc private func showProblems() {
        Task {
            let issues: [String]
            do {
                issues = try await reader.fileIssues().map(\.description)
            } catch {
                issues = [problemsUnreadable(error)]
            }
            let window = problems ?? ProblemsWindow()
            problems = window
            window.show(status.problemLines + issues)
        }
    }

    // MARK: Commands

    /// The list that has the keys.
    private enum List: Equatable {
        case tracks
        case pane(BrowserModel.Pane)
        case timeline
    }

    private var focusedList: List? {
        let responder = table.table.window?.firstResponder
        if responder === table.table { return .tracks }
        if responder === timeline.table { return .timeline }
        return panes.tables.first { $0.value === responder }.map { .pane($0.key) }
    }

    /// The browser's lists in the order Tab moves through them: the sidebar, the panes, the
    /// track table.
    public var focusAreas: [NSView] {
        if showsTimeline { return [sidebarController.outline, timeline.table] }
        return [sidebarController.outline]
            + BrowserModel.Pane.allCases.compactMap { panes.tables[$0] } + [table.table]
    }

    /// Moves the selection of the list with the keys; false when none of them has the keys.
    public func moveSelection(_ move: RowMove, extending: Bool) -> Bool {
        switch focusedList {
        case .tracks: table.move(move, extending: extending)
        case .pane(let pane): panes.move(move, in: pane)
        case .timeline: timeline.move(move, extending: extending)
        case nil: return false
        }
        return true
    }

    /// Focuses the next pane to the right (or left), from the genre pane to the track table.
    public func focusPane(forward: Bool) {
        // The timeline has no panes.
        guard !showsTimeline else {
            focusTracks()
            return
        }
        let order: [List] = BrowserModel.Pane.allCases.map { .pane($0) } + [.tracks]
        let index = focusedList.flatMap { order.firstIndex(of: $0) } ?? (order.count - 1)
        let next = order[(index + (forward ? 1 : order.count - 1)) % order.count]
        switch next {
        case .tracks, .timeline: focusTracks()
        case .pane(let pane): table.table.window?.makeFirstResponder(panes.tables[pane])
        }
    }

    /// Gives the keys to the track table, or to the timeline while it shows.
    public func focusTracks() {
        let list = showsTimeline ? timeline.table : table.table
        list.window?.makeFirstResponder(list)
    }

    public func focusSidebar() {
        sidebarController.outline.window?.makeFirstResponder(sidebarController.outline)
    }

    /// Focuses the search field with its text selected.
    public func focusSearch() {
        searchField.window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    /// Whether the shown list has a selection to act on.
    public var hasSelectedTracks: Bool {
        // A timeline selection of only missing files enables commands that then beep and say
        // so, rather than reading every selected play's track each time a menu is checked.
        showsTimeline
            ? !timeline.table.selectedRowIndexes.isEmpty
            : !table.table.selectedRowIndexes.isEmpty
    }

    /// The selected tracks in row order: on the timeline, each track once (ADR 0022).
    private func selectedTrackIDs() throws -> [Int64] {
        showsTimeline
            ? try timelineModel.trackIDs(ofRows: timeline.table.selectedRowIndexes)
            : model.ids(ofRows: table.table.selectedRowIndexes)
    }

    /// `selectedTrackIDs`, or nil after reporting `failure` with why they couldn't be read.
    private func selectedTrackIDs(else failure: String) -> [Int64]? {
        do {
            return try selectedTrackIDs()
        } catch {
            reportCommand(failure, error)
            return nil
        }
    }

    /// Whether the track table has the keys.
    public var tracksHaveFocus: Bool { focusedList == .tracks }

    public func selectAllTracks() {
        (showsTimeline ? timeline.table : table.table).selectAll(nil)
    }

    public func playSelection() {
        if showsTimeline { timeline.playSelected() } else { table.playSelected() }
    }

    public func playSelectionNext() {
        if showsTimeline { timeline.playSelectedNext() } else { table.playSelectedNext() }
    }

    /// The paths of the selected tracks, in table order.
    public func selectedPaths() async throws -> [String] {
        let ids = try selectedTrackIDs()
        let paths = try await reader.paths(ids: ids)
        return ids.compactMap { paths[$0] }
    }

    public var sortColumn: TrackColumn { model.sortColumn }

    public func sort(by column: TrackColumn) { Task { await model.sort(by: column) } }

    public func reverseSort() { Task { await model.reverseSort() } }

    public var canGoBack: Bool { model.history.canGoBack }
    public var canGoForward: Bool { model.history.canGoForward }

    public func back() { Task { if await model.back() { showSource() } } }

    public func forward() { Task { if await model.forward() { showSource() } } }

    /// Selects the model's source in the sidebar, listing the playlists as they are now. A
    /// folder the sidebar no longer lists, since its tracks left the index, gives way to the
    /// library.
    private func showSource() {
        sidebarController.show(
            folders: folders, playlists: model.playlists, source: model.filter.source)
        guard !sidebarController.lists(model.filter.source) else { return }
        logger.notice("the folder shown has no tracks left; showing the library")
        Task {
            await model.setSource(nil)
            showSource()
        }
    }

    // MARK: Playlists and stats

    /// Every playlist, by name.
    public var playlists: [Playlist] { model.playlists }

    /// The playlist the sidebar shows, if it shows one.
    public var shownPlaylist: Playlist? { model.shownPlaylist }

    /// Shows a source, as the sidebar would, from the palette or after a new playlist.
    public func show(_ source: BrowserSource?) {
        Task {
            await model.setSource(source)
            showSource()
            focusTracks()
        }
    }

    /// Makes a playlist, smart when `rules` are given, holding the selected tracks when
    /// `withSelection` is set, and shows it.
    public func createPlaylist(named name: String, rules: SmartRules?, withSelection: Bool) {
        let failure = "couldn't make the playlist \"\(name)\""
        guard let ids = withSelection ? selectedTrackIDs(else: failure) : [] else { return }
        edit("couldn't make the playlist \"\(name)\"", entriesChange: true) {
            try await self.model.createPlaylist(named: name, rules: rules, trackIDs: ids)
        }
    }

    public func renamePlaylist(_ id: Int64, to name: String) {
        edit("couldn't rename the playlist") { try await self.model.renamePlaylist(id, to: name) }
    }

    public func deletePlaylist(_ id: Int64) {
        edit("couldn't delete the playlist", entriesChange: true) {
            try await self.model.deletePlaylist(id)
        }
    }

    public func setRules(_ rules: SmartRules, of id: Int64) {
        edit("couldn't change the playlist's rules") {
            try await self.model.setRules(rules, of: id)
        }
    }

    /// Imports each playlist file as a new manual playlist, in turn, and shows the last one.
    /// What an import couldn't add is listed in the Problems window, which opens to show it.
    public func importPlaylists(from urls: [URL]) {
        Task {
            var summaries: [String] = []
            var lines: [String] = []
            for url in urls {
                do {
                    let result = try await model.importPlaylist(from: url)
                    summaries.append(result.summary)
                    lines += result.reportLines
                } catch {
                    let failure = terminalSafe("couldn't import \(url.path): \(error)")
                    logger.error("\(failure)")
                    summaries.append(failure)
                    lines.append(failure)
                }
            }
            showSource()
            finishPlaylistFile(summaries.joined(separator: " · "), lines)
            playlistEntriesChanged()
        }
    }

    /// Writes the playlist `id`, which must still be the one shown, to `url` as M3U8, in the
    /// table's sort, with paths relative to the file's folder when `relativePaths` is set.
    public func exportShownPlaylist(_ id: Int64, to url: URL, relativePaths: Bool) {
        guard let playlist = model.shownPlaylist, playlist.id == id else {
            report("couldn't export the playlist: it's no longer shown")
            return
        }
        let missing = model.missingTracks
        Task {
            do {
                let (written, unwritable) = try await model.exportPlaylist(
                    playlist.id, to: url, relativePaths: relativePaths)
                let (summary, lines) = exportReport(
                    file: url.path, written: written, missing: missing, unwritable: unwritable)
                finishPlaylistFile(summary, lines)
            } catch {
                report(terminalSafe("couldn't export the playlist to \(url.path): \(error)"))
            }
        }
    }

    /// Reads `player`'s library at `url` and shows what importing it would change in a sheet
    /// over `window`. One import is open at a time.
    public func importLibrary(_ player: PlayerLibrary.Player, from url: URL, over window: NSWindow)
    {
        guard !isImporting else {
            NSSound.beep()
            show(failure: "An import is already open")
            return
        }
        isImporting = true
        show(failure: "Reading the \(player.title) library…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let library = try await Task.detached { try PlayerLibrary.read(player, at: url) }
                    .value
                let session = PlayerImportSession(
                    shown: try await model.importPlan(library, prefix: nil)
                ) { [model] prefix in try await model.importPlan(library, prefix: prefix) }
                let sheet = PlayerImportSheet(session: session, player: player)
                sheet.confirmed = { [weak self] plan in self?.apply(plan) }
                sheet.closed = { [weak self] in
                    self?.importSheet = nil
                    self?.isImporting = false
                }
                importSheet = sheet
                showStatus()
                sheet.begin(over: window)
            } catch {
                isImporting = false
                report(terminalSafe("couldn't read \(url.path): \(error)"))
            }
        }
    }

    private func apply(_ plan: ImportPlan) {
        Task {
            do {
                let written = try await model.applyImport(plan.library, prefix: plan.prefix)
                showSource()
                finishPlaylistFile(written.summary, written.detailLines)
                playlistEntriesChanged()
            } catch {
                report(
                    terminalSafe(
                        "couldn't import from \(plan.library.player.title); nothing changed: \(error)"
                    ))
            }
        }
    }

    /// Shows what an import or export did in the status bar, and opens the Problems window on
    /// `lines` when there are any.
    private func finishPlaylistFile(_ summary: String, _ lines: [String]) {
        status.playlistFileReport = lines
        showStatus()
        show(failure: summary)
        if !lines.isEmpty { showProblems() }
    }

    /// Adds the selected tracks to a manual playlist.
    public func addSelection(to playlist: Int64) {
        let failure = "couldn't add the tracks to the playlist"
        guard let ids = selectedTrackIDs(else: failure) else { return }
        edit(failure, entriesChange: true) {
            _ = try await self.model.add(ids, to: playlist)
        }
    }

    /// Whether the selection can be taken out of the playlist shown.
    public var canRemoveFromPlaylist: Bool {
        model.shownPlaylist?.isManual == true && hasSelectedTracks
    }

    public func removeSelectionFromPlaylist() {
        let rows = table.table.selectedRowIndexes
        edit("couldn't remove the tracks from the playlist", entriesChange: true) {
            try await self.model.removeFromShownPlaylist(rows: rows)
        }
    }

    /// Rates the selected tracks; 0 stars clears their rating.
    public func rateSelection(_ stars: Int) {
        guard let ids = selectedTrackIDs(else: "couldn't rate the tracks") else { return }
        edit("couldn't rate the tracks") { try await self.model.rate(ids, stars: stars) }
    }

    /// Follows `library.groupByAlbumArtist`.
    public func setGroupByAlbumArtist(_ on: Bool) async { await model.setGroupByAlbumArtist(on) }

    /// Loves the selection, or unloves it when all of it is loved.
    public func toggleLovedSelection() {
        guard let ids = selectedTrackIDs(else: "couldn't love the tracks") else { return }
        edit("couldn't love the tracks") { try await self.model.toggleLoved(ids) }
    }

    /// Counts a play of the track at `path`, at `seconds` since 1970.
    public func recordPlay(_ path: String, at seconds: Double) {
        edit("couldn't count the play of \(path)") {
            try await self.model.recordPlay(path, at: seconds)
            if self.showsTimeline { await self.timelineModel.addNewPlays() }
        }
    }

    public func recordSkip(_ path: String) {
        edit("couldn't count the skip of \(path)") { try await self.model.recordSkip(path) }
    }

    /// Runs an edit, then lists the playlists and selects the source as they now are. A failure
    /// is logged and shown in the status bar. `entriesChange` says the edit can add or drop
    /// playlist entries, which the health report counts.
    private func edit(
        _ failure: String, entriesChange: Bool = false,
        _ body: @escaping @MainActor () async throws -> Void
    ) {
        Task {
            do {
                try await body()
                if entriesChange { playlistEntriesChanged() }
            } catch {
                report("\(failure): \(error)")
            }
            showSource()
        }
    }

    /// Playlist entries were added or dropped: a report already made runs again, so Lost
    /// Entries isn't left counting the old ones.
    private func playlistEntriesChanged() {
        guard health.report != nil || health.isRunning else { return }
        runHealth()
    }

    public var isStatusBarVisible: Bool { !statusBar.isHidden }

    public func toggleStatusBar() { statusBar.isHidden.toggle() }

    /// Selects the track at `path` in the table, centered, showing the whole library first if
    /// the source, a pane or the search hides it.
    public func reveal(path: String) async {
        let id: Int64
        do {
            guard let track = try index.track(path: path) else { return }
            id = track.id
        } catch {
            report("couldn't find \(path) in the library: \(error)")
            return
        }
        guard let row = await model.reveal(id) else { return }
        if model.filter.search.isEmpty { searchField.stringValue = "" }
        showSource()
        showRow(row)
    }

    /// Selects `row` alone, centered, and gives the table the keys.
    public func showRow(_ row: Int) {
        if showsTimeline { timeline.selectCentered(row) } else { table.selectCentered(row) }
        focusTracks()
    }

    /// Every genre, artist and album in the library.
    public func allEntries() async throws -> [(BrowserModel.Pane, BrowserEntry)] {
        try await model.allEntries()
    }

    /// Shows what `query` names and plays all of it, for `music-player play`. Returns what
    /// plays, as the tool prints it.
    public func play(_ query: PlayQuery) async throws -> String {
        if case .search(let text) = query { searchField.stringValue = text }
        let request = try await model.show(query)
        if case .entry = query { searchField.stringValue = "" }
        showSource()
        focusTracks()
        play(request)
        return "Playing \(tracks(request.urls.count))"
    }

    /// Shows the library narrowed to one entry, as the palette chooses it.
    public func showOnly(_ pane: BrowserModel.Pane, id: Int64) async {
        searchField.stringValue = ""
        await model.showOnly(pane, id: id)
        showSource()
        focusTracks()
    }

    /// What identifies `row`, to check a palette row still points at it: the track ID, or on
    /// the timeline the play's history ID.
    public func rowID(at row: Int) -> Int64? {
        if showsTimeline {
            return timelineModel.entries.indices.contains(row) ? timelineModel.entries[row].id : nil
        }
        return model.trackIDs.indices.contains(row) ? model.trackIDs[row] : nil
    }

    /// The shown rows' names in order, each with its `rowID`, for Go to Item. On the timeline,
    /// the loaded plays.
    public func trackNames() async throws -> [TrackName] {
        guard showsTimeline else { return try await model.trackNames() }
        return try timelineModel.names()
    }

    /// Esc clears the search and gives the keys back to the table; ↑ and ↓ move the table's
    /// selection while the field keeps the keys.
    public func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            searchField.stringValue = ""
            searchChanged()
            focusTracks()
        case #selector(NSResponder.moveUp(_:)): table.move(.up, extending: false)
        case #selector(NSResponder.moveDown(_:)): table.move(.down, extending: false)
        default: return false
        }
        return true
    }

    // MARK: Split view

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let window = split.window, window.isVisible, !split.subviews.isEmpty else { return }
        let height = Int(split.subviews[0].frame.height.rounded())
        guard height != browserHeight else { return }
        browserHeight = height
        browserHeightChanged(height)
    }

    public func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        // The table keeps room for a few rows.
        min(proposedMaximumPosition, splitView.bounds.height - 120)
    }
}

private func problemsUnreadable(_ error: any Error) -> String {
    "couldn't read the library's problems: \(error)"
}
