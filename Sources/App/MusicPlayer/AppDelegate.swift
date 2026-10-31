import AppKit
import Artwork
import Commands
import HALOutput
import KeyChord
import Library
import LibraryBrowser
import Log
import NowPlaying
import Palette
import Playback
import QueueView
import Settings
import SettingsWindow

private let logger = moduleLogger()

/// The composition root for the window: reads Settings once, builds the features, and wires the
/// playback engine, the HAL output and the library watcher to them.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The now-playing bar's art: twice its point size, for Retina displays.
    static let artPixels = Int(NowPlayingBar.artPoints) * 2
    static let artCacheImages = 64

    private let paths: AppPaths
    private let measuring: Bool
    private let snapshotURL: URL?
    private let snapshotOf: SnapshotTarget
    /// How long after the first rows the snapshot waits, for the scan and art to show.
    static let snapshotDelaySeconds = 4.0
    private(set) var settings: ConfigStore<AppSettings>?
    let banner = ConfigBanner()
    private(set) var state: StateStore<AppState>?
    var palette: PaletteController?
    var settingsWindow: SettingsWindowController?
    /// What each ⌘K entry item opens, by its key.
    var paletteEntries: [String: (BrowserModel.Pane, Int64)] = [:]
    /// Looks a track up by path, for counting plays toward frecency.
    private(set) var trackLookup: ((String) throws -> TrackRow?)?
    private(set) var saver: LayoutSaver?
    private(set) var window: MainWindow?
    private(set) var browser: LibraryBrowser?
    private var nowPlaying: NowPlayingBar?
    private(set) var queue: QueuePanel?
    private var watcher: LibraryWatcher?
    private(set) var output: DeviceOutput?
    private(set) var engine: PlaybackEngine?
    private var activity = PlaybackActivity.stopped
    /// The engine's latest state, for the menus' check marks.
    private(set) var playback = PlaybackState()
    /// Whether the output has a volume, from the setting read at launch.
    private(set) var digitalVolume = false
    /// The digital volume, in dB below full.
    var volumeDecibels = 0.0
    /// The output settings changed while playing; the output reopens once playback stops.
    var outputChanged = false
    private var playbackUpdates: Task<Void, Never>?
    private(set) var dispatcher: CommandDispatcher?
    private var menu: MainMenu?
    private let artwork = ArtworkLoader(maxPixelSize: artPixels, capacity: artCacheImages)

    /// `measuring` runs `WindowMeasurement` once the table first draws rows, then quits.
    /// `snapshotURL` gets a PNG of the window a few seconds after that.
    init(paths: AppPaths, measuring: Bool, snapshotURL: URL?, snapshotOf: SnapshotTarget) {
        self.snapshotOf = snapshotOf
        self.paths = paths
        self.measuring = measuring
        self.snapshotURL = snapshotURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let settings = ConfigStore(
                AppSettings(), fileURL: paths.configFile, check: try shortcutCheck(),
                creating: true)
            self.settings = settings
            applyAppearance(settings[\.appearance])
            let dispatcher = CommandDispatcher(bindings: try keyBindings(settings.shortcuts))
            let menu = MainMenu(dispatcher: dispatcher, appName: appName, settings: AppSettings())
            dispatcher.bindingsChanged = { [weak menu] in menu?.showChords() }
            NSApp.mainMenu = menu.bar
            NSApp.windowsMenu = menu.windowsMenu
            NSApp.helpMenu = menu.helpMenu
            self.dispatcher = dispatcher
            self.menu = menu
            try openWindow(settings)
            registerCommands(dispatcher)
            if let state, let saver { makePalette(dispatcher, state: state, saver: saver) }
            registerSettingCommands(dispatcher)
            settings.changed = { [weak self] keys in self?.settingsChanged(keys) }
            settings.problemsChanged = { [weak self] in self?.showConfigProblems() }
            banner.openConfigFile = { [weak dispatcher] in dispatcher?.run(.openConfigFile) }
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

    private func openWindow(_ settings: ConfigStore<AppSettings>) throws {
        let state = try StateStore(AppState(), fileURL: paths.stateFile)
        self.state = state
        let saver = LayoutSaver(state)
        self.saver = saver
        let layout = WindowSettings(settings, state: state)
        let databaseURL = libraryFileURL(in: paths.dataDirectory)
        // Rows for the table come from a connection of the main thread's own.
        let index = try LibraryIndex(at: databaseURL)
        let browser = LibraryBrowser(
            reader: try LibraryReader(databaseURL: databaseURL), index: index,
            layout: layout.trackTable, browserHeight: layout.browserHeight,
            folders: layout.folders)
        let lookup = { (path: String) in try index.track(path: path) }
        trackLookup = lookup
        let nowPlaying = NowPlayingBar(model: NowPlayingModel(lookup: lookup), artwork: artwork)
        let queue = QueuePanel(model: QueueModel(lookup: lookup))
        let window = MainWindow(
            settings: layout, banner: banner.view, browser: browser, nowPlaying: nowPlaying,
            queue: queue, saver: saver)
        self.browser = browser
        self.nowPlaying = nowPlaying
        self.queue = queue
        self.window = window

        nowPlaying.toggleQueue = { [weak window] in window?.toggleQueue() }
        browser.play = { [weak self] request in self?.play(request) }
        browser.playNext = { [weak self] urls in
            guard let engine = self?.engine else { return }
            Task { await engine.playNext(urls) }
        }
        browser.tableLayoutChanged = { saver.set(\.trackTable, $0) }
        browser.browserHeightChanged = { height in
            if AppState.browserHeightRange.contains(height) {
                saver.set(\.browserHeight, height)
            }
        }
        browser.stateChanged = { state in
            saver.set(\.source, state.source)
            saver.set(\.selectedGenre, state.genre)
            saver.set(\.selectedArtist, state.artist)
            saver.set(\.selectedAlbum, state.album)
        }
        browser.libraryRefreshed = {
            nowPlaying.libraryChanged()
            queue.libraryChanged()
        }
        browser.addFolder = { [weak self] in self?.addFolder() }
        browser.removeFolder = { [weak self] path in self?.confirmRemoving(path) }
        browser.firstRowsDrawn = { [weak self] in self?.interactive() }
        let keyCommand = { [weak self] (chords: [KeyChord]) in
            self?.dispatcher?.key(chords) ?? .unbound
        }
        browser.keyCommand = keyCommand
        queue.keyCommand = keyCommand
        if !layout.statusBarVisible { browser.toggleStatusBar() }

        window.show()
        NSApp.activate(ignoringOtherApps: true)
        Task { await browser.load(layout.browser) }
    }

    /// The first rows are on screen. Everything that can wait for that starts now.
    private func interactive() {
        guard let settings else { return }
        startPlayback(settings)
        startWatching(settings[\.watchedFolders], settings)
        if let snapshotURL {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.snapshotDelaySeconds) {
                [weak self] in self?.snapshot(to: snapshotURL)
            }
        }
        if measuring, let browser {
            // After this turn of the run loop, so the first frame is counted as drawn.
            DispatchQueue.main.async { [artwork] in
                WindowMeasurement.run(browser: browser, artwork: artwork)
            }
        }
    }

    /// Draws `snapshotOf` into a PNG; the palette gets a second to list its items first.
    private func snapshot(to url: URL) {
        let target: () -> NSWindow? =
            switch snapshotOf {
            case .main: { [weak self] in self?.window?.window }
            case .palette: { [weak self] in self?.palette?.window }
            case .settings, .shortcuts: { [weak self] in self?.settingsWindow?.window }
            }
        let wait = snapshotOf == .main ? 0 : 1.0
        switch snapshotOf {
        case .main: break
        case .palette: dispatcher?.run(.showPalette)
        case .settings: settingsWindowController()?.show(.general)
        case .shortcuts: settingsWindowController()?.show(.shortcuts)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            do {
                guard let window = target() else { throw SnapshotError(path: url.path) }
                try writeSnapshot(of: window, to: url)
            } catch {
                logger.error("\(error)")
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            }
        }
    }

    /// App ▸ Settings…, which the standard item sends up the responder chain.
    @objc func showSettings(_ sender: Any?) {
        settingsWindowController()?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saver?.flush()
        watcher?.stop()
        // Puts the device and the default outputs back the way they were.
        output?.close()
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
            let provider = try HALDeviceProvider(
                deviceUID: settings[\.outputDeviceUID], hogMode: settings[\.hogMode],
                restoreRecordURL: recordURL)
            let output = try DeviceOutput(
                provider: provider, digitalVolume: settings[\.digitalVolume])
            let engine = PlaybackEngine(output: output)
            digitalVolume = settings[\.digitalVolume]
            self.output = output
            self.engine = engine
            nowPlaying?.connect(engine)
            queue?.connect(engine)
            playbackUpdates = Task { [weak self] in
                for await update in await engine.updates() {
                    self?.playback = update.state
                    self?.playbackChanged(update.state)
                    if case .trackStarted(let index) = update.event {
                        self?.countPlay(update.state.queue[index].path)
                    }
                }
            }
        } catch {
            logger.error("no output: \(error)")
            nowPlaying?.showUnavailable("No output device: \(error)")
        }
    }

    private func play(_ request: PlayRequest) {
        guard let engine else { return }
        Task {
            await engine.setQueue(request.urls, first: request.first)
            await engine.play()
        }
    }

    /// Opens the output again with the output settings as they are now. While something plays
    /// or is paused, that waits until playback stops, so a settings change never cuts a track.
    func reopenOutput() {
        guard let settings, output != nil else { return }
        guard playback.status == .stopped else {
            outputChanged = true
            logger.notice("the output settings changed; they apply once playback stops")
            return
        }
        outputChanged = false
        playbackUpdates?.cancel()
        output?.close()
        output = nil
        engine = nil
        playback = PlaybackState()
        startPlayback(settings)
    }

    /// Tells the watcher, so network rescans stay off the NAS while a track starts.
    private func playbackChanged(_ state: PlaybackState) {
        if outputChanged, state.status == .stopped { reopenOutput() }
        let now = watcherActivity(state)
        guard now != activity, let settings else { return }
        activity = now
        watcher?.playbackChanged(
            now, pausePollingDuringPlayback: settings[\.pausePollingDuringPlayback])
    }

    // MARK: Watched folders

    private func startWatching(_ folders: [WatchedFolder], _ settings: ConfigStore<AppSettings>) {
        watcher?.stop()
        guard let browser else { return }
        let watcher = LibraryWatcher(
            databaseURL: libraryFileURL(in: paths.dataDirectory),
            networkReaders: settings[\.networkScanReaders], events: browser.watcherEvents)
        let pause = settings[\.pausePollingDuringPlayback]
        watcher.start(folders: folders, pausePollingDuringPlayback: pause)
        if activity != .stopped {
            watcher.playbackChanged(activity, pausePollingDuringPlayback: pause)
        }
        self.watcher = watcher
    }

    func addFolder() {
        guard let settings, let window = window?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch"
        panel.message = "Choose a folder of music to add to the library. Its files are only read."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.watch(url, settings)
        }
    }

    private func watch(_ url: URL, _ settings: ConfigStore<AppSettings>) {
        let path = url.standardizedFileURL.path
        var folders = settings[\.watchedFolders]
        guard !folders.contains(where: { $0.path == path }) else { return }
        do {
            // FSEvents reports nothing on network volumes, so those are polled.
            let local = try url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
            folders.append(WatchedFolder(path: path, kind: local == true ? .local : .network))
            try settings.set(\.watchedFolders, to: folders)
        } catch {
            fail("Couldn't add \(path)", error)
        }
    }

    private func confirmRemoving(_ path: String) {
        guard let settings, let window = window?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Stop watching \((path as NSString).lastPathComponent)?"
        alert.informativeText =
            "Its tracks leave the library. The files themselves aren't touched, and play counts"
            + " and ratings are kept for when the folder is added again."
        alert.addButton(withTitle: "Stop Watching")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let folders = settings[\.watchedFolders].filter { $0.path != path }
            do {
                try settings.set(\.watchedFolders, to: folders)
            } catch {
                self?.fail("Couldn't remove \(path)", error)
            }
        }
    }

    func changedFolders(_ folders: [WatchedFolder], _ settings: ConfigStore<AppSettings>) {
        startWatching(folders, settings)
        if let browser { Task { await browser.setFolders(folders) } }
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
