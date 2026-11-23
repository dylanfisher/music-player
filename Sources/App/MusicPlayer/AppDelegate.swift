import Analysis
import AppKit
import Artwork
import Commands
import Discogs
import DiscogsTagger
import DisplayText
import Downloads
import HALOutput
import KeyChord
import Library
import LibraryBrowser
import LocalSocket
import Log
import Metadata
import NowPlaying
import Palette
import Playback
import PlaylistEditor
import QueueView
import Receiver
import SQLite
import Scripting
import Settings
import SettingsWindow
import Snapshot
import TagEditor
import TagWriter
import UPnPOutput
import WindowPlacement

private let logger = moduleLogger()

/// The composition root for the window: reads Settings once, builds the features, and wires the
/// playback engine, the HAL output and the library watcher to them.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The now-playing bar's art: twice its point size, for Retina displays.
    static let artPixels = HeaderPart.artPoints * 2
    static let artCacheImages = 64

    let paths: AppPaths
    private let measuring: MeasurementKind?
    private let reportingLaunch: Bool
    private let snapshotURL: URL?
    private let snapshotOf: SnapshotTarget
    /// The Separate Releases value a rescan was confirmed for before a relaunch.
    private let rescanConfirmed: Bool?
    /// Whether the index makes an album of each Discogs release, as the window's first open
    /// built it (ADR 0143). The setting differs from it after a change, until a relaunch.
    private(set) var separatesReleases: Bool?
    /// How long after the first rows the snapshot waits, for the scan and art to show.
    static let snapshotDelaySeconds = 4.0
    /// How long quitting waits for the outputs to close: longer than a device takes to restore
    /// its format, which it waits up to 3 s for.
    static let closeWaitSeconds = 6.0
    /// How long quitting waits for the engine's place, for the play state.
    static let resumeWaitSeconds = 1.0
    private(set) var settings: ConfigStore<AppSettings>?
    let banner = ConfigBanner()
    private(set) var state: StateStore<AppState>?
    var palette: PaletteController?
    var settingsWindow: SettingsWindowController?
    /// What each ⌘K entry item opens, by its key.
    var paletteEntries: [String: (BrowserModel.Pane, Int64)] = [:]
    /// ⌘P's artists and albums, with the entry each key shows, and its tracks.
    var goToEntries:
        LibraryListing<(items: [PaletteItem], shown: [String: (BrowserModel.Pane, Int64)])>?
    var goToTracks: LibraryListing<[PaletteItem]>?
    /// Looks a track up by path, for counting plays toward frecency.
    private(set) var trackLookup: ((String) throws -> TrackRow?)?
    /// Looks tracks up by path together, for an info window's play counts and ratings.
    private var tracksLookup: (([String]) throws -> [TrackRow?])?
    private(set) var saver: LayoutSaver?
    /// The play state saved at quit, read at launch, and what saves it once that's put back
    /// (ADR 0095).
    private var launchResume = ResumePoint()
    private(set) var resumeSaver: ResumeSaver?
    /// Set once quitting has gone on, so the play state's wait replies once.
    private var quitReplied = false
    private(set) var window: MainWindow?
    private(set) var browser: LibraryBrowser?
    private(set) var nowPlaying: NowPlayingBar?
    private(set) var toolbar: MainToolbar?
    private(set) var signalPath: SignalPathPanel?
    /// The details of a playback problem, opened from the status bar.
    private(set) lazy var problemWindow = makeProblemWindow()
    /// Media keys, headphone buttons, Now Playing in Control Center, and the Dock menu.
    var mediaControls: MediaControls?
    private var dockMenu: DockMenu?
    private(set) var queue: QueuePanel?
    /// What Edit ▸ Copy last copied, for Paste.
    var trackClipboard: TrackClipboard?
    private(set) var watcher: LibraryWatcher?
    /// Carries the organized files' stats, one organize's or launch's at a time (ADR 0164).
    let layoutCarrier = LayoutCarrier()
    /// The library's snapshots (ADR 0142), made with the window.
    private(set) var snapshotScheduler: SnapshotScheduler?
    /// Asks for the day's snapshot every hour, once the launch's scans have ended.
    var snapshotTimer: Timer?
    /// Held while the app runs, so a restore at another copy's launch waits (ADR 0142).
    var indexInUse: IndexInUse?
    private var shareChanges: ShareChangeObserver?
    var output: DeviceOutput?
    /// Each device's state before playback first changed it, shared by every provider made for
    /// it, since a settings change makes a new one.
    let deviceSnapshots = DeviceSnapshots()
    /// The renderer `output.renderer` names, while the engine plays to it.
    var rendererOutput: RendererOutput?
    /// Counts the sync folders chosen, so only the latest one's check applies.
    private var syncFolderPicks = 0
    /// The search for that renderer, and its signal paths for the panel.
    var rendererSearch: Task<Void, Never>?
    var rendererPathUpdates: Task<Void, Never>?
    /// The volume keys' tap, while they drive the receiver.
    var volumeKeyTap: MediaKeyTap?
    var explainedAccessibility = false
    /// The device output's latest path, shown again when playback comes back from a renderer.
    var devicePath: SignalPath?
    var engine: PlaybackEngine?
    var activity = PlaybackActivity.stopped
    /// The engine's latest state, for the menus' check marks.
    var playback = PlaybackState()
    /// Whether the device in use has a digital volume, from its profile.
    var digitalVolume = false
    /// The digital volume, in dB below full.
    var volumeDecibels = 0.0
    /// The UID of the device in use, whose profile the output settings and the volume change.
    var outputUID: String?
    /// Set while the config is being made to show the device in use, so those writes aren't
    /// taken as edits.
    var showingInUse = false
    var playbackUpdates: Task<Void, Never>?
    var signalPathUpdates: Task<Void, Never>?
    var returnUpdates: Task<Void, Never>?
    /// Plays and skips, counted from the engine's updates.
    private(set) var playTracker: PlayTracker?
    /// The smart playlist editor while it's open.
    var ruleEditor: RuleEditorSheet?
    /// The tag editor, which writes music files only after the user saves an edit (ADR 0020).
    private(set) lazy var tagEditing = makeTagEditing()
    /// The tag editor once made, so a quit doesn't make one to ask it.
    private var madeTagEditing: TagEditing?
    /// The Discogs tagger, once first shown.
    var discogsTagger: DiscogsTagger?
    /// The tagger open on a staged download's discrepancy, while it's open.
    var stagedTagger: DiscogsTagger?
    /// The start of the downloads, waiting for this Mac's name; a settings change replaces it.
    var downloadsStarting: Task<Void, Never>?
    /// Soulseek downloads, which run while the service is set (phase 54).
    private(set) lazy var downloads = makeDownloads()
    private(set) var dispatcher: CommandDispatcher?
    /// Runs the tool's requests and links, once playback is ready.
    var scriptRouter: ScriptRouter?
    /// Receiver control, while `receiver.enabled` is on.
    var receiver: ReceiverControl?
    /// The web remote's service and what it keeps between reads (ADR 0214).
    let remote = RemoteParts()
    var scriptServer: LocalSocketServer?
    /// Links that came before the router, run once it's there.
    var waitingLinks: [String] = []
    private var menu: MainMenu?
    /// The output picker's devices and renderers, as last found, and what keeps them current.
    var foundDevices: [FoundOutput] = []
    var foundRenderers: [FoundOutput] = []
    var outputSearch: Task<Void, Never>?
    /// What playback fell back to System Default from, while it does (ADR 0223).
    var outputFallback = OutputFallbacks<RendererOutput>()
    var deviceListWatch: DeviceListWatch?
    var outputMenu: OutputMenu?
    var playlistMenus: [PlaylistMenu] = []
    private let artwork = ArtworkLoader(
        maxPixelSize: artPixels, capacity: artCacheImages, read: SharedArtRead().read)
    private(set) lazy var recommendations = makeRecommendations()
    /// The art column's thumbnails, kept between launches (ADR 0079).
    private(set) lazy var thumbnails = ThumbnailStore(directory: paths.thumbnailDirectory)
    /// The Spectrum window's spectrograms, kept beside the thumbnails (ADR 0115).
    lazy var spectrograms = SpectrogramStore(directory: paths.spectrogramDirectory)
    /// Made on first use by `measuresCache()`, `fileAnalyzer()` and `libraryPass()`.
    var measures: MeasuresCache?
    var analyzer: FileAnalyzer?
    var libraryAnalysis: LibraryAnalysis?
    /// Where Analyze Library was at its last report; nil when it isn't running or paused.
    var libraryAnalysisStage: LibraryAnalysis.Progress.Stage?
    /// Whether every file was tried since the last run started, as the pass last said, so
    /// Analyze Library reads the whole library again (ADR 0119).
    var libraryAnalysisEveryFileTried = false
    private(set) lazy var spectrumWindows = makeSpectrumWindows()
    private let stalls = StallDetector { NSApp.currentEvent.map { eventName($0.type) } }

    /// `measuring` runs `WindowMeasurement` once the table first draws rows, then quits.
    /// `reportingLaunch` prints a line once the first scan of each watched folder has ended.
    /// `snapshotURL` gets a PNG of the window a few seconds after that. `rescanConfirmed`
    /// rebuilds the index at launch without asking, when Separate Releases changing to it is
    /// the only reason.
    init(
        paths: AppPaths, measuring: MeasurementKind?, reportingLaunch: Bool, snapshotURL: URL?,
        snapshotOf: SnapshotTarget, rescanConfirmed: Bool? = nil
    ) {
        self.rescanConfirmed = rescanConfirmed
        self.snapshotOf = snapshotOf
        self.paths = paths
        self.measuring = measuring
        self.reportingLaunch = reportingLaunch
        self.snapshotURL = snapshotURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            // Before any connection opens the index and the state and config files are read,
            // which a restore replaces (ADR 0142, 0181).
            try applyRestoreAtLaunch()
            let settings = try signposted(.launchSettings) {
                ConfigStore(
                    AppSettings(), fileURL: paths.configFile, check: try shortcutCheck(),
                    creating: true)
            }
            self.settings = settings
            playTracker = PlayTracker(playedFraction: playedFraction(settings)) {
                [weak self] in self?.record($0)
            }
            applyAppearance(settings[\.appearance])
            let dispatcher = CommandDispatcher(bindings: try keyBindings(settings.shortcuts))
            stalls.start()
            dispatcher.willRun = { [stalls] in stalls.noteCommand($0.rawValue) }
            let menu = MainMenu(dispatcher: dispatcher, appName: appName, settings: AppSettings())
            dispatcher.bindingsChanged = { [weak menu] in menu?.showChords() }
            NSApp.mainMenu = menu.bar
            // In every window, the field being edited takes the text-editing chords before the
            // menu bar does.
            _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                event.window?.editTextFirst(event) == true ? nil : event
            }
            NSApp.windowsMenu = menu.windowsMenu
            NSApp.helpMenu = menu.helpMenu
            self.dispatcher = dispatcher
            self.menu = menu
            try signposted(.launchWindow) { try openWindow(settings, dispatcher) }
            watchOutputs(menu)
            registerCommands(dispatcher)
            wireTrackMenu(menu)
            if let state, let saver { makePalette(dispatcher, state: state, saver: saver) }
            registerSettingCommands(dispatcher)
            settings.changed = { [weak self] keys in self?.settingsChanged(keys) }
            settings.problemsChanged = { [weak self] in self?.showConfigProblems() }
            saver?.failureChanged = { [weak self] in self?.showConfigProblems() }
            banner.closeStateDiscard = { [weak self] in
                self?.saver?.forgetDiscarded()
                self?.showConfigProblems()
            }
            banner.openConfigFile = { [weak dispatcher] in dispatcher?.run(.openConfigFile) }
            banner.removeObsoleteSettings = { [weak self, weak settings] in
                do {
                    try settings?.removeObsoleteKeys()
                } catch {
                    self?.fail("Couldn't remove the obsolete settings", error)
                }
            }
            showConfigProblems()
            settings.startWatching()
        } catch LibraryError.rescanDeclined {
            // Quit at the rescan question, which left the index as it was.
            NSApp.terminate(nil)
        } catch {
            fail("The library couldn't open", error)
        }
    }

    /// Every other window opens where it was left, or centered on the main window's screen,
    /// and its frame goes to the state file as it changes (ADR 0158).
    private func keepWindowFrames(_ state: StateStore<AppState>, _ saver: LayoutSaver) {
        let placed = PlacedWindows.shared
        placed.frames = state[\.windowFrames].frames.mapValues(\.rect)
        placed.framesChanged = { frames in
            saver.set(\.windowFrames, WindowFrames(frames.mapValues(WindowFrame.init)))
        }
        placed.anchor = { [weak self] in self?.window?.window }
    }

    /// The file of the track the engine has loaded.
    var currentTrackPath: String? {
        playback.currentIndex.map { playback.queue[$0].path }
    }

    private func openWindow(_ settings: ConfigStore<AppSettings>, _ dispatcher: CommandDispatcher)
        throws
    {
        let state = try StateStore(AppState(), fileURL: paths.stateFile)
        self.state = state
        let saver = LayoutSaver(state)
        self.saver = saver
        keepWindowFrames(state, saver)
        let layout = WindowSettings(settings, state: state)
        let databaseURL = libraryFileURL(in: paths.dataDirectory)
        do {
            try Database.readAhead(at: databaseURL)
        } catch {
            // Only a hint: the queries read what they need either way.
            logger.error("couldn't read the library file ahead: \(error)")
        }
        // Rows for the table come from a connection of the main thread's own. It opens first,
        // so it alone may move an unreadable file aside, before any other connection opens.
        // It alone passes Separate Releases; every other connection keeps what it built.
        let index = try LibraryIndex(
            at: databaseURL, movingAsideIfUnreadable: true,
            confirmRescan: { [rescanConfirmed] notice in
                rescanConfirmed.map(notice.onlySeparatesReleases) == true || askToRescan(notice)
            },
            separateReleases: settings[\.separateReleases])
        separatesReleases = index.separateReleases
        snapshotScheduler = SnapshotScheduler(paths: paths)
        let browser = LibraryBrowser(
            reader: try LibraryReader(databaseURL: databaseURL), index: index,
            layout: layout.trackTable, browserHeight: layout.browserHeight,
            groupByAlbumArtist: layout.groupByAlbumArtist, thumbnails: thumbnails)
        browser.setTableAppearance(layout.tableAppearance)
        browser.statsHeight = layout.statsHeight
        browser.problemColumns = state[\.problemsColumns]
        browser.problemColumnsChanged = { saver.set(\.problemsColumns, $0) }
        if let timelineTable = layout.timelineTable { browser.showTimelineColumns(timelineTable) }
        let lookup = { (path: String) in try index.track(path: path) }
        trackLookup = lookup
        tracksLookup = { try index.tracks(atPaths: $0) }
        let nowPlaying = NowPlayingBar(model: NowPlayingModel(lookup: lookup), artwork: artwork)
        nowPlaying.header.apply(layout.headerStatus)
        for (item, header) in zip(ToolbarItem.customStatuses, nowPlaying.customStatuses) {
            if let slot = layout.customStatuses[item] { header.apply(slot) }
        }
        nowPlaying.titleFormat = layout.headerTitleFormat
        makeMediaControls(dispatcher, lookup: lookup)
        let queue = QueuePanel(model: QueueModel(lookup: lookup))
        let signalPath = SignalPathPanel()
        signalPath.setReceiverVolume = { [weak self] in self?.slideReceiverVolume($0) }
        let toolbar = MainToolbar(
            identifier: String(describing: MainWindow.self), transport: nowPlaying.transport,
            status: nowPlaying.status, customStatuses: nowPlaying.customStatuses.map(\.view),
            search: browser.searchField, dispatcher: dispatcher, items: state[\.toolbarItems])
        toolbar.statusLayout = layout.headerStatus
        toolbar.customStatusLayouts = layout.customStatuses
        toolbar.titleFormat = layout.headerTitleFormat
        toolbar.itemsChanged = { items in
            saver.set(\.toolbarItems, items)
            if !items.contains(.search) { browser.clearSearch() }
        }
        toolbar.volumeDecibels = { [weak self] in
            guard let self, canSetVolume else { return nil }
            return volumeDecibels
        }
        toolbar.setVolume = { [weak self] in self?.setVolume($0, saving: $1) }
        let window = MainWindow(
            settings: layout, banner: banner.view, browser: browser, toolbar: toolbar,
            signalPath: signalPath, queue: queue, saver: saver)
        self.browser = browser
        connectRatings(browser, nowPlaying) { [weak self] in self?.tagEditing.ratingsChanged() }
        wireRediscover(browser, settings)
        self.nowPlaying = nowPlaying
        nowPlaying.follow(window.window)
        nowPlaying.problemOpened = { [weak self] in self?.showProblem($0) }
        nowPlaying.fixRequested = { [weak self] in self?.apply($0, for: $1) }
        window.showTitles(of: nowPlaying, layout.windowTitle)
        self.toolbar = toolbar
        self.signalPath = signalPath
        self.queue = queue
        self.window = window

        browser.play = { [weak self] request in self?.play(request) }
        browser.playStart = { [weak self] start in self?.play(start) }
        browser.playNext = { [weak self] urls in
            guard let engine = self?.engine else { return }
            Task { await engine.playNext(urls) }
        }
        browser.currentPlayback = { [weak self] in await self?.engine?.spot() }
        browser.restorePlayback = { [weak self] spot in await self?.engine?.restore(spot) }
        browser.addToQueue = { [weak self] urls in self?.addToQueue(urls) }
        window.browserStateChanged = { [weak self] in self?.resumeSaver?.changed() }
        browser.groupingsChosen = { [weak self] groupings in
            do {
                try settings.set(\.browserGroupings, to: groupings)
            } catch {
                self?.fail("Couldn't change the browser's columns", error)
                return
            }
            // Here too, not only on the config's change: a file that didn't name the key held
            // the default, which may be what was chosen, so nothing changed there.
            Task { await browser.setGroupings(groupings) }
        }
        browser.selectionChanged = { [weak self] in self?.resumeSaver?.changed() }
        makeGoToListings(browser)
        browser.libraryRefreshed = { [weak self] in
            self?.goToEntries?.libraryChanged()
            self?.goToTracks?.libraryChanged()
            self?.mediaControls?.libraryChanged()
            nowPlaying.libraryChanged()
            queue.libraryChanged()
        }
        browser.edited = { [weak self] in self?.watcher?.pushSync() }
        browser.restored = { [weak self] paths in
            let folders = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
            self?.watcher?.rescan(directories: folders.sorted())
        }
        browser.runCommand = { [weak self] id in
            if self?.dispatcher?.run(id) != true { NSSound.beep() }
        }
        browser.watchedFolders = { settings[\.watchedFolders] }
        browser.watch = { [weak self] url in self?.watch(url, settings) }
        browser.libraryFolder = { (settings[\.copyAddedFiles], settings[\.libraryFolder]) }
        browser.rescanDirectories = { [weak self] directories in
            self?.watcher?.rescan(directories: directories)
        }
        browser.firstRowsDrawn = { [weak self] in self?.interactive() }
        let keyCommand = { [weak self] (chords: [KeyChord]) in
            self?.dispatcher?.key(chords) ?? .unbound
        }
        browser.keyCommand = keyCommand
        queue.keyCommand = keyCommand
        applyStatusBar(layout.statusBar)
        browser.setStatusAccessory(downloads.statusView)
        if !layout.statusBarVisible { browser.toggleStatusBar() }
        downloads.setStatusBarShown(browser.isStatusBarVisible)
        window.statusBarToggled = { [weak self] in self?.downloads.setStatusBarShown($0) }
        downloads.statusStyle = settings[\.downloadsStatusStyle]
        downloads.styleChosen = { [weak self] style in
            do {
                try settings.set(\.downloadsStatusStyle, to: style)
            } catch {
                self?.fail("Couldn't change how the downloads show", error)
            }
        }
        downloads.autoApprove = settings[\.autoApproveSafeMatches]
        downloads.autoApproveChosen = { [weak self] on in
            do {
                try settings.set(\.autoApproveSafeMatches, to: on)
            } catch {
                self?.fail("Couldn't change whether safe matches are approved", error)
            }
        }
        downloads.autoUpgradesInFlight = settings[\.autoUpgradesInFlight]
        downloads.autoUpgrade = settings[\.autoUpgrade]
        downloads.autoUpgradeChosen = { [weak self] on in
            do {
                try settings.set(\.autoUpgrade, to: on)
            } catch {
                self?.fail("Couldn't change whether albums are upgraded automatically", error)
            }
        }
        browser.statusTotals = layout.statusTotals
        browser.totalsFormats = layout.totalsFormats
        browser.statusTotalsChanged = { saver.set(\.statusTotals, $0) }
        if !layout.browserVisible { browser.toggleBrowser() }

        window.show()
        NSApp.activate(ignoringOtherApps: true)
        launchResume = layout.resume
        Task { await browser.load(layout.browser, resume: layout.resume) }
        if let aside = index.movedAside { showMovedAside(aside, in: window.window) }
    }

    /// The first rows are on screen. Everything that can wait for that starts now.
    private func interactive() {
        guard let settings else { return }
        signposted(.launchServices) { startServices(settings) }
    }

    private func startServices(_ settings: ConfigStore<AppSettings>) {
        startPlayback(settings)
        resumePlayback(settings)
        applyRendererSetting()
        thumbnails.trimInBackground()
        spectrograms.trimInBackground()
        startScripting()
        applyReceiverSetting()
        applyRemoteSetting()
        startWatching(settings)
        applyDownloadsSettings()
        showLibraryAnalysisStanding()
        shareChanges = ShareChangeObserver { [weak self] in self?.watcher?.sharesMayHaveMoved() }
        if let snapshotURL {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.snapshotDelaySeconds) {
                [weak self] in self?.snapshot(to: snapshotURL)
            }
        }
        if let measuring, let browser {
            // After this turn of the run loop, so the first frame is counted as drawn.
            DispatchQueue.main.async { [artwork] in
                WindowMeasurement.run(measuring, browser: browser, artwork: artwork)
            }
        }
    }

    /// Draws `snapshotOf` into a PNG; the palette gets a second to list its items first.
    private func snapshot(to url: URL) {
        let target: () -> NSWindow? =
            switch snapshotOf {
            case .main, .health, .stats: { [weak self] in self?.window?.window }
            case .review: { [weak self] in self?.browser?.yearReviewWindow }
            case .palette: { [weak self] in self?.palette?.window }
            case .playlist: { [weak self] in self?.ruleEditor?.window }
            case .tags: { [weak self] in self?.tagEditing.editors.last?.window }
            case .settings, .playback, .appearance, .toolbar, .library, .folders, .tagging,
                .shortcuts:
                { [weak self] in self?.settingsWindow?.window }
            case .statusBar:
                { [weak self] in
                    self?.settingsWindow?.barBuilderWindow(AppSettings().statusBarLayout.key)
                }
            case .headerStatus:
                { [weak self] in
                    self?.settingsWindow?.barBuilderWindow(AppSettings().headerStatusLayout.key)
                }
            case .toolbarSheet: { [weak self] in self?.window?.window.attachedSheet }
            case .downloads: { [weak self] in self?.downloads.window }
            }
        // The palette lists its items, and the tag editor reads its files, first.
        // The downloads wait for their first poll too.
        let wait =
            snapshotOf == .main ? 0 : snapshotOf == .tags || snapshotOf == .downloads ? 3.0 : 1.0
        switch snapshotOf {
        case .main: break
        case .health: dispatcher?.run(.checkHealth)
        case .stats: dispatcher?.run(.showStats)
        case .review: dispatcher?.run(.showYearInReview)
        case .palette: dispatcher?.run(.showPalette)
        case .playlist: dispatcher?.run(.newSmartPlaylist)
        case .tags:
            browser?.selectAllTracks()
            dispatcher?.run(.editTags)
        case .settings: settingsWindowController()?.show(.general)
        case .playback: settingsWindowController()?.show(.playback)
        case .appearance: settingsWindowController()?.show(.appearance)
        case .toolbar: settingsWindowController()?.show(.toolbar)
        case .library: settingsWindowController()?.show(.library)
        case .folders: settingsWindowController()?.show(.folders)
        case .tagging: settingsWindowController()?.show(.tagging)
        case .shortcuts: settingsWindowController()?.show(.shortcuts)
        case .statusBar:
            settingsWindowController()?.showBarBuilder(AppSettings().statusBarLayout.key)
        case .headerStatus:
            settingsWindowController()?.showBarBuilder(AppSettings().headerStatusLayout.key)
        case .toolbarSheet: toolbar?.toolbar.runCustomizationPalette(nil)
        case .downloads: dispatcher?.run(.showDownloads)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            do {
                guard let window = target() else { throw SnapshotError(path: url.path) }
                try writeSnapshot(of: window, to: url)
            } catch {
                logger.error("\(error)")
                printError(error)
            }
        }
    }

    /// Accessibility permission is given in System Settings, so the volume keys are tried
    /// again when the owner comes back.
    func applicationDidBecomeActive(_ notification: Notification) {
        applyVolumeKeys()
    }

    /// Asks first while work a quit would cut short is under way (ADR 0191), or the tag
    /// editor's own question while only tag writes are queued (ADR 0167), then saves the play
    /// state before quitting, waiting up to `resumeWaitSeconds` for the engine's place.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let question = QuitQuestion(
            running: unfinishedWork, alsoListing: madeTagEditing?.unfinishedWork ?? [])
        {
            // Asked after returning, as the tag editor's question is.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    let quit = question.ask()
                    guard quit, let self else {
                        return sender.reply(toApplicationShouldTerminate: quit)
                    }
                    if !self.saveResumeThenQuit(sender) { self.replyToQuit(sender) }
                }
            }
            return .terminateLater
        }
        let held = madeTagEditing?.holdQuit { [weak self] quit in
            guard quit, let self else { return sender.reply(toApplicationShouldTerminate: quit) }
            if !saveResumeThenQuit(sender) { replyToQuit(sender) }
        }
        if held == true { return .terminateLater }
        return saveResumeThenQuit(sender) ? .terminateLater : .terminateNow
    }

    /// The work under way outside the tag editor's queue that a quit cuts short, a line each,
    /// from the parts made already.
    private var unfinishedWork: [String] {
        (browser?.unfinishedWork ?? []) + (discogsTagger?.unfinishedWork ?? [])
            + (stagedTagger?.unfinishedWork ?? []) + downloads.unfinishedWork
    }

    /// Saves the play state, then quits; false, doing nothing, without a saver.
    private func saveResumeThenQuit(_ sender: NSApplication) -> Bool {
        guard let resumeSaver else { return false }
        Task { [weak self] in
            await resumeSaver.save()
            self?.replyToQuit(sender)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeWaitSeconds) {
            [weak self] in
            guard let self, !quitReplied else { return }
            logger.error("the play state wasn't read within \(Self.resumeWaitSeconds) s; quitting")
            replyToQuit(sender)
        }
        return true
    }

    private func replyToQuit(_ sender: NSApplication) {
        guard !quitReplied else { return }
        quitReplied = true
        sender.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        volumeKeyTap?.stop()
        scriptServer?.stop()
        receiver?.stop()
        remote.service?.stop()
        downloadsStarting?.cancel()
        downloads.stop()
        window?.saveToolbarVisibility()
        saver?.flush()
        watcher?.stop()
        // Puts the device and the default outputs back the way they were. The device output's
        // close waits on its control thread, which a read from a share that stopped answering
        // holds. The renderer's close stops its HTTP server, which waits on the queue that
        // reads the file it serves, so a hung share holds that too. Both close together within
        // one bound; the device's restore record puts it back at the next launch instead.
        var outputs: [any Output] = []
        outputs += outputFallback.renderersToClose(rendererOutput).map { $0 as any Output }
        if let output { outputs.append(output) }
        let closing = outputs
        if !finishes(
            within: Self.closeWaitSeconds,
            { DispatchQueue.concurrentPerform(iterations: closing.count) { closing[$0].close() } })
        {
            logger.error("the outputs didn't close within \(Self.closeWaitSeconds) s; quitting")
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenu?.menu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: Playback

    /// Cues the track of the play state saved at quit, paused where it was, then starts saving
    /// the play state (ADR 0095). Saving waits for the cue, so a save before it can't replace
    /// the saved track with nothing.
    private func resumePlayback(_ settings: ConfigStore<AppSettings>) {
        guard let browser else { return }
        let saver = ResumeSaver(settings) { [weak self] in await self?.currentResumePoint() }
        let resume = launchResume
        Task { [weak self] in
            if let engine = self?.engine, let resumed = await browser.resumedPlayback(resume) {
                await engine.cue(resumed.spot, durationSeconds: resumed.durationSeconds)
            }
            self?.resumeSaver = saver
        }
    }

    /// Where playback and the window are, for the play state. Without an output nothing can
    /// have played, so the saved track stays.
    private func currentResumePoint() async -> ResumePoint? {
        guard let browser, let settings else { return nil }
        guard let engine else {
            let saved = settings[\.resume]
            var point = browser.resumePoint(playing: nil)
            point?.track = saved.track
            point?.seconds = saved.seconds
            point?.from = saved.from
            return point
        }
        let spot = await engine.spot()
        let playing = spot.index.flatMap { index in
            spot.status == .stopped ? nil : (spot.queue[index].path, spot.seconds)
        }
        return browser.resumePoint(playing: playing)
    }

    private func makeTagEditing() -> TagEditing {
        let editing = TagEditing(
            writer: TagWriter(journal: TagUndoJournal(dataDirectory: paths.dataDirectory)),
            ledger: libraryFileURL(in: paths.dataDirectory))
        editing.written = { [weak self] report, organized, done in
            guard let self, let organized else {
                self?.watcher?.rescan(files: report.changed, parsed: report.parsed)
                return done()
            }
            carry(organized, then: report, done: done)
        }
        editing.organizingFolder = { [weak self] in
            guard let settings = self?.settings, settings[\.keepFilesOrganized] else { return nil }
            return settings[\.libraryFolder]
        }
        editing.run = { [weak self] in self?.dispatcher?.run($0) }
        editing.isEnabled = { [weak self] in self?.dispatcher?.isEnabled($0) == true }
        editing.saving = { [weak self] progress in self?.browser?.showSaving(progress) }
        editing.organizing = { [weak self] progress in self?.browser?.showOrganizing(progress) }
        editing.playCounts = { [weak self] paths in
            self?.indexed(paths, \.playCount, "play count") ?? paths.map { _ in nil }
        }
        editing.setPlayCount = { [weak self] count, paths in
            self?.browser?.setPlayCount(count, paths: paths)
        }
        editing.ratings = { [weak self] paths in
            self?.indexed(paths, \.rating, "star rating") ?? paths.map { _ in nil }
        }
        editing.setRating = { [weak self] stars, paths in
            self?.browser?.setRating(stars, paths: paths)
        }
        // The local catalog only: the tab is what an import of the dumps holds.
        editing.release = { [weak self] id in
            guard let self, let settings else { throw NoSettings() }
            return try await releaseDetail(
                id, catalogAt: paths.discogsCatalogFile(settings[\.discogsCatalogPath]))
        }
        madeTagEditing = editing
        return editing
    }

    /// What the index has for each of `paths`, by `fact` of its track, for an info window; nil
    /// for a path it has no track for, or all nil when it couldn't read them, which is logged.
    private func indexed<Fact>(
        _ paths: [String], _ fact: KeyPath<TrackRow, Fact>, _ name: String
    ) -> [Fact?] {
        do {
            guard let tracksLookup else { return paths.map { _ in nil } }
            return try tracksLookup(paths).map { $0?[keyPath: fact] }
        } catch {
            logger.error("couldn't read the \(name) of \(tracks(paths.count)): \(error)")
            return paths.map { _ in nil }
        }
    }

    private func makeMediaControls(
        _ dispatcher: CommandDispatcher, lookup: @escaping (String) throws -> TrackRow?
    ) {
        let controls = MediaControls(
            model: NowPlayingModel(lookup: lookup), dispatcher: dispatcher,
            remote: SystemRemoteCommands(), center: SystemNowPlaying(),
            artwork: artwork.sharingReads(
                maxPixelSize: MediaControls.artPixels, capacity: MediaControls.artCacheImages),
            seek: { [weak self] seconds in
                guard let engine = self?.engine else { return }
                Task { await engine.seek(toSeconds: seconds) }
            })
        mediaControls = controls
        dockMenu = DockMenu(model: controls.model, dispatcher: dispatcher)
    }

    private func play(_ start: PlayStart) {
        guard let engine else { return }
        Task {
            // The queue playing is this list's as it was set: play the track in it, as Next
            // does, rather than replace it (ADR 0097).
            if let queue = start.queue,
                await engine.play(entry: queue.first, ifQueueIs: queue.urls)
            {
                return
            }
            let filling = await engine.play(starting: start.url) {
                let request = try await start.request()
                return (request.urls, request.first)
            }
            do {
                try await filling.value
            } catch {
                fail("Couldn't read the queue to play", error)
            }
        }
    }

    private func play(_ request: PlayRequest) { play(request.urls, first: request.first) }
    /// Plays `urls` from `first` as a new queue.
    func play(_ urls: [URL], first: Int) {
        guard let engine else { return }
        guard urls.indices.contains(first) else {
            fail("Couldn't play", PlayRequestError.noStart(first, of: urls.count))
            return
        }
        // Through `play(starting:)`, so the output keeps the device open (ADR 0078).
        Task {
            let filling = await engine.play(starting: urls[first]) { (urls, first) }
            do {
                try await filling.value
            } catch {
                fail("Couldn't play the queue", error)
            }
        }
    }

    // MARK: Watched folders

    func startWatching(_ settings: ConfigStore<AppSettings>) {
        watcher?.stop()
        watcher = nil
        guard let browser else { return }
        // A run Bench measures, or one drawing a PNG, takes no snapshots, which would add
        // their reads to what it measures.
        let snapshotting = measuring == nil && !reportingLaunch && snapshotURL == nil
        let events = standingAndProfileFollowing(
            reportingLaunch ? reportingLaunchEnd(browser.watcherEvents) : browser.watcherEvents)
        guard
            let watcher = startedWatcher(
                settings, databaseURL: libraryFileURL(in: paths.dataDirectory),
                events: snapshotting ? startingSnapshotsAfterLaunch(events) : events)
        else {
            // No folder has a scan to wait for.
            if reportingLaunch { FileHandle.standardOutput.write(launchedLine) }
            if snapshotting { startDailySnapshots() }
            return
        }
        if activity != .stopped {
            watcher.playbackChanged(
                activity, pausePollingDuringPlayback: settings[\.pausePollingDuringPlayback])
        }
        self.watcher = watcher
        // Organized files whose stats a carry before couldn't move.
        carry(nil, then: nil)
    }

    /// Asks for a folder to watch in a sheet over `window`.
    func addFolder(over window: NSWindow) {
        guard let settings else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = watchTitle
        panel.message =
            "Choose a folder of music to add to the library. Its files are written only when"
            + " you edit their tags."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.watch(url, settings)
        }
    }

    private func watch(_ url: URL, _ settings: ConfigStore<AppSettings>) {
        Task {
            // FSEvents reports nothing on network volumes, so those are polled.
            let found = await blockingFileWork { Result { try folderToWatch(at: url) } }
            do {
                let folder = try found.get()
                var folders = settings[\.watchedFolders]
                guard
                    !folders.contains(where: {
                        $0.path == folder.path && $0.share == folder.share
                    })
                else { return }
                folders.append(folder)
                try settings.set(\.watchedFolders, to: folders)
            } catch {
                fail("Couldn't add \(url.standardizedFileURL.path)", error)
            }
        }
    }

    /// Asks for the sync folder, stored by share when it's on one, as a watched folder is. The
    /// panel opens at the folder set now, where it is now.
    func chooseSyncFolder() {
        guard let settings else { return }
        guard let current = settings[\.syncFolder] else { return showSyncFolderPanel(at: nil) }
        let shares: [MountedShare]
        do {
            shares = current.share == nil ? [] : try SystemShareMounts().mountedShares()
        } catch {
            logger.error("Couldn't list the mounted shares to open at the sync folder: \(error)")
            return showSyncFolderPanel(at: nil)
        }
        Task {
            // The folder may be on a share that has stopped answering.
            let found = await blockingFileWork {
                existingSyncFolder(current, among: shares, isDirectory: isDirectory)
            }
            switch found {
            case .success(let path): showSyncFolderPanel(at: path)
            case .failure(let missing):
                // Change… is how a missing folder gets replaced, so the panel opens anyway.
                let place = String(describing: missing.place)
                logger.notice("the sync folder isn't there to open the panel at: \(place)")
                showSyncFolderPanel(at: nil)
            }
        }
    }

    private func showSyncFolderPanel(at path: String?) {
        guard let settings else { return }
        let panel = syncFolderPanel(at: path)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.syncFolderPicks += 1
            let pick = self?.syncFolderPicks
            Task {
                let found = await blockingFileWork { Result { try folderToWatch(at: url) } }
                // A later pick supersedes this one, even if this check returns after it.
                guard self?.syncFolderPicks == pick else { return }
                do {
                    let folder = try found.get()
                    try settings.set(
                        \.syncFolder, to: SyncFolder(path: folder.path, share: folder.share))
                } catch {
                    self?.fail("Couldn't sync through \(url.standardizedFileURL.path)", error)
                }
            }
        }
    }

    /// Asks for the staging folder, stored by share when it's on one, as a watched folder is.
    func chooseStagingFolder() {
        guard let settings else { return }
        let panel = stagingFolderPanel()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let found = await blockingFileWork { Result { try folderToWatch(at: url) } }
                do {
                    let folder = try found.get()
                    try settings.set(
                        \.stagingFolder, to: StagingFolder(path: folder.path, share: folder.share))
                } catch {
                    self?.fail("Couldn't stage downloads in \(url.standardizedFileURL.path)", error)
                }
            }
        }
    }

    /// Opens the sync folder in Finder where it is now, or says in a sheet over `window` why
    /// it can't.
    func openSyncFolder(over window: NSWindow) {
        guard let settings, let folder = settings[\.syncFolder] else { return NSSound.beep() }
        let shares: [MountedShare]
        do {
            shares = folder.share == nil ? [] : try SystemShareMounts().mountedShares()
        } catch {
            return fail("Couldn't find the sync folder", error)
        }
        Task {
            // The folder may be on a share that has stopped answering.
            let found = await blockingFileWork {
                existingSyncFolder(folder, among: shares, isDirectory: isDirectory)
            }
            switch found {
            case .success(let path):
                let opened = await blockingFileWork {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
                }
                if !opened {
                    logger.error("Finder didn't open the sync folder at \(path)")
                    NSSound.beep()
                }
            case .failure(let missing):
                let (message, detail) = syncFolderProblem(
                    missing.place, share: folder.share ?? folder.path)
                let alert = NSAlert()
                alert.messageText = message
                alert.informativeText = detail
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// Asks in a sheet over `window` to stop watching the folder at `position` in the setting.
    func confirmRemovingFolder(at position: Int, over window: NSWindow) {
        guard let settings, settings[\.watchedFolders].indices.contains(position) else {
            return NSSound.beep()
        }
        let folder = settings[\.watchedFolders][position]
        let name = (folder.path as NSString).lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Stop watching \(name.isEmpty ? folder.share ?? folder.path : name)?"
        alert.informativeText =
            "Its tracks leave the library. The files themselves aren't touched, and play counts"
            + " and ratings are kept for when the folder is added again."
        alert.addButton(withTitle: "Stop Watching")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try stopWatching(folder, settings) { self?.watcher }
            } catch {
                self?.fail("Couldn't stop watching \(folder.path)", error)
            }
        }
    }

    /// Rescans the folders at `positions` in the setting, as Settings ▸ Watched Folders lists them.
    func rescanFolders(at positions: [Int]) {
        guard let settings, let watcher else { return NSSound.beep() }
        let folders = settings[\.watchedFolders]
        watcher.rescan(folders: positions.filter(folders.indices.contains).map { folders[$0] })
    }

    func changedFolders(_ settings: ConfigStore<AppSettings>) {
        startWatching(settings)
        showConfigProblems()
    }

    // MARK: Errors

    func fail(_ message: String, _ error: any Error) {
        logger.error("\(message): \(error)")
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "\(error)"
        alert.runModal()
        if window == nil { NSApp.terminate(nil) }
    }
}

/// A play request whose start isn't one of its tracks.
enum PlayRequestError: Error, CustomStringConvertible {
    case noStart(Int, of: Int)

    var description: String {
        switch self {
        case .noStart(let first, let count): "track \(first + 1) of \(count) isn't in the queue"
        }
    }
}

/// Get Info's Discogs tab asked for the catalog before the settings that name it were read,
/// or as the app quits.
private struct NoSettings: Error, CustomStringConvertible {
    var description: String { "the settings that name the catalog aren't read" }
}
