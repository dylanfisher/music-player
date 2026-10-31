import AppKit
import Commands
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
    public static let refreshIntervalSeconds = 2.0

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
    /// Called once, when the table first draws rows, or once loading finds none to draw.
    public var firstRowsDrawn: (() -> Void)? {
        get { table.firstRowsDrawn }
        set { table.firstRowsDrawn = newValue }
    }

    private let reader: LibraryReader
    private let index: LibraryIndex
    private let table: TrackTableController
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

    /// `index` is a connection for the main thread, which fetches the table's rows a page at a
    /// time: a page is one primary-key lookup per row and takes well under a millisecond.
    public init(
        reader: LibraryReader, index: LibraryIndex, layout: TrackTableLayout, browserHeight: Int,
        folders: [WatchedFolder]
    ) {
        self.reader = reader
        self.index = index
        self.browserHeight = browserHeight
        self.folders = folders
        model = BrowserModel(
            reader: reader, sortColumn: layout.sortColumn, ascending: layout.sortAscending)
        let model = self.model
        // The views report to this object, which exists only after its stored properties do.
        weak var owner: LibraryBrowser?
        let cache = RowCache { ids in try index.rows(ids: ids) }
        let actions = BrowserActions(
            play: { rows, clicked in owner?.playRows(rows, clicked: clicked) },
            playNext: { rows in owner?.queueNext(rows) },
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
            owner?.edit("couldn't add the tracks to the playlist") {
                _ = try await model.add(ids, to: playlist)
            }
        }
        content = NSViewController()
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

        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self

        model.changed = { [weak self] change in self?.apply(change) }
        model.failed = { [weak self] message in self?.show(failure: message) }
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
        let stack = NSStackView(views: [split, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for view in [split, bar] {
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
        showSource()
        if model.trackIDs.isEmpty, let firstRowsDrawn {
            self.firstRowsDrawn = nil
            firstRowsDrawn()
        }
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
        if case .folder(let path) = source, !folders.contains(where: { $0.path == path }) {
            source = nil
        }
        sidebarController.show(folders: folders, playlists: model.playlists, source: source)
        if source != model.filter.source { await model.setSource(source) }
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
            if summary.read > 0 || summary.removed > 0 { refreshNow() }
        case .scanFailed, .removed:
            refreshNow()
        }
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
        showStatus()
        stateChanged(model.state)
    }

    private func showStatus() {
        statusLabel.stringValue = status.text(
            trackCount: model.trackIDs.count, missingCount: model.missingTracks)
        statusLabel.toolTip = status.folderLines.joined(separator: "\n")
        problemsButton.isHidden = !status.hasProblems
    }

    /// Logs a failure and shows it in the status bar.
    public func report(_ message: String) {
        logger.error("\(message)")
        show(failure: message)
    }

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
            window.show(status.folderLines + issues)
        }
    }

    // MARK: Commands

    /// The list that has the keys.
    private enum List: Equatable {
        case tracks
        case pane(BrowserModel.Pane)
    }

    private var focusedList: List? {
        let responder = table.table.window?.firstResponder
        if responder === table.table { return .tracks }
        return panes.tables.first { $0.value === responder }.map { .pane($0.key) }
    }

    /// The browser's lists in the order Tab moves through them: the sidebar, the panes, the
    /// track table.
    public var focusAreas: [NSView] {
        [sidebarController.outline]
            + BrowserModel.Pane.allCases.compactMap { panes.tables[$0] } + [table.table]
    }

    /// Moves the selection of the list with the keys; false when none of them has the keys.
    public func moveSelection(_ move: RowMove, extending: Bool) -> Bool {
        switch focusedList {
        case .tracks: table.move(move, extending: extending)
        case .pane(let pane): panes.move(move, in: pane)
        case nil: return false
        }
        return true
    }

    /// Focuses the next pane to the right (or left), from the genre pane to the track table.
    public func focusPane(forward: Bool) {
        let order: [List] = BrowserModel.Pane.allCases.map { .pane($0) } + [.tracks]
        let index = focusedList.flatMap { order.firstIndex(of: $0) } ?? (order.count - 1)
        let next = order[(index + (forward ? 1 : order.count - 1)) % order.count]
        switch next {
        case .tracks: focusTracks()
        case .pane(let pane): table.table.window?.makeFirstResponder(panes.tables[pane])
        }
    }

    public func focusTracks() { table.table.window?.makeFirstResponder(table.table) }

    public func focusSidebar() {
        sidebarController.outline.window?.makeFirstResponder(sidebarController.outline)
    }

    /// Focuses the search field with its text selected.
    public func focusSearch() {
        searchField.window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    public var hasSelectedTracks: Bool { !table.table.selectedRowIndexes.isEmpty }

    /// Whether the track table has the keys.
    public var tracksHaveFocus: Bool { focusedList == .tracks }

    public func selectAllTracks() { table.table.selectAll(nil) }

    public func playSelection() { table.playSelected() }

    public func playSelectionNext() { table.playSelectedNext() }

    /// The paths of the selected tracks, in table order.
    public func selectedPaths() async throws -> [String] {
        try await model.urls(ofRows: table.table.selectedRowIndexes).map(\.path)
    }

    public var sortColumn: TrackColumn { model.sortColumn }

    public func sort(by column: TrackColumn) { Task { await model.sort(by: column) } }

    public func reverseSort() { Task { await model.reverseSort() } }

    public var canGoBack: Bool { model.history.canGoBack }
    public var canGoForward: Bool { model.history.canGoForward }

    public func back() { Task { if await model.back() { showSource() } } }

    public func forward() { Task { if await model.forward() { showSource() } } }

    /// Selects the model's source in the sidebar, listing the playlists as they are now.
    private func showSource() {
        sidebarController.show(
            folders: folders, playlists: model.playlists, source: model.filter.source)
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
        let rows = withSelection ? table.table.selectedRowIndexes : []
        edit("couldn't make the playlist \"\(name)\"") {
            try await self.model.createPlaylist(named: name, rules: rules, rows: rows)
        }
    }

    public func renamePlaylist(_ id: Int64, to name: String) {
        edit("couldn't rename the playlist") { try await self.model.renamePlaylist(id, to: name) }
    }

    public func deletePlaylist(_ id: Int64) {
        edit("couldn't delete the playlist") { try await self.model.deletePlaylist(id) }
    }

    public func setRules(_ rules: SmartRules, of id: Int64) {
        edit("couldn't change the playlist's rules") {
            try await self.model.setRules(rules, of: id)
        }
    }

    /// Adds the selected tracks to a manual playlist.
    public func addSelection(to playlist: Int64) {
        let ids = model.ids(ofRows: table.table.selectedRowIndexes)
        edit("couldn't add the tracks to the playlist") {
            _ = try await self.model.add(ids, to: playlist)
        }
    }

    /// Whether the selection can be taken out of the playlist shown.
    public var canRemoveFromPlaylist: Bool {
        model.shownPlaylist?.isManual == true && hasSelectedTracks
    }

    public func removeSelectionFromPlaylist() {
        let rows = table.table.selectedRowIndexes
        edit("couldn't remove the tracks from the playlist") {
            try await self.model.removeFromShownPlaylist(rows: rows)
        }
    }

    /// Rates the selected tracks; 0 stars clears their rating.
    public func rateSelection(_ stars: Int) {
        let rows = table.table.selectedRowIndexes
        edit("couldn't rate the tracks") { try await self.model.rate(rows: rows, stars: stars) }
    }

    /// Counts a play of the track at `path`, at `seconds` since 1970.
    public func recordPlay(_ path: String, at seconds: Double) {
        edit("couldn't count the play of \(path)") {
            try await self.model.recordPlay(path, at: seconds)
        }
    }

    public func recordSkip(_ path: String) {
        edit("couldn't count the skip of \(path)") { try await self.model.recordSkip(path) }
    }

    /// Runs an edit, then lists the playlists and selects the source as they now are. A failure
    /// is logged and shown in the status bar.
    private func edit(_ failure: String, _ body: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await body()
            } catch {
                report("\(failure): \(error)")
            }
            showSource()
        }
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
        table.selectCentered(row)
        focusTracks()
    }

    /// Every genre, artist and album in the library.
    public func allEntries() async throws -> [(BrowserModel.Pane, BrowserEntry)] {
        try await model.allEntries()
    }

    /// Shows the library narrowed to one entry, as the palette chooses it.
    public func showOnly(_ pane: BrowserModel.Pane, id: Int64) async {
        searchField.stringValue = ""
        await model.showOnly(pane, id: id)
        showSource()
        focusTracks()
    }

    /// The track ID shown at `row`, to check a palette row still points at it.
    public func trackID(at row: Int) -> Int64? {
        model.trackIDs.indices.contains(row) ? model.trackIDs[row] : nil
    }

    /// The shown tracks' names in table order; nil when the list changed while they were read.
    public func trackNames() async throws -> [TrackName] { try await model.trackNames() }

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
