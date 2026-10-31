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
            selectSource: { folder in Task { await model.setSource(folder) } },
            addFolder: { owner?.addFolder() },
            removeFolder: { path in owner?.removeFolder(path) },
            keyCommand: { chords in owner?.keyCommand(chords) ?? .unbound })
        sidebar = sidebarController
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
        sidebarController.show(folders: folders, source: saved.source)
        await model.load(saved)
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
        let source = folders.contains { $0.path == model.filter.folder } ? model.filter.folder : nil
        sidebarController.show(folders: folders, source: source)
        if source != model.filter.folder { await model.setSource(source) }
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
        statusLabel.stringValue = status.text(trackCount: model.trackIDs.count)
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

    private func showSource() { sidebarController.show(source: model.filter.folder) }

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
