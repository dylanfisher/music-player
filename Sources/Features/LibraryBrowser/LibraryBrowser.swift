import AppKit
import Library
import Log
import Settings

private let logger = moduleLogger()

/// The library half of the window: the sidebar, the genre, artist and album panes over the track
/// table, the search field, and the status line. The app places the views and handles what they
/// report; the logic is in `BrowserModel`.
@MainActor
public final class LibraryBrowser: NSObject, NSSplitViewDelegate {
    /// The longest the window waits between refreshes while a scan stores rows.
    public static let refreshIntervalSeconds = 2.0

    public let model: BrowserModel
    public let sidebar: NSViewController
    /// The panes over the track table, with the status line under them.
    public let content: NSViewController
    public let searchField = NSSearchField()

    /// Play these files as a new queue.
    public var play: (PlayRequest) -> Void = { _ in }
    /// Queue these files after the current track.
    public var playNext: ([URL]) -> Void = { _ in }
    public var tableLayoutChanged: (TrackTableLayout) -> Void = { _ in }
    public var browserHeightChanged: (Int) -> Void = { _ in }
    public var stateChanged: (BrowserState) -> Void = { _ in }
    public var addFolder: () -> Void = {}
    public var removeFolder: (String) -> Void = { _ in }
    /// Called once, when the table first draws rows.
    public var firstRowsDrawn: (() -> Void)? {
        get { table.firstRowsDrawn }
        set { table.firstRowsDrawn = newValue }
    }

    private let reader: LibraryReader
    private var table: TrackTableController!
    private var panes: PanesController!
    private var sidebarController: SidebarController!
    private let split = NSSplitView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let problemsButton = NSButton()
    private var status = LibraryStatus()
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
        self.browserHeight = browserHeight
        self.folders = folders
        model = BrowserModel(
            reader: reader, sortColumn: layout.sortColumn, ascending: layout.sortAscending)
        let content = NSViewController()
        self.content = content
        let sidebar = NSViewController()
        self.sidebar = sidebar
        super.init()

        let cache = RowCache { ids in try index.rows(ids: ids) }
        let actions = BrowserActions(
            play: { [weak self] rows, clicked in self?.playRows(rows, clicked: clicked) },
            playNext: { [weak self] rows in self?.queueNext(rows) },
            sort: { [weak self] column, ascending in
                guard let self else { return }
                Task { await self.model.setSort(column, ascending: ascending) }
            },
            layoutChanged: { [weak self] layout in self?.tableLayoutChanged(layout) },
            failed: { [weak self] message in self?.show(failure: message) })
        table = TrackTableController(model: model, cache: cache, layout: layout, actions: actions)
        panes = PanesController(model: model) { [weak self] pane, id in
            guard let self else { return }
            Task { await self.model.select(pane, id: id) }
        }
        sidebarController = SidebarController(
            selectSource: { [weak self] folder in
                guard let self else { return }
                Task { await self.model.setSource(folder) }
            },
            addFolder: { [weak self] in self?.addFolder() },
            removeFolder: { [weak self] path in self?.removeFolder(path) })
        sidebar.view = sidebarController.view
        sidebar.addChild(sidebarController)
        content.view = makeContent()
        content.addChild(table)
        content.addChild(panes)

        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)

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
        let bar = NSStackView(views: [statusLabel, problemsButton])
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
        await countIssues()
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
    public func libraryChanged(_ event: WatcherEvent) {
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
            await countIssues()
        }
    }

    private func countIssues() async {
        do {
            status.fileIssueCount = Set(try await reader.fileIssues().map(\.path)).count
        } catch {
            show(failure: "couldn't read the library's problems: \(error)")
        }
        showStatus()
    }

    private func apply(_ change: BrowserChange) {
        let selection = table.selectedIDs
        if change.panes { panes.reload() }
        table.reload(change, keeping: selection)
        showStatus()
        stateChanged(model.state)
    }

    private func showStatus() {
        statusLabel.stringValue = status.text(trackCount: model.trackIDs.count)
        statusLabel.toolTip = status.folderLines.joined(separator: "\n")
        problemsButton.isHidden = !status.hasProblems
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
                logger.error("couldn't read the tracks to play: \(error)")
                show(failure: "couldn't read the tracks to play: \(error)")
            }
        }
    }

    private func queueNext(_ rows: IndexSet) {
        Task {
            do {
                playNext(try await model.urls(ofRows: rows))
            } catch {
                logger.error("couldn't read the tracks to queue: \(error)")
                show(failure: "couldn't read the tracks to queue: \(error)")
            }
        }
    }

    @objc private func showProblems() {
        Task {
            let issues: [String]
            do {
                issues = try await reader.fileIssues().map(\.description)
            } catch {
                issues = ["couldn't read the library's problems: \(error)"]
            }
            let window = problems ?? ProblemsWindow()
            problems = window
            window.show(status.folderLines + issues)
        }
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
