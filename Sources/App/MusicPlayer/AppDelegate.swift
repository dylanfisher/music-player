import AppKit
import Artwork
import Commands
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
import TagEditor
import TagWriter
import UPnPOutput

private let logger = moduleLogger()

/// The composition root for the window: reads Settings once, builds the features, and wires the
/// playback engine, the HAL output and the library watcher to them.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The now-playing bar's art: twice its point size, for Retina displays.
    static let artPixels = HeaderPart.artPoints * 2
    static let artCacheImages = 64
    /// Now Playing's art: the current track's and the one before, for going back.
    static let systemArtCacheImages = 2

    let paths: AppPaths
    private let measuring: MeasurementKind?
    private let reportingLaunch: Bool
    private let snapshotURL: URL?
    private let snapshotOf: SnapshotTarget
    /// How long after the first rows the snapshot waits, for the scan and art to show.
    static let snapshotDelaySeconds = 4.0
    /// How long quitting waits for the outputs to close: longer than a device takes to restore
    /// its format, which it waits up to 3 s for.
    static let closeWaitSeconds = 6.0
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
    private(set) var saver: LayoutSaver?
    private(set) var window: MainWindow?
    private(set) var browser: LibraryBrowser?
    private(set) var nowPlaying: NowPlayingBar?
    private(set) var toolbar: MainToolbar?
    private(set) var signalPath: SignalPathPanel?
    /// Media keys, headphone buttons, Now Playing in Control Center, and the Dock menu.
    private var mediaControls: MediaControls?
    private var dockMenu: DockMenu?
    private(set) var queue: QueuePanel?
    private(set) var watcher: LibraryWatcher?
    private var shareChanges: ShareChangeObserver?
    private(set) var output: DeviceOutput?
    /// Each device's state before playback first changed it, shared by every provider made for
    /// it, since a settings change makes a new one.
    private let deviceSnapshots = DeviceSnapshots()
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
    private(set) var devicePath: SignalPath?
    private(set) var engine: PlaybackEngine?
    private var activity = PlaybackActivity.stopped
    /// The engine's latest state, for the menus' check marks.
    private(set) var playback = PlaybackState()
    /// Whether the device in use has a digital volume, from its profile.
    private(set) var digitalVolume = false
    /// The digital volume, in dB below full.
    var volumeDecibels = 0.0
    /// The UID of the device in use, whose profile the output settings and the volume change.
    private(set) var outputUID: String?
    /// Set while the config is being made to show the device in use, so those writes aren't
    /// taken as edits.
    private var showingInUse = false
    private var playbackUpdates: Task<Void, Never>?
    private var signalPathUpdates: Task<Void, Never>?
    private var returnUpdates: Task<Void, Never>?
    /// Plays and skips, counted from the engine's updates.
    private(set) var playTracker: PlayTracker?
    /// The smart playlist editor while it's open.
    var ruleEditor: RuleEditorSheet?
    /// The tag editor, which writes music files only after the user saves an edit (ADR 0020).
    private(set) lazy var tagEditing = makeTagEditing()
    private(set) var dispatcher: CommandDispatcher?
    /// Runs the tool's requests and links, once playback is ready.
    var scriptRouter: ScriptRouter?
    /// Receiver control, while `receiver.enabled` is on.
    var receiver: ReceiverControl?
    var scriptServer: LocalSocketServer?
    /// Links that came before the router, run once it's there.
    var waitingLinks: [String] = []
    private var menu: MainMenu?
    /// The output picker's devices and renderers, as last found, and what keeps them current.
    var foundDevices: [FoundOutput] = []
    var foundRenderers: [FoundOutput] = []
    var outputSearch: Task<Void, Never>?
    var deviceListWatch: DeviceListWatch?
    var outputMenu: OutputMenu?
    var playlistMenus: [PlaylistMenu] = []
    private let artwork = ArtworkLoader(maxPixelSize: artPixels, capacity: artCacheImages)
    /// Logs the main thread's stalls over 100 ms, for the field data the benches can't give.
    /// The art column's thumbnails, kept between launches (ADR 0079).
    private lazy var thumbnails = ThumbnailStore(directory: paths.thumbnailDirectory)
    private let stalls = StallDetector { NSApp.currentEvent.map { eventName($0.type) } }

    /// `measuring` runs `WindowMeasurement` once the table first draws rows, then quits.
    /// `reportingLaunch` prints a line once the first scan of each watched folder has ended.
    /// `snapshotURL` gets a PNG of the window a few seconds after that.
    init(
        paths: AppPaths, measuring: MeasurementKind?, reportingLaunch: Bool, snapshotURL: URL?,
        snapshotOf: SnapshotTarget
    ) {
        self.snapshotOf = snapshotOf
        self.paths = paths
        self.measuring = measuring
        self.reportingLaunch = reportingLaunch
        self.snapshotURL = snapshotURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
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
        } catch {
            fail("The library couldn't open", error)
        }
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
        let index = try LibraryIndex(at: databaseURL, movingAsideIfUnreadable: true)
        let browser = LibraryBrowser(
            reader: try LibraryReader(databaseURL: databaseURL), index: index,
            layout: layout.trackTable, browserHeight: layout.browserHeight,
            groupByAlbumArtist: layout.groupByAlbumArtist, thumbnails: thumbnails)
        browser.setTableAppearance(layout.tableAppearance)
        let lookup = { (path: String) in try index.track(path: path) }
        trackLookup = lookup
        let nowPlaying = NowPlayingBar(model: NowPlayingModel(lookup: lookup), artwork: artwork)
        nowPlaying.header.apply(layout.headerStatus)
        makeMediaControls(dispatcher, lookup: lookup)
        let queue = QueuePanel(model: QueueModel(lookup: lookup))
        let signalPath = SignalPathPanel()
        let toolbar = MainToolbar(
            identifier: String(describing: MainWindow.self), transport: nowPlaying.transport,
            status: nowPlaying.status, search: browser.searchField, dispatcher: dispatcher,
            items: state[\.toolbarItems])
        toolbar.statusLayout = layout.headerStatus
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
        self.nowPlaying = nowPlaying
        nowPlaying.follow(window.window)
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
        browser.addToQueue = { [weak self] urls in
            guard let engine = self?.engine else { return }
            Task { await engine.addToQueue(urls) }
        }
        browser.tableLayoutChanged = { saver.set(\.trackTable, $0) }
        browser.browserHeightChanged = { height in
            if AppState.browserHeightRange.contains(height) {
                saver.set(\.browserHeight, height)
            }
        }
        browser.stateChanged = { state in
            saver.set(\.source, state.source)
            saver.set(\.browserColumns, state.columns)
        }
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
        browser.watchedFolders = { settings[\.watchedFolders] }
        browser.watch = { [weak self] url in self?.watch(url, settings) }
        browser.firstRowsDrawn = { [weak self] in self?.interactive() }
        let keyCommand = { [weak self] (chords: [KeyChord]) in
            self?.dispatcher?.key(chords) ?? .unbound
        }
        browser.keyCommand = keyCommand
        queue.keyCommand = keyCommand
        applyStatusBar(layout.statusBar)
        if !layout.statusBarVisible { browser.toggleStatusBar() }
        browser.statusTotals = layout.statusTotals
        browser.statusTotalsChanged = { saver.set(\.statusTotals, $0) }
        if !layout.browserVisible { browser.toggleBrowser() }

        window.show()
        NSApp.activate(ignoringOtherApps: true)
        Task { await browser.load(layout.browser) }
        if let aside = index.movedAside { showMovedAside(aside, in: window.window) }
    }

    /// Says the library file couldn't be read and where it went, with a way to find it.
    private func showMovedAside(_ aside: URL, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "The library file couldn't be read"
        alert.informativeText =
            "It was moved to \(aside.path), and a new library was started. The next scan fills"
            + " it. The plays, ratings and playlists stay in the old file."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            NSWorkspace.shared.activateFileViewerSelecting([aside])
        }
    }

    /// The first rows are on screen. Everything that can wait for that starts now.
    private func interactive() {
        guard let settings else { return }
        signposted(.launchServices) { startServices(settings) }
    }

    private func startServices(_ settings: ConfigStore<AppSettings>) {
        startPlayback(settings)
        applyRendererSetting()
        thumbnails.trimInBackground()
        startScripting()
        applyReceiverSetting()
        startWatching(settings)
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
            case .main: { [weak self] in self?.window?.window }
            case .palette: { [weak self] in self?.palette?.window }
            case .playlist: { [weak self] in self?.ruleEditor?.window }
            case .tags: { [weak self] in self?.tagEditing.sheet?.window }
            case .settings, .playback, .appearance, .folders, .shortcuts:
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
            }
        // The palette lists its items, and the tag editor reads its files, first.
        let wait = snapshotOf == .main ? 0 : snapshotOf == .tags ? 3.0 : 1.0
        switch snapshotOf {
        case .main: break
        case .palette: dispatcher?.run(.showPalette)
        case .playlist: dispatcher?.run(.newSmartPlaylist)
        case .tags:
            browser?.selectAllTracks()
            dispatcher?.run(.editTags)
        case .settings: settingsWindowController()?.show(.general)
        case .playback: settingsWindowController()?.show(.playback)
        case .appearance: settingsWindowController()?.show(.appearance)
        case .folders: settingsWindowController()?.show(.folders)
        case .shortcuts: settingsWindowController()?.show(.shortcuts)
        case .statusBar:
            settingsWindowController()?.showBarBuilder(AppSettings().statusBarLayout.key)
        case .headerStatus:
            settingsWindowController()?.showBarBuilder(AppSettings().headerStatusLayout.key)
        case .toolbarSheet: toolbar?.toolbar.runCustomizationPalette(nil)
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

    func applicationWillTerminate(_ notification: Notification) {
        volumeKeyTap?.stop()
        scriptServer?.stop()
        receiver?.stop()
        window?.saveToolbarVisibility()
        saver?.flush()
        watcher?.stop()
        // Puts the device and the default outputs back the way they were. The device output's
        // close waits on its control thread, which a read from a share that stopped answering
        // holds. The renderer's close stops its HTTP server, which waits on the queue that
        // reads the file it serves, so a hung share holds that too. Both close together within
        // one bound; the device's restore record puts it back at the next launch instead.
        var outputs: [any Output] = []
        if let rendererOutput { outputs.append(rendererOutput) }
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

    /// Opens nothing yet: the device is held only once something plays.
    func startPlayback(_ settings: ConfigStore<AppSettings>) {
        do {
            let recordURL = restoreRecordURL(in: paths.dataDirectory)
            if let recovered = try HALDeviceProvider.recoverAfterCrash(restoreRecordURL: recordURL)
            {
                logger.notice("\(recovered)")
            }
            let profile = try outputProfile(settings, switched: false)
            try save(profile)
            let output = try DeviceOutput(try deviceChoice(profile))
            let engine = PlaybackEngine(output: output)
            showInUse(profile, settings)
            self.output = output
            self.engine = engine
            nowPlaying?.connect(engine)
            mediaControls?.connect(engine)
            queue?.connect(engine)
            // The output's stream ends when it closes, so a reopened output replaces this.
            signalPathUpdates?.cancel()
            signalPathUpdates = Task { [weak self] in
                for await path in output.signalPaths {
                    self?.devicePath = path
                    // While a renderer plays, the panel shows its path instead.
                    if self?.rendererOutput == nil { self?.signalPath?.show(path) }
                    self?.recordFormats(path)
                }
            }
            returnUpdates = Task { [weak self] in
                for await uid in output.returns { self?.outputReturned(to: uid) }
            }
            playbackUpdates = Task { [weak self] in
                for await update in await engine.updates() {
                    self?.playback = update.state
                    self?.playbackChanged(update.state)
                    self?.browser?.showPlaying(path: self?.currentTrackPath)
                    self?.playTracker?.handle(update)
                    if case .trackStarted(let index) = update.event {
                        self?.countPlay(update.state.queue[index].path)
                    }
                }
            }
        } catch {
            logger.error("no output: \(error)")
            mediaControls?.refreshCommands()
            nowPlaying?.showUnavailable("No output device: \(error)")
            signalPath?.show(nil)
        }
    }

    private func makeTagEditing() -> TagEditing {
        let editing = TagEditing(
            writer: TagWriter(journal: TagUndoJournal(dataDirectory: paths.dataDirectory)))
        editing.written = { [weak self] paths in
            let folders = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
            self?.watcher?.rescan(directories: folders.sorted())
        }
        editing.replaceArtwork = { [weak self] in self?.dispatcher?.run(.replaceArtwork) }
        editing.removeArtwork = { [weak self] in self?.dispatcher?.run(.removeArtwork) }
        return editing
    }

    private func makeMediaControls(
        _ dispatcher: CommandDispatcher, lookup: @escaping (String) throws -> TrackRow?
    ) {
        let controls = MediaControls(
            model: NowPlayingModel(lookup: lookup), dispatcher: dispatcher,
            remote: SystemRemoteCommands(), center: SystemNowPlaying(),
            artwork: ArtworkLoader(
                maxPixelSize: MediaControls.artPixels, capacity: Self.systemArtCacheImages),
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

    private func play(_ request: PlayRequest) {
        guard let engine else { return }
        guard request.urls.indices.contains(request.first) else {
            fail("Couldn't play", PlayRequestError.noStart(request.first, of: request.urls.count))
            return
        }
        // Through `play(starting:)`, so the output keeps the device open (ADR 0078).
        Task {
            let filling = await engine.play(starting: request.urls[request.first]) {
                (request.urls, request.first)
            }
            do {
                try await filling.value
            } catch {
                fail("Couldn't play the queue", error)
            }
        }
    }

    /// Moves the output to the device and settings the config names now, mid-track if one is
    /// playing. `switched` says whether the config's device changed (ADR 0037).
    func outputSettingsChanged(switched: Bool) {
        guard let settings, let output, !showingInUse else { return }
        do {
            let profile = try outputProfile(settings, switched: switched)
            if let inUse = inUseProfile, inUse.uid == profile.uid, inUse.hogMode == profile.hogMode,
                inUse.digitalVolume == profile.digitalVolume
            {
                return
            }
            try save(profile)
            output.use(try deviceChoice(profile))
            showInUse(profile, settings)
        } catch {
            fail("Couldn't switch the output device", error)
        }
    }

    /// The output went back on its own to a device that came back.
    private func outputReturned(to uid: String) {
        guard let settings, let state else { return }
        // It was in use before, so it has a profile, and its kind isn't read.
        let profile = state[\.deviceProfiles].profile(
            for: uid, config: outputConfig(settings), switched: true, typeHogs: nil)
        do {
            try save(profile)
        } catch {
            logger.error("couldn't save \(uid)'s profile: \(error)")
        }
        showInUse(profile, settings)
    }

    private var inUseProfile: DeviceProfile? {
        state?[\.deviceProfiles].profiles.first { $0.uid == outputUID }
    }

    private func outputConfig(_ settings: ConfigStore<AppSettings>) -> OutputConfig {
        OutputConfig(hogMode: settings[\.hogMode], digitalVolume: settings[\.digitalVolume])
    }

    private func outputProfile(_ settings: ConfigStore<AppSettings>, switched: Bool) throws
        -> DeviceProfile
    {
        let uid = try HALDeviceProvider.resolve(
            settings[\.outputDeviceUID], snapshots: deviceSnapshots)
        return profileState[\.deviceProfiles].profile(
            for: uid, config: outputConfig(settings), switched: switched, typeHogs: typeHogs(uid))
    }

    /// Whether a device seen for the first time hogs, from its transport type. A device whose
    /// type can't be read starts from `output.hogMode`, as one not connected does.
    private func typeHogs(_ uid: String) -> Bool? {
        do {
            return try HALDeviceProvider.hogsByDefault(uid)
        } catch {
            logger.error(
                "can't read \(uid)'s transport type; it starts from output.hogMode: \(error)")
            return nil
        }
    }

    /// Written before the output uses it, so a crash never leaves the device with settings its
    /// profile doesn't hold.
    private func save(_ profile: DeviceProfile) throws {
        try profileState.set(\.deviceProfiles, to: profileState[\.deviceProfiles].using(profile))
    }

    private var profileState: StateStore<AppState> {
        guard let state else { preconditionFailure("the state file opens before playback starts") }
        return state
    }

    private func deviceChoice(_ profile: DeviceProfile) throws -> DeviceChoice {
        DeviceChoice(
            provider: try HALDeviceProvider(
                deviceUID: profile.uid, hogMode: profile.hogMode,
                restoreRecordURL: restoreRecordURL(in: paths.dataDirectory),
                snapshots: deviceSnapshots),
            digitalVolume: profile.digitalVolume, gain: pow(10, profile.volumeDecibels / 20),
            formats: profile.formats)
    }

    /// Makes `profile` the one in use, and the config's output settings show it, so the menus
    /// and the settings window read what the device plays with.
    private func showInUse(_ profile: DeviceProfile, _ settings: ConfigStore<AppSettings>) {
        outputUID = profile.uid
        digitalVolume = profile.digitalVolume
        volumeDecibels = profile.volumeDecibels
        showingInUse = true
        defer { showingInUse = false }
        do {
            // Null, the system default, is left alone while it still names this device.
            let named = settings[\.outputDeviceUID]
            if named != profile.uid,
                try named != nil
                    || HALDeviceProvider.resolve(nil, snapshots: deviceSnapshots) != profile.uid
            {
                try settings.set(\.outputDeviceUID, to: profile.uid)
            }
            if settings[\.hogMode] != profile.hogMode {
                try settings.set(\.hogMode, to: profile.hogMode)
            }
            if settings[\.digitalVolume] != profile.digitalVolume {
                try settings.set(\.digitalVolume, to: profile.digitalVolume)
            }
        } catch {
            logger.error("couldn't show \(profile.uid)'s settings in the config: \(error)")
        }
    }

    /// Records the rates and formats the device in the path reported, when they changed.
    private func recordFormats(_ path: SignalPath) {
        guard case .device(let sink) = path.sink, case .connected(let signal) = sink.state,
            let state,
            let next = state[\.deviceProfiles].reporting(signal.formats, for: sink.uid)
        else { return }
        do {
            try state.set(\.deviceProfiles, to: next)
        } catch {
            logger.error("couldn't record \(sink.uid)'s formats: \(error)")
        }
    }

    /// Saves the digital volume in the profile of the device in use, before it's applied.
    func saveVolume(_ decibels: Double) {
        guard var profile = inUseProfile else { return }
        profile.volumeDecibels = decibels
        do {
            try save(profile)
        } catch {
            logger.error("couldn't save the volume in \(profile.uid)'s profile: \(error)")
        }
    }

    /// Tells the watcher, so network rescans stay off the NAS while a track starts.
    private func playbackChanged(_ state: PlaybackState) {
        let now = watcherActivity(state)
        guard now != activity, let settings else { return }
        activity = now
        watcher?.playbackChanged(
            now, pausePollingDuringPlayback: settings[\.pausePollingDuringPlayback])
    }

    // MARK: Watched folders

    private func startWatching(_ settings: ConfigStore<AppSettings>) {
        watcher?.stop()
        watcher = nil
        guard let browser else { return }
        guard
            let watcher = startedWatcher(
                settings, databaseURL: libraryFileURL(in: paths.dataDirectory),
                events: reportingLaunch
                    ? reportingLaunchEnd(browser.watcherEvents) : browser.watcherEvents)
        else {
            // No folder has a scan to wait for.
            if reportingLaunch { FileHandle.standardOutput.write(launchedLine) }
            return
        }
        if activity != .stopped {
            watcher.playbackChanged(
                activity, pausePollingDuringPlayback: settings[\.pausePollingDuringPlayback])
        }
        self.watcher = watcher
    }

    /// `events`, and a "launched" line on standard output once the watcher's scans at start
    /// have ended.
    private func reportingLaunchEnd(
        _ events: @escaping @Sendable (WatcherEvent) -> Void
    ) -> @Sendable (WatcherEvent) -> Void {
        { event in
            events(event)
            if case .launchScansEnded = event {
                FileHandle.standardOutput.write(launchedLine)
            }
        }
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

    /// Asks for the sync folder, stored by share when it's on one, as a watched folder is.
    func chooseSyncFolder() {
        guard let settings else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Sync Here"
        panel.message =
            "Choose a folder outside your music for the Macs that play this library to share"
            + " their stats through. The app writes only its own log there."
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

    /// Rescans the folders at `positions` in the setting, as the Watched Folders table lists them.
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

/// What `--report-launch` prints once the launch's scans have ended.
private let launchedLine = Data("launched\n".utf8)

/// A play request whose start isn't one of its tracks.
enum PlayRequestError: Error, CustomStringConvertible {
    case noStart(Int, of: Int)

    var description: String {
        switch self {
        case .noStart(let first, let count): "track \(first + 1) of \(count) isn't in the queue"
        }
    }
}
