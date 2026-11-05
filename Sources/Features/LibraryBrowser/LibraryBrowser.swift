import AppKit
import Artwork
import BarView
import Commands
import DisplayText
import KeyChord
import Library
import Log
import Playback
import Settings

private let logger = moduleLogger()

/// The library half of the window: the sidebar, the browser's three columns over the track
/// table, the search field, and the status line. The app places the views and handles what they
/// report; the logic is in `BrowserModel`.
@MainActor
public final class LibraryBrowser: NSObject, NSSplitViewDelegate, NSSearchFieldDelegate {
    /// The longest the window waits between refreshes while a scan stores rows.
    static let refreshIntervalSeconds = 2.0
    /// The space between the status bar's views and at its ends.
    static let statusSpacingPoints: CGFloat = 10

    let model: BrowserModel
    public let sidebar: NSViewController
    /// The panes over the track table, with the status line under them.
    public let content: NSViewController
    public let searchField = NSSearchField()
    /// Takes the watcher's events on any thread and hands them to the browser in the order they
    /// were sent, so a late progress report never lands after its scan's outcome.
    public let watcherEvents: @Sendable (WatcherEvent) -> Void

    /// Play these files as a new queue.
    public var play: (PlayRequest) -> Void = { _ in }
    /// Play this track now, and the queue it comes with once that's read.
    public var playStart: (PlayStart) -> Void = { _ in }
    /// Queue these files after the current track.
    public var playNext: ([URL]) -> Void = { _ in }
    /// Where playback stands, which a play's step keeps to put back; nil without an output.
    public var currentPlayback: () async -> PlaybackSpot? = { nil }
    /// Puts playback back where Back or Forward over a play found it.
    public var restorePlayback: (PlaybackSpot) async -> Void = { _ in }
    /// The last of Back, Forward and plays' steps, each of which runs after the one before, so
    /// a second ⌘[ reads the playback the first put back.
    private(set) var stepping: Task<Void, Never>?
    /// Queue these files after the last track.
    public var addToQueue: ([URL]) -> Void = { _ in }
    /// The context menu of the track table and the timeline. A right-click selects the row it's
    /// on first, so the menu's commands act on the selection.
    public var trackMenu: NSMenu? {
        didSet {
            table.table.menu = trackMenu
            timeline.table.menu = trackMenu
        }
    }
    public var tableLayoutChanged: (TrackTableLayout) -> Void = { _ in }
    /// Which totals the status bar shows. A click on them moves to the next and reports it.
    public var statusTotals = AppState().statusTotals.defaultValue {
        didSet { showStatus() }
    }
    public var statusTotalsChanged: (StatusTotals) -> Void = { _ in }
    /// What the list's rows and the selected rows add up to, each read again after it changes.
    private(set) var listTotals = TrackTotals()
    private(set) var selectionTotals = TrackTotals()
    /// The reads of the totals under way, by the totals each reads.
    private var totalsReads:
        [ReferenceWritableKeyPath<LibraryBrowser, TrackTotals>: Task<Void, Never>] = [:]
    /// How many messages the bar has shown, so a read of the totals that ends after one leaves
    /// the message showing.
    private var messagesShown = 0
    public var browserHeightChanged: (Int) -> Void = { _ in }
    public var stateChanged: (BrowserState) -> Void = { _ in }
    /// Called after each refresh for a library change, so other views can read their rows again.
    public var libraryRefreshed: () -> Void = {}
    /// The sidebar's context menu: ask before deleting this playlist, and open its rules.
    public var confirmDeletePlaylist: (Playlist) -> Void = { _ in }
    public var editRules: (Playlist) -> Void = { _ in }
    /// Called after the user changed plays, ratings or playlists, which go in the sync log.
    public var edited: () -> Void = {}
    /// Called with the paths of removed tracks the user restored, whose folders need a scan.
    public var restored: ([String]) -> Void = { _ in }
    /// Moves the files Remove… was confirmed for to the Trash; tests replace it.
    var trash: ([URL]) async -> TrashOutcome = moveToTrash
    /// The watched folders as the settings hold them, for Locate… to check a folder is in one.
    public var watchedFolders: () -> [WatchedFolder] = { [] }
    /// Adds the folder to the watched folders, for Locate….
    public var watch: (URL) -> Void = { _ in }
    /// Locate…'s questions, which tests replace.
    var chooseFolder: @MainActor (String, NSWindow, @escaping (URL) -> Void) -> Void =
        askForFolder
    var confirmWatch: @MainActor (String, NSWindow, @escaping (Bool) -> Void) -> Void =
        askToWatch
    /// Runs the command a key press in one of the browser's lists is bound to.
    public var keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome = { _ in .unbound }
    /// Called once, when the table or the timeline first draws rows, or once loading finds none
    /// to draw.
    public var firstRowsDrawn: (() -> Void)? {
        get { table.firstRowsDrawn }
        set { table.firstRowsDrawn = newValue }
    }

    let reader: LibraryReader
    private let index: LibraryIndex
    let table: TrackTableController
    let timelineModel: TimelineModel
    /// Shown in place of the panes and the track table while the timeline is the source.
    let timeline: TimelineController
    /// The timeline's load since it last showed, which Show Current Track waits for.
    private var timelineLoad: Task<Void, Never>?
    private let panes: PanesController
    private let sidebarController: SidebarController
    private let split = NSSplitView()
    /// The scan progress and the leading columns, the center column centered on the window,
    /// and the trailing columns and the problems button, each edge in a stack so what's hidden
    /// takes no width.
    private let statusLeading = NSStackView()
    private let statusColumns = BarColumns()
    private let statusTrailing = NSStackView()
    private lazy var statusBar = CenteredRow(
        leading: statusLeading, middle: statusColumns.center, trailing: statusTrailing,
        spacing: Self.statusSpacingPoints, inset: Self.statusSpacingPoints)
    private(set) var statusLayout = StatusBarLayout(columns: .defaultStatusBar, style: .minimal)
    /// The views of the playing track's parts, which the app gives.
    private var statusPartViews: [StatusPart: NSView] = [:]
    private var statusHeight: NSLayoutConstraint?
    private var statusArtHeight: NSLayoutConstraint?
    /// The status bar on glass, or the toolbar's material before macOS 26, laid over the bottom
    /// of the track table and the timeline, and showing and hiding with them.
    private(set) lazy var statusArea = statusBackground(around: statusBar, border: statusBorder)
    /// The line along the status bar's top, in the separator's color, as the track table
    /// header's line along its bottom.
    let statusBorder = NSBox()
    let statusLabel = NSTextField(labelWithString: "")
    private let scanIndicator = NSProgressIndicator()
    /// Whether the scan bar moves on its own, which only it does while the status bar shows.
    private(set) var scanIndicatorAnimates = false
    private let scanLabel = NSTextField(labelWithString: "")
    private let problemsButton = NSButton()
    private(set) var status = LibraryStatus()
    private var browserHeight: Int
    private var lastRefresh = Date.distantPast
    private var refreshPending = false
    private(set) var problems: ProblemsWindow?
    let health: HealthModel
    /// Set from the read of another player's library until its preview sheet closes.
    private var isImporting = false
    private(set) var importSheet: PlayerImportSheet?
    /// What the last import wrote, whose misses Locate… matches again.
    var lastImport: ImportPlan?
    /// A Locate… waiting for the scan of the folder it had watched, and the miss it was for.
    private(set) var pendingLocate: (folder: String, miss: String)?
    /// The file an import from Swinsian reads its column layout from; tests replace it.
    var swinsianPreferences = SwinsianColumns.preferencesURL
    /// True from Resolve Lost Stats until its last sheet closes, so one is open at a time.
    private var isResolvingLostStats = false
    private(set) var lostStatsSheet: LostStatsSheet?

    /// `index` is a connection for the main thread, which fetches the table's rows a page at a
    /// time: a page is one primary-key lookup per row and takes well under a millisecond.
    public init(
        reader: LibraryReader, index: LibraryIndex, layout: TrackTableLayout, browserHeight: Int,
        groupByAlbumArtist: Bool, thumbnails: ThumbnailStore?
    ) {
        self.reader = reader
        self.index = index
        self.browserHeight = browserHeight
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
            move: { ids, row in
                owner?.edit("couldn't move the tracks") { try await model.move(ids, toRow: row) }
            },
            sort: { column, ascending in
                Task { await model.setSort(column, ascending: ascending) }
            },
            layoutChanged: { layout in owner?.tableLayoutChanged(layout) },
            failed: { message in owner?.show(failure: message) },
            keyCommand: { chords in owner?.keyCommand(chords) ?? .unbound })
        table = TrackTableController(
            model: model, cache: cache, layout: layout, actions: actions, thumbnails: thumbnails)
        table.selectionChanged = { owner?.readSelectionTotals() }
        table.rateClicked = { id, stars in
            owner?.edit("couldn't rate the track") { try await model.rate([id], stars: stars) }
        }
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
                    owner?.start(request)
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
            keyCommand: { chords in owner?.keyCommand(chords) ?? .unbound },
            failed: { message in owner?.show(failure: message) })
        panes = PanesController(
            model: model,
            select: { grouping, value in Task { await model.select(grouping, value) } },
            setGrouping: { grouping, column in
                Task { await model.setGrouping(grouping, ofColumn: column) }
            },
            keyCommand: { chords in owner?.keyCommand(chords) ?? .unbound },
            focusPane: { forward in owner?.focusPane(forward: forward) })
        sidebarController = SidebarController(
            // The sidebar shows the model's source after, which stays put when it fails.
            selectSource: { source in
                Task {
                    await model.setSource(source)
                    owner?.showSource()
                }
            },
            keyCommand: { chords in owner?.keyCommand(chords) ?? .unbound })
        sidebar = sidebarController
        sidebarController.dropTracks = { playlist, ids in
            owner?.edit("couldn't add the tracks to the playlist", entriesChange: true) {
                _ = try await model.add(ids, to: playlist)
            }
        }
        sidebarController.dropPlaylistFiles = { urls in owner?.importPlaylists(from: urls) }
        sidebarController.renamePlaylist = { id, name in owner?.renamePlaylist(id, to: name) }
        sidebarController.duplicatePlaylist = { playlist in owner?.duplicatePlaylist(playlist) }
        sidebarController.deletePlaylist = { playlist in owner?.confirmDeletePlaylist(playlist) }
        sidebarController.editRules = { playlist in owner?.editRules(playlist) }
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
        model.listPlace = { [weak self] in self?.listPlace() ?? ([], nil) }
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

        // The lists' font, so the bar reads as part of the tables, as Swinsian's does.
        statusLabel.font = TextCell.font
        statusLabel.lineBreakMode = .byTruncatingTail
        scanLabel.font = TextCell.font
        scanLabel.textColor = .secondaryLabelColor
        scanLabel.lineBreakMode = .byTruncatingTail
        scanIndicator.style = .bar
        scanIndicator.controlSize = .small
        scanIndicator.minValue = 0
        scanIndicator.maxValue = 1
        scanIndicator.widthAnchor.constraint(equalToConstant: 100).isActive = true
        problemsButton.bezelStyle = .inline
        problemsButton.image = NSImage(
            systemSymbolName: SymbolName.problem, accessibilityDescription: nil)
        problemsButton.imagePosition = .imageLeading
        problemsButton.target = self
        problemsButton.action = #selector(showProblems)
        statusLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(showNextTotals)))
        statusLabel.alignment = .center
        for view in [scanIndicator, scanLabel] { statusLeading.addArrangedSubview(view) }
        statusTrailing.addArrangedSubview(problemsButton)
        for stack in [statusLeading, statusTrailing] {
            stack.detachesHiddenViews = true
            stack.distribution = .fill
            stack.spacing = Self.statusSpacingPoints
            stack.alignment = .centerY
            // Only a flexible column in it stretches it, toward the center.
            stack.setHuggingPriority(.init(1), for: .horizontal)
        }
        problemsButton.font = TextCell.font
        statusHeight = statusArea.heightAnchor.constraint(equalToConstant: 0)
        statusHeight?.isActive = true
        layOutStatusBar()
        scanLabel.setContentCompressionResistancePriority(
            CenteredRow.textCompressionPriority, for: .horizontal)
        for view in [scanIndicator, scanLabel, problemsButton] { view.isHidden = true }
        timeline.view.isHidden = true
        let stack = NSStackView(views: [split, timeline.view])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.detachesHiddenViews = true
        for view in [split, timeline.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // The bar lies over the lists' bottom, so their rows scroll under it.
        let container = NSView()
        for view in [stack, statusArea] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusArea.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
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
        showSource()
        await countIssues()
    }

    /// Scrolls the table through every row as a scroll-bar drag does, drawing each screenful,
    /// and passes each row to `visit`. Returns each screenful's time to scroll and draw, in
    /// milliseconds. For measuring scrolling, and memory once the whole library has been on
    /// screen.
    public func scrollThroughEveryRow(_ visit: (TrackRow) -> Void) -> [Double] {
        table.scrollThroughEveryRow(visit)
    }

    /// Scrolls the track table in trackpad flicks, timing each frame, then pages down and waits
    /// for the art on screen (ADR 0073). Each art read waits `artDelaySeconds` first, as on a NAS. `.scan` also
    /// reports a scan's progress as often as the watcher does, so the browser refreshes as it
    /// does during a scan.
    public func measureScroll(_ scrollCase: ScrollCase, artDelaySeconds: Double) async
        -> ScrollReport
    {
        let reads = SlowArtReads(delaySeconds: artDelaySeconds)
        table.readArt = reads.read
        let folder = watchedFolders().first?.path ?? ""
        let paging = scrollCase == .pages
        let table = table
        let measurement = ScrollMeasurement(
            table: table, frames: paging ? 0 : ScrollMeasurement.frames,
            pageDowns: paging ? ScrollMeasurement.pageDowns : 1,
            intervalSeconds: LibraryWatcher.progressIntervalSeconds,
            move: scrollCase == .resize ? { table.resizeFrame($0) } : nil
        ) { [weak self] in
            guard scrollCase == .scan else { return }
            self?.libraryChanged(.scanning(folder: folder, ScanProgress()))
        }
        let refreshed = libraryRefreshed
        libraryRefreshed = { [weak measurement] in
            measurement?.refreshed()
            refreshed()
        }
        let result = await measurement.run()
        libraryRefreshed = refreshed
        return ScrollReport(
            framesMs: result.framesMs, refreshFramesMs: result.refreshFramesMs,
            lastCoverMs: result.lastCoverMs, artReads: reads.count,
            pageCoversMs: result.pageCoversMs)
    }

    /// What the watcher reported. Refreshes as rows arrive, at most every
    /// `refreshIntervalSeconds` during a scan and at once when one ends.
    func libraryChanged(_ event: WatcherEvent) {
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
        case .keptIndex:
            // No scan ends for it at launch, so the first report runs now.
            if health.report == nil && !health.isRunning { runHealth() }
        case .scanFailed:
            refreshNow()
        case .removed:
            refreshNow()
            runHealth()
        case .folders:
            // The rewrite gave the tracks under them new paths.
            refreshNow()
        case .synced(let report):
            if report.changed {
                refreshNow()
                runHealth()
            }
        case .syncFailed, .launchScansEnded:
            break
        }
        guard let pending = pendingLocate else { return }
        switch event {
        case .scanned(let folder, _) where isPath(pending.folder, inOrAt: folder):
            pendingLocate = nil
            Task { await matchAgain(pending.miss, under: pending.folder) }
        case .scanFailed(let folder, _) where isPath(pending.folder, inOrAt: folder):
            // The status line says why; a later scan of the folder isn't the user asking again.
            pendingLocate = nil
        default: break
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
                    self?.edited()
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

    // MARK: Removing tracks

    /// Asks over `window` whether to remove the selected tracks from the library, or to move
    /// their files to the Trash as well (ADR 0050).
    public func removeSelection(over window: NSWindow) {
        guard let ids = selectedTrackIDs(else: "couldn't remove the tracks"), !ids.isEmpty
        else { return }
        askToRemove(ids.count, over: window) { [weak self] choice in
            guard let choice else { return }
            Task { await self?.remove(ids, choice) }
        }
    }

    /// Removes the tracks `ids` as the user chose. Only the files the Trash took leave the
    /// library on `.trash`; the status bar says why the rest stayed.
    func remove(_ ids: [Int64], _ choice: RemovalChoice) async {
        do {
            switch choice {
            case .library:
                try await reader.removeFromLibrary(trackIDs: ids)
            case .trash:
                let paths = try await reader.paths(ids: ids)
                let urls = Dictionary(
                    uniqueKeysWithValues: ids.compactMap { id in
                        paths[id].map { (URL(fileURLWithPath: $0, isDirectory: false), id) }
                    })
                let outcome = await trash(Array(urls.keys))
                try await reader.forgetTrashed(trackIDs: outcome.moved.compactMap { urls[$0] })
                if let failure = outcome.failure {
                    report(
                        "couldn't move \(urls.count - outcome.moved.count) of the files to the"
                            + " Trash: \(failure)")
                }
            }
        } catch {
            report("couldn't remove the tracks: \(error)")
        }
        refreshNow()
        runHealth()
    }

    /// Offers the removed tracks over `window`, to restore one or all of them; after one, the
    /// rest are offered again.
    public func restoreRemoved(over window: NSWindow) {
        Task { [weak self] in
            guard let self else { return }
            let removed: [RemovedPath]
            do {
                removed = try await reader.removedPaths()
            } catch {
                return report("couldn't read the removed tracks: \(error)")
            }
            guard !removed.isEmpty else { return show(failure: "No removed tracks to restore") }
            askToRestore(removed, over: window) { [weak self] ids in
                guard !ids.isEmpty else { return }
                Task {
                    await self?.restore(ids)
                    if ids.count < removed.count { self?.restoreRemoved(over: window) }
                }
            }
        }
    }

    /// Lets scans add the removed tracks `ids` again, and has their folders scanned.
    func restore(_ ids: [Int64]) async {
        do {
            restored(try await reader.restoreRemoved(ids))
        } catch {
            report("couldn't restore the removed tracks: \(error)")
        }
        runHealth()
    }

    private func runHealth() {
        Task { await health.run() }
    }

    /// A newer report: the sidebar counts it, and a check shown lists it.
    private func healthChanged() {
        guard let report = health.report else { return }
        sidebarController.show(health: report)
        if case .health = model.filter.source {
            Task {
                await model.refresh()
                refreshProblems()
            }
        } else {
            showStatus()
            refreshProblems()
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
            await signposted(.refresh) {
                await model.refresh()
                if showsTimeline { timelineModel.refresh() }
                libraryRefreshed()
            }
            await countIssues()
        }
    }

    /// On the refresh connection, since a refresh is what most often asks.
    private func countIssues() async {
        let reader = reader.refreshes
        do {
            status.dismissed = try await reader.dismissedProblems()
            let issues = try await reader.fileIssues().filter {
                !status.dismissed.contains($0.description)
            }
            status.fileIssueCount = Set(issues.map(\.path)).count
        } catch {
            report(problemsUnreadable(error))
        }
        showStatus()
    }

    private func apply(_ change: BrowserChange) {
        if change.panes { panes.reload() }
        table.reload(change)
        if change.showsEverythingAgain { selectPlayingTrack() }
        showTimelineIfItIsTheSource()
        runHealthIfShownFirst()
        readTotals(
            of: model.trackIDs, into: \.listTotals,
            on: change.reason == .libraryChanged ? reader.refreshes : reader)
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
            timelineLoad = Task { await timelineModel.load() }
        } else {
            timelineModel.clear()
        }
        if hadKeys { focusTracks() }
    }

    private func showStatus() {
        let check: HealthCheck? =
            if case .health(let check) = model.filter.source { check } else { nil }
        let found = check.flatMap { health.report?[$0] }
        status.healthProblems =
            if let check, let found { healthProblems(found, of: check) } else { [] }
        status.healthOtherCount = found?.otherCount ?? 0
        statusLabel.stringValue = status.summary(
            list: listTotals, selection: selectionTotals,
            shown: statusTotals, missingCount: model.missingTracks,
            playCount: showsTimeline ? timelineModel.playCount : nil)
        statusLabel.toolTip = nil
        statusLabel.isHidden = !statusLayout.showsTotals
        fitStatusBarHeight()
        scanLabel.stringValue = status.scanText ?? ""
        scanLabel.isHidden = status.scanText == nil
        showScanProgress()
        problemsButton.title = status.problemsTitle ?? ""
        problemsButton.toolTip = status.problemLines.joined(separator: "\n")
        problemsButton.isHidden = status.problemsTitle == nil
    }

    private func readSelectionTotals() {
        readTotals(
            of: model.ids(ofRows: table.table.selectedRowIndexes), into: \.selectionTotals,
            on: reader)
    }

    /// Adds up `ids` on the reader, after the rows show rather than before, then shows the
    /// totals unless a message showed meanwhile. A newer read of the same totals replaces one
    /// under way.
    private func readTotals(
        of ids: [Int64], into totals: ReferenceWritableKeyPath<LibraryBrowser, TrackTotals>,
        on reader: LibraryReader
    ) {
        totalsReads[totals]?.cancel()
        guard !ids.isEmpty else {
            totalsReads[totals] = nil
            self[keyPath: totals] = TrackTotals()
            showStatus()
            return
        }
        let shown = messagesShown
        totalsReads[totals] = Task { [weak self, reader] in
            do {
                let read = try await reader.trackTotals(ids: ids)
                guard !Task.isCancelled, let self else { return }
                self[keyPath: totals] = read
                if messagesShown == shown { showStatus() }
            } catch {
                guard !Task.isCancelled else { return }
                self?.report("couldn't add up the tracks' sizes and lengths: \(error)")
            }
        }
    }

    /// A bar that fills as the scans read, or moves on its own while one still lists folders.
    private func showScanProgress() {
        let scans = status.scanText != nil
        scanIndicator.isHidden = !scans
        insetStatusBar()
        let fraction = status.scanFraction
        scanIndicator.isIndeterminate = fraction == nil
        if let fraction { scanIndicator.doubleValue = fraction }
        // A hidden bar would keep animating and drawing.
        let animates = scans && fraction == nil && !statusArea.isHidden
        guard animates != scanIndicatorAnimates else { return }
        scanIndicatorAnimates = animates
        if animates {
            scanIndicator.startAnimation(nil)
        } else {
            scanIndicator.stopAnimation(nil)
        }
    }

    /// The bar's leading inset: the art's top and bottom inset when the art starts the bar, so
    /// it has as much space on its left, and the spacing otherwise.
    private func insetStatusBar() {
        statusBar.leadingInset =
            statusLayout.startsWithArt(scanning: status.scanText != nil)
            ? StatusBarLayout.artInsetPoints : Self.statusSpacingPoints
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

    /// The system beep; tests count it instead.
    var beep: () -> Void = { NSSound.beep() }

    @objc func showNextTotals() {
        statusTotals = statusTotals.next
        statusTotalsChanged(statusTotals)
    }

    /// What the status bar says, for tests.
    var statusText: String { statusLabel.stringValue }

    /// The problems button's title while it shows, for tests.
    var problemsButtonTitle: String? { problemsButton.isHidden ? nil : problemsButton.title }

    private func show(failure message: String) {
        messagesShown += 1
        statusLabel.stringValue = message
        statusLabel.toolTip = message
        statusLabel.isHidden = false
        fitStatusBarHeight()
    }

    @objc private func searchChanged() {
        let text = searchField.stringValue
        Task { await model.setSearch(text) }
    }

    private func playRows(_ rows: IndexSet, clicked: Int) {
        Task {
            do {
                guard let start = try await model.playStart(selected: rows, clicked: clicked)
                else { return }
                let played = PlaybackSpot(
                    queue: [start.url], index: 0, seconds: 0, status: .playing)
                recordPlay(played) { self.playStart(start) }
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

    @objc func showProblems() {
        Task {
            let rows = await problemRows()
            let window = problems ?? makeProblemsWindow()
            problems = window
            window.show(rows)
        }
    }

    /// Lists the problems again in the Problems window, if it's open.
    private func refreshProblems() {
        guard let problems, problems.window.isVisible else { return }
        Task { problems.refresh(await problemRows()) }
    }

    /// The status's problems, then each file's, leaving out those dismissed.
    private func problemRows() async -> [Problem] {
        do {
            let issues = try await reader.fileIssues().map(\.description)
            return status.problems
                + issues.filter { !status.dismissed.contains($0) }.map { Problem($0) }
        } catch {
            return status.problems + [Problem(problemsUnreadable(error))]
        }
    }

    private func makeProblemsWindow() -> ProblemsWindow {
        let window = ProblemsWindow()
        window.act = { [weak self] action, selected in
            Task { await self?.fix(selected, by: action) }
        }
        return window
    }

    /// Does `action` to the problems `selected`, the rows its button acts on. Remove and Restore
    /// run the health report, which lists the problems again when it ends.
    func fix(_ selected: [Problem], by action: ProblemAction) async {
        switch action {
        case .dismiss, .dismissAll:
            do {
                try await reader.dismissProblems(selected.map(\.line))
            } catch {
                report("couldn't dismiss the problems: \(error)")
            }
            await countIssues()
            refreshProblems()
        case .remove:
            guard let ids = action.pathIDs(of: selected) else { return }
            do {
                try await reader.removeFromLibrary(trackIDs: ids)
            } catch {
                report("couldn't remove the tracks: \(error)")
            }
            runHealth()
        case .restore:
            guard let ids = action.pathIDs(of: selected) else { return }
            await restore(ids)
        case .locate:
            guard let miss = action.missingPath(of: selected), let window = problems?.window
            else { return }
            chooseFolder(miss, window) { [weak self] folder in
                Task { await self?.locate(miss, in: folder) }
            }
        }
    }

    /// Locate… for the last import's miss `miss`, now under `folder`: matches the misses again
    /// at once when a watched folder holds `folder`, or offers to watch it and matches them
    /// once its scan ends.
    func locate(_ miss: String, in folder: URL) async {
        let path = folder.standardizedFileURL.path
        let roots: [String]
        do {
            roots = try await reader.lastKnownFolders(watchedFolders()).map(\.path)
        } catch {
            return report("couldn't read the watched folders: \(error)")
        }
        guard roots.contains(where: { isPath(path, inOrAt: $0) }) else {
            guard let window = problems?.window else { return }
            confirmWatch(path, window) { [weak self] yes in
                guard yes, let self else { return }
                pendingLocate = (path, miss)
                watch(folder)
            }
            return
        }
        await matchAgain(miss, under: path)
    }

    /// Imports the last import's misses under the folder `miss` was in again, from `folder`,
    /// and lists those still missing.
    func matchAgain(_ miss: String, under folder: String) async {
        guard var plan = lastImport else { return report("couldn't locate: no import to match") }
        let prefix = PathPrefix(locating: miss, in: folder)
        let misses = plan.misses(under: prefix.from)
        do {
            let written = try await model.applyImport(misses, prefix: prefix)
            let still = Set(written.unmatched + written.unreadFormat)
            let found = Set(misses.tracks.map(\.path).filter { !still.contains(prefix.apply($0)) })
            plan.unmatched.removeAll { found.contains($0) }
            lastImport = plan
            status.playlistFileReport = plan.problems
            showStatus()
            show(
                failure:
                    "Located \(number(found.count)) of \(tracks(misses.tracks.count)) in"
                    + " \(terminalSafe(folder))")
            refreshProblems()
            edited()
        } catch {
            report(terminalSafe("couldn't match the tracks in \(folder): \(error)"))
        }
    }

    // MARK: Commands

    /// The list that has the keys.
    private enum List: Equatable {
        case tracks
        /// A browser column, by its place.
        case pane(Int)
        case timeline
    }

    private var focusedList: List? {
        let responder = table.table.window?.firstResponder
        if responder === table.table { return .tracks }
        if responder === timeline.table { return .timeline }
        return panes.tables.firstIndex { $0 === responder }.map { .pane($0) }
    }

    /// The browser's lists in the order Tab moves through them: the sidebar, the panes, the
    /// track table.
    public var focusAreas: [NSView] {
        if showsTimeline { return [sidebarController.outline, timeline.table] }
        let shownPanes = isBrowserVisible ? panes.tables : []
        return [sidebarController.outline] + shownPanes + [table.table]
    }

    /// Moves the selection of the list with the keys; false when none of them has the keys.
    public func moveSelection(_ move: RowMove, extending: Bool) -> Bool {
        switch focusedList {
        case .tracks: table.move(move, extending: extending)
        case .pane(let column): panes.move(move, in: column)
        case .timeline: timeline.move(move, extending: extending)
        case nil: return false
        }
        return true
    }

    /// Focuses the next pane to the right (or left), from the genre pane to the track table.
    public func focusPane(forward: Bool) {
        // The timeline has no panes, and hidden ones take no keys.
        guard !showsTimeline, isBrowserVisible else {
            focusTracks()
            return
        }
        let order: [List] = panes.tables.indices.map { .pane($0) } + [.tracks]
        let index = focusedList.flatMap { order.firstIndex(of: $0) } ?? (order.count - 1)
        let next = order[(index + (forward ? 1 : order.count - 1)) % order.count]
        switch next {
        case .tracks, .timeline: focusTracks()
        case .pane(let column): table.table.window?.makeFirstResponder(panes.tables[column])
        }
    }

    /// Gives the keys to the track table, or to the timeline while it shows.
    public func focusTracks() {
        let list = shownList.table
        list.window?.makeFirstResponder(list)
    }

    public func focusSidebar() {
        sidebarController.outline.window?.makeFirstResponder(sidebarController.outline)
    }

    /// Whether the search field is in the window, which it isn't once the user takes it out
    /// of the toolbar.
    public var isSearchShown: Bool { searchField.window != nil }

    /// Empties the search field and shows what it hid, so a search can't stay on once its
    /// field is out of the window.
    public func clearSearch() {
        guard !searchField.stringValue.isEmpty else { return }
        searchField.stringValue = ""
        searchChanged()
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

    /// Whether Remove… has tracks to act on: the track table or the timeline has the keys and a
    /// selection. ⌫ in the sidebar or a pane runs nothing on tracks the user isn't looking at.
    public var canRemoveSelection: Bool {
        (focusedList == .tracks || focusedList == .timeline) && hasSelectedTracks
    }

    public func selectAllTracks() {
        (showsTimeline ? timeline.table : table.table).selectAll(nil)
    }

    public func playSelection() {
        if showsTimeline { timeline.playSelected() } else { table.playSelected() }
    }

    public func playSelectionNext() {
        if showsTimeline { timeline.playSelectedNext() } else { table.playSelectedNext() }
    }

    /// Queues the selected tracks after the last track.
    public func addSelectionToQueue() {
        let onTimeline = showsTimeline
        let rows = (onTimeline ? timeline : table).table.selectedRowIndexes
        Task {
            do {
                addToQueue(
                    onTimeline
                        ? try timelineModel.urls(ofRows: rows)
                        : try await model.urls(ofRows: rows))
            } catch {
                reportCommand("couldn't queue the selection", error)
            }
        }
    }

    /// Shows the library narrowed to the first selected track's artist or album, with that
    /// track selected, as Show Artist and Show Album do. Beeps when it has none.
    public func showSelection(in pane: BrowserModel.Pane) {
        let failure = "couldn't show the track's \(pane.title.lowercased())"
        guard let track = selectedTrackIDs(else: failure)?.first else { return }
        let entry: Int64?
        do {
            let entries = try index.entryIDs(ofTrack: track, model.filter)
            entry =
                switch pane {
                case .album: entries.album
                case .artist: entries.artist
                case .genre: nil
                }
        } catch {
            reportCommand(failure, error)
            return
        }
        guard let entry else { return beep() }
        Task {
            // With no column showing that kind of entry, the track is shown in the library.
            guard await showOnly(pane, id: entry) else { return await reveal(trackID: track) }
            if let row = model.trackIDs.firstIndex(of: track) { showRow(row) }
        }
    }

    /// The manual playlists that list the first selected track, for Show in Playlist.
    public func playlistsHoldingSelection() throws -> [Playlist] {
        guard let track = try selectedTrackIDs().first else { return [] }
        return try index.playlists(holding: track)
    }

    /// Shows the playlist `id` with the first selected track selected.
    public func showSelection(inPlaylist id: Int64) {
        guard let track = selectedTrackIDs(else: "couldn't show the playlist")?.first else {
            return
        }
        Task {
            await model.setSource(.playlist(id))
            showSource()
            if let row = model.trackIDs.firstIndex(of: track) {
                showRow(row)
            } else {
                focusTracks()
            }
        }
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

    /// Undoes the last step: shows the window as the step before had it, and puts back the
    /// playback a play replaced (ADR 0090).
    public func back() { inTurn { [weak self] in await self?.step(back: true) } }

    public func forward() { inTurn { [weak self] in await self?.step(back: false) } }

    private func step(back: Bool) async {
        let playing = await currentPlayback()
        guard let move = back ? model.back(playing: playing) : model.forward(playing: playing)
        else { return }
        if let playback = move.playback { await restorePlayback(playback) }
        await model.show(move.window)
        searchField.stringValue = model.filter.search
        showSource()
        guard !showsTimeline else { return }
        let rows = model.rows(holding: move.window.selection)
        table.select(rows)
        if let scroll = move.window.scroll {
            table.restore((scroll.id, scroll.offset), row: model.rows(holding: [scroll.id]).first)
        } else if let first = rows.first {
            table.center(first)
        }
    }

    /// Runs `work` after the steps before it.
    private func inTurn(_ work: @escaping @MainActor () async -> Void) {
        let previous = stepping
        stepping = Task {
            await previous?.value
            await work()
        }
    }

    /// Takes a play's step, keeping the playback it replaces, then plays. Without an output
    /// nothing plays, so no step is taken.
    private func recordPlay(_ played: PlaybackSpot, then play: @escaping @MainActor () -> Void) {
        inTurn { [weak self] in
            guard let self else { return }
            if let replaced = await currentPlayback() {
                model.recordPlay(played, replacing: replaced)
            }
            play()
        }
    }

    /// Plays `request` as a step Back can undo.
    private func start(_ request: PlayRequest) {
        let played = PlaybackSpot(
            queue: request.urls, index: request.first, seconds: 0, status: .playing)
        recordPlay(played) { [weak self] in self?.play(request) }
    }

    /// The track table's selected tracks and first visible track, which a step keeps. The
    /// timeline's rows are plays, and it loads afresh each time it shows, so it keeps neither.
    private func listPlace() -> (selection: Set<Int64>, scroll: WindowPlace.Scroll?) {
        guard !showsTimeline else { return ([], nil) }
        let anchor = table.scrollAnchor(in: model.trackIDs)
        return (
            Set(model.ids(ofRows: table.table.selectedRowIndexes)),
            anchor.map { WindowPlace.Scroll(id: $0.id, offset: $0.offset) }
        )
    }

    /// Selects the model's source in the sidebar, listing the playlists as they are now.
    private func showSource() {
        sidebarController.show(playlists: model.playlists, source: model.filter.source)
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

    /// Copies a playlist and shows the copy.
    public func duplicatePlaylist(_ playlist: Playlist) {
        edit("couldn't duplicate the playlist", entriesChange: true) {
            try await self.model.duplicatePlaylist(playlist)
        }
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
            finishPlaylistFile(summaries.joined(separator: " · "), lines.map { Problem($0) })
            playlistEntriesChanged()
            edited()
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
                finishPlaylistFile(summary, lines.map { Problem($0) })
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
                let preferences = swinsianPreferences
                let (library, columns) = try await Task.detached {
                    let columns: Result<SwinsianColumns, any Error>? =
                        player == .swinsian
                        ? Result { try SwinsianColumns(preferencesAt: preferences) } : nil
                    return (try PlayerLibrary.read(player, at: url), columns)
                }.value
                let session = PlayerImportSession(
                    shown: try await model.importPlan(library, prefix: nil)
                ) { [model] prefix in try await model.importPlan(library, prefix: prefix) }
                let sheet = PlayerImportSheet(session: session, player: player, columns: columns)
                sheet.confirmed = { [weak self] plan, columns in self?.apply(plan, columns) }
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

    /// Writes `plan`, then shows Swinsian's `columns` when they were chosen and saves them as the
    /// table's layout.
    private func apply(_ plan: ImportPlan, _ columns: SwinsianColumns?) {
        Task {
            do {
                let written = try await model.applyImport(plan.library, prefix: plan.prefix)
                lastImport = written
                // Its miss was the old import's.
                pendingLocate = nil
                showSource()
                var summary = written.summary
                var rows = written.problems
                if let columns {
                    let layout = columns.layout(over: table.layout)
                    table.showColumns(layout)
                    await model.setSort(layout.sortColumn, ascending: layout.sortAscending)
                    tableLayoutChanged(table.layout)
                    summary += " · column layout"
                    rows += columns.detailLines.map { Problem($0) }
                }
                finishPlaylistFile(summary, rows)
                playlistEntriesChanged()
                edited()
            } catch {
                report(
                    terminalSafe(
                        "couldn't import from \(plan.library.player.title); nothing changed: \(error)"
                    ))
            }
        }
    }

    /// Shows what an import or export did in the status bar, and opens the Problems window on
    /// `rows` when there are any.
    private func finishPlaylistFile(_ summary: String, _ rows: [Problem]) {
        status.playlistFileReport = rows
        showStatus()
        show(failure: summary)
        if !rows.isEmpty { showProblems() }
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

    /// Follows the track table's `appearance.` settings.
    public func setTableAppearance(_ appearance: TableAppearance) {
        table.apply(appearance)
        // The timeline always alternates its rows; on glass, translucently.
        timeline.table.usesAlternatingRowBackgroundColors = !appearance.glass
        timeline.table.drawsTranslucentRows = appearance.glass
    }

    /// Likes or dislikes the selection, or clears that when all of it has it already.
    public func toggleSelection(_ opinion: TrackOpinion) {
        let failure = opinion == .liked ? "couldn't like the tracks" : "couldn't dislike the tracks"
        guard let ids = selectedTrackIDs(else: failure) else { return }
        edit(failure) { try await self.model.toggle(opinion, ids) }
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
                edited()
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

    public var isBrowserVisible: Bool { !panes.view.isHidden }

    /// Hides or shows the browser's columns; they come back at their saved height.
    /// Hiding them selects All in each first, since a hidden selection would narrow the table
    /// with nothing on screen saying why.
    public func toggleBrowser() {
        if isBrowserVisible { Task { await model.clearPanes() } }
        let paneHadKeys = if case .pane = focusedList { true } else { false }
        panes.view.isHidden.toggle()
        split.adjustSubviews()
        if isBrowserVisible { split.setPosition(CGFloat(browserHeight), ofDividerAt: 0) }
        if paneHadKeys { focusTracks() }
    }

    /// Marks the row of the track at `path`, the one playing or paused, in the track table;
    /// nil marks none.
    public func showPlaying(path: String?) { table.playingPath = path }

    public var isStatusBarVisible: Bool { !statusArea.isHidden }

    /// Centers the status bar's middle on the window beside the sidebar, where the title is
    /// with a full-size content view, or on the whole window.
    public func centerStatusBar(besideSidebar: Bool) {
        statusBar.centersFrom = besideSidebar ? content.view : nil
    }

    /// Lays the status bar out as `layout` says, with `views` for the playing track's parts.
    public func setStatusBar(_ layout: StatusBarLayout, views: [StatusPart: NSView]) {
        statusLayout = layout
        statusPartViews = views
        layOutStatusBar()
        showStatus()
    }

    /// The status bar's column at `place`, for tests.
    func statusColumn(at place: BarPlace) -> StatusColumn? { statusColumns.column(at: place) }

    private func layOutStatusBar() {
        statusArtHeight?.isActive = false
        statusColumns.layOut(
            statusLayout.columns, in: statusBar, leading: statusLeading, trailing: statusTrailing,
            trailingBefore: problemsButton, spacing: Self.statusSpacingPoints,
            stacks: statusLayout.stacks(at:)
        ) { place, column in
            let view = { (part: StatusPart) in
                part == .totals ? self.statusLabel : self.statusPartViews[part]
            }
            if statusLayout.parts(at: place).contains(.totals) {
                statusLabel.alignment = column.alignment.textAlignment
            }
            return (
                statusLayout.parts(at: place).compactMap(view),
                statusLayout.stretching(at: place).flatMap(view)
            )
        }
        // An image view can already hold a recognizer of AppKit's own, so only ours counts.
        if let art = statusPartViews[.art],
            !art.gestureRecognizers.contains(where: { $0 is NSClickGestureRecognizer })
        {
            art.addGestureRecognizer(
                NSClickGestureRecognizer(target: self, action: #selector(openPlayingArt)))
        }
        if let art = statusPartViews[.art],
            statusLayout.columns.columns.contains(where: { $0.column.parts.contains(.art) })
        {
            statusArtHeight = art.heightAnchor.constraint(equalToConstant: 0)
            statusArtHeight?.isActive = true
        }
        insetStatusBar()
        fitStatusBarHeight()
    }

    /// Sets the bar's height, the art's and the lists' inset under the bar, for the stacks as
    /// they are now: a part that shows or hides, the totals' label with a failure say, changes
    /// a stack's height.
    private func fitStatusBarHeight() {
        // As tall as the track table's header in the minimal style, read from it, so the bar
        // matches the header on every macOS version.
        let header = table.table.headerView?.frame.height ?? 0
        let stacks = statusColumns.stacked.map { Double($0.stack.fittingSize.height) }.max() ?? 0
        let height = statusLayout.heightPoints(headerPoints: header, stackPoints: stacks)
        statusArtHeight?.constant = statusLayout.artPoints(heightPoints: height)
        guard statusHeight?.constant != CGFloat(height) else { return }
        statusHeight?.constant = height
        insetListsUnderStatusBar()
    }

    /// Opens the status bar's art in the viewer a click on a row's art opens.
    @objc func openPlayingArt() {
        guard let path = table.playingPath,
            let image = (statusPartViews[.art] as? NSImageView)?.image
        else { return }
        do {
            guard let track = try index.track(path: path), let embedded = track.art else {
                return
            }
            table.openArt(image, embedded, of: track)
        } catch {
            report("couldn't read the art of \(path): \(error)")
        }
    }

    public func toggleStatusBar() {
        statusArea.isHidden.toggle()
        insetListsUnderStatusBar()
        showScanProgress()
    }

    /// Lets the track table and the timeline scroll their last rows clear of the bar.
    private func insetListsUnderStatusBar() {
        let bottom = statusArea.isHidden ? 0 : statusHeight?.constant ?? 0
        for list in [table, timeline] as [RowListController] { list.setBottomInset(bottom) }
    }

    /// Whether Show Current Track has something to show: the track playing, or else a selected
    /// row.
    public func canShowCurrentTrack(playingPath: String?) -> Bool {
        playingPath != nil || hasSelection
    }

    /// Whether the list the window shows has a row selected, for Show Selected Track.
    public var hasSelection: Bool { !shownList.table.selectedRowIndexes.isEmpty }

    /// Show Current Track: the track at `playingPath` in what the browser showed when its play
    /// started, or else in the library (ADR 0091); with nothing playing, the selected rows.
    /// Centered, with the keys.
    public func showCurrentTrack(playingPath: String?) async {
        guard let playingPath else { return showSelectedTrack() }
        guard let id = trackID(path: playingPath) else { return }
        if await reveal(trackID: id, in: model.history.playSource) { return }
        await reveal(trackID: id)
    }

    /// Selects track `id` in what `start` shows: where the window shows its source and lists
    /// the track, else in the source with `start`'s search and column selections, else in the
    /// source alone. False when there's no `start`, its playlist is gone, or it doesn't list
    /// the track.
    private func reveal(trackID id: Int64, in start: TrackFilter?) async -> Bool {
        guard let start, model.exists(start.source) else { return false }
        if start.source == .timeline { return await revealPlay(ofTrack: id) }
        if model.filter.source == start.source, let row = model.rows(holding: [id]).first {
            showRow(row)
            return true
        }
        let alone = TrackFilter(source: start.source)
        for filter in start.search.isEmpty && start.selections.isEmpty ? [alone] : [start, alone] {
            await model.show(WindowPlace(filter: filter), visiting: true)
            guard let row = model.rows(holding: [id]).first else { continue }
            searchField.stringValue = model.filter.search
            showSource()
            showRow(row)
            return true
        }
        return false
    }

    /// Shows the timeline with the newest loaded play of track `id` selected; false when it
    /// lists none.
    private func revealPlay(ofTrack id: Int64) async -> Bool {
        if !showsTimeline {
            await model.setSource(.timeline)
            showSource()
        }
        await timelineLoad?.value
        guard let row = timelineModel.entries.firstIndex(where: { $0.trackID == id }) else {
            return false
        }
        showRow(row)
        return true
    }

    /// Show Selected Track: the selected rows, centered, with the keys.
    public func showSelectedTrack() {
        shownList.centerSelection()
        focusTracks()
    }

    /// Back at the whole library, selects the track playing, centered, as Show Current Track
    /// does, but leaves the keys where they are. With nothing playing, the reload has centered
    /// the selection already.
    private func selectPlayingTrack() {
        guard let path = table.playingPath, let id = trackID(path: path),
            let row = model.rows(holding: [id]).first
        else { return }
        table.selectCentered(row)
    }

    /// Scrolls the list the window shows `rows` rows down, or up when negative, keeping the
    /// selection.
    public func scrollTracks(byRows rows: Int) { shownList.scroll(byRows: rows) }

    /// The list the window shows: the timeline's or the track table.
    private var shownList: RowListController { showsTimeline ? timeline : table }

    /// Selects the track at `path` in the table, centered, showing the whole library first if
    /// the source, a pane or the search hides it.
    public func reveal(path: String) async {
        guard let id = trackID(path: path) else { return }
        await reveal(trackID: id)
    }

    /// The ID of the track at `path`; nil when the library has none, or after reporting why it
    /// couldn't be read.
    private func trackID(path: String) -> Int64? {
        do {
            return try index.track(path: path)?.id
        } catch {
            report("couldn't find \(path) in the library: \(error)")
            return nil
        }
    }

    /// Selects track `id` in the table, centered, showing the whole library first if the
    /// source, a pane or the search hides it. The timeline's rows are plays, not tracks, so it
    /// leaves the timeline.
    public func reveal(trackID id: Int64) async {
        if showsTimeline { _ = await model.showAll() }
        guard let row = await model.reveal(id) else { return }
        if model.filter.search.isEmpty { searchField.stringValue = "" }
        showSource()
        showRow(row)
    }

    /// Selects `row` alone, centered, and gives the table the keys.
    func showRow(_ row: Int) {
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
        start(request)
        return "Playing \(tracks(request.urls.count))"
    }

    /// Whether Show All Music would change nothing: the table lists the whole library.
    public var showsAllMusic: Bool { model.showsEverything }

    /// Shows every track: the library, every pane at All and no search. A browser already
    /// showing that is left as it is.
    public func showAll() {
        Task {
            guard await model.showAll() else { return }
            if !searchField.stringValue.isEmpty { searchField.stringValue = "" }
            showSource()
        }
    }

    /// Shows the library narrowed to one entry, as the palette chooses it. False, changing
    /// nothing, when no browser column shows that kind of entry.
    @discardableResult
    public func showOnly(_ pane: BrowserModel.Pane, id: Int64) async -> Bool {
        guard await model.showOnly(pane, id: id) else { return false }
        searchField.stringValue = ""
        showSource()
        focusTracks()
        return true
    }

    /// Shows the whole library with the first track of one genre, artist or album selected,
    /// centered, as the palette goes to one.
    public func showFirstTrack(of pane: BrowserModel.Pane, id: Int64) async {
        let row: Int?
        do {
            row = try await model.showFirstTrack(of: pane, id: id)
        } catch {
            report("couldn't find the \(pane.title.lowercased())'s first track: \(error)")
            return
        }
        searchField.stringValue = ""
        showSource()
        guard let row else { return }
        showRow(row)
    }

    /// What identifies `row`: the track ID, or on the timeline the play's history ID.
    func rowID(at row: Int) -> Int64? {
        if showsTimeline {
            return timelineModel.entries.indices.contains(row) ? timelineModel.entries[row].id : nil
        }
        return model.trackIDs.indices.contains(row) ? model.trackIDs[row] : nil
    }

    /// Every track's name in the library, for Go to Item.
    public func allTrackNames() async throws -> [TrackName] {
        try await model.allTrackNames()
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
        guard let window = split.window, window.isVisible, isBrowserVisible else { return }
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

    /// A hidden pane's divider would still draw as a line over the table.
    public func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        !isBrowserVisible
    }
}

private func problemsUnreadable(_ error: any Error) -> String {
    "couldn't read the library's problems: \(error)"
}

/// `content` on glass from macOS 26, and before on the title bar's material, the toolbar's gray
/// (ADR 0072), filling the view returned, with `border` along its top. Either blends with the
/// rows scrolled under it (ADR 0084).
@MainActor
private func statusBackground(around content: NSView, border: NSBox) -> NSView {
    // The bar and its border, the material's one content view. The border takes the bar's top
    // point, as the header's line takes the header's last, and the parts lie below it.
    let bordered = NSView()
    border.boxType = .custom
    border.borderWidth = 0
    border.fillColor = .separatorColor
    for view in [content, border] {
        view.translatesAutoresizingMaskIntoConstraints = false
        bordered.addSubview(view)
    }
    let material: NSView
    if #available(macOS 26, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = 0
        glass.contentView = bordered
        material = glass
    } else {
        let effect = NSVisualEffectView()
        effect.material = .titlebar
        effect.blendingMode = .withinWindow
        effect.addSubview(bordered)
        material = effect
    }
    bordered.translatesAutoresizingMaskIntoConstraints = false
    // A stack taller than the tall style's cap is cut at the bar's edges, not drawn over the
    // rows. Views clip by default before macOS 14.
    if #available(macOS 14, *) { material.clipsToBounds = true }
    NSLayoutConstraint.activate([
        bordered.leadingAnchor.constraint(equalTo: material.leadingAnchor),
        bordered.trailingAnchor.constraint(equalTo: material.trailingAnchor),
        bordered.topAnchor.constraint(equalTo: material.topAnchor),
        bordered.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        content.leadingAnchor.constraint(equalTo: bordered.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: bordered.trailingAnchor),
        content.topAnchor.constraint(equalTo: border.bottomAnchor),
        content.bottomAnchor.constraint(equalTo: bordered.bottomAnchor),
        border.leadingAnchor.constraint(equalTo: bordered.leadingAnchor),
        border.trailingAnchor.constraint(equalTo: bordered.trailingAnchor),
        border.topAnchor.constraint(equalTo: bordered.topAnchor),
        border.heightAnchor.constraint(equalToConstant: StatusBarLayout.borderPoints),
    ])
    return material
}
