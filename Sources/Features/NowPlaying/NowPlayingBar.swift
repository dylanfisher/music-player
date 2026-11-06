import AppKit
import Artwork
import Commands
import Library
import Log
import Playback
import Settings

private let logger = moduleLogger()

/// The toolbar's playback items: the transport buttons, and the now-playing status with the
/// current track, its times, a seek bar and the output format; and the playing track's parts of
/// the status bar. It reads the engine's updates and sends it the buttons; the model decides
/// what to show.
@MainActor
public final class NowPlayingBar: NSObject {
    /// How often the position updates while playing. Nothing ticks while paused or stopped, or
    /// while the window doesn't show.
    static let positionIntervalSeconds = 0.5

    public let model: NowPlayingModel
    /// The previous, play and next buttons.
    public let transport: NSView
    /// Art, title, artist and album, the format line, and a seek bar with times, in the
    /// columns the user lays out.
    public let header = HeaderStatus()
    public var status: NSView { header.view }
    /// The toolbar's Custom Status items, one per `ToolbarItem.customStatuses` slot, each with
    /// its own views and layout, showing the same track as the status (ADR 0089).
    public let customStatuses = ToolbarItem.customStatuses.map { _ in HeaderStatus() }
    /// What the Title Line says, in the status and in each Custom Status item.
    public var titleFormat = TitleTemplate.titleLine {
        didSet { show() }
    }
    /// The status bar's art, track, format and seek bar.
    public let statusBar = StatusBarParts()
    /// Called when the playback problem in the status bar is clicked.
    public var problemOpened: (ShownProblem) -> Void = { _ in }
    /// Called with a fix the user chose for a problem, and the track to play again once it's
    /// made.
    public var fixRequested: (PlaybackFix, URL?) -> Void = { _, _ in }
    /// Shows a problem's dialog as a sheet over the window; tests replace it.
    var showDialog: (ProblemDialog) -> Void = { _ in }
    /// What the window's title says while a track plays.
    public var windowTitle = TitleTemplate.windowTitle {
        didSet { show() }
    }
    /// Called with the window's title as the track or its tags change: nil for the app's name.
    public var windowTitleChanged: (String?) -> Void = { _ in }
    private let artwork: ArtworkLoader
    private var engine: PlaybackEngine?
    private var updates: Task<Void, Never>?
    private var timer: Timer?
    /// Seeks sent to the engine and not yet done, while which the bars keep the target.
    private var pendingSeeks = 0
    /// Whether the engine is connected and an output opened.
    private var connected = false
    /// Why no output could be opened, which the format line says until an engine connects.
    private var unavailableReason: String?
    /// Whether any of the window shows. AppKit draws a window that's covered, so the bar stops
    /// its updates itself.
    private var windowShows = true
    private var occlusion: NSObjectProtocol?
    /// The window the bar is in, which a problem's dialog shows over.
    private weak var window: NSWindow?

    private let previousButton = NSButton()
    private let playButton = NSButton()
    private let nextButton = NSButton()

    public init(model: NowPlayingModel, artwork: ArtworkLoader) {
        self.model = model
        self.artwork = artwork
        let transport = NSStackView(views: [previousButton, playButton, nextButton])
        transport.spacing = 4
        self.transport = transport
        super.init()
        for (button, action) in [
            (previousButton, #selector(previous)), (playButton, #selector(playPause)),
            (nextButton, #selector(next)),
        ] {
            button.target = self
            button.action = action
        }
        Self.setUpTransport(previousButton, playButton, nextButton)
        for bar in seekBars {
            bar.seek = { [weak self] fraction, done in self?.seek(to: fraction, done: done) }
        }
        statusBar.problemClicked = { [weak self] in
            guard let self, let problem = model.problem else { return }
            problemOpened(problem)
        }
        showDialog = { [weak self] in self?.present($0) }
        setEnabled(false)
        show()
    }

    /// Updates the position only while `window`, which holds the bar, shows: not while it's
    /// minimized, hidden, covered or behind a locked screen. It counts as showing until the
    /// first change, since a window not yet on screen reports itself hidden.
    public func follow(_ window: NSWindow) {
        self.window = window
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.windowShowsChanged(window?.occlusionState.contains(.visible) == true)
            }
        }
    }

    func windowShowsChanged(_ shows: Bool) {
        windowShows = shows
        tickWhilePlaying()
        if shows { Task { await showPosition() } }
    }

    /// Whether the position is updating.
    var ticks: Bool { timer != nil }

    /// Follows `engine` from now on.
    public func connect(_ engine: PlaybackEngine) {
        self.engine = engine
        unavailableReason = nil
        updates?.cancel()
        updates = Task { [weak self] in
            for await update in await engine.updates() {
                self?.apply(update)
            }
        }
        setEnabled(true)
    }

    /// A rescan may have changed the current track's tags or art.
    public func libraryChanged() {
        model.libraryChanged()
        loadArt()
        show()
    }

    /// No output could be opened, so nothing can play. Says why in the format line.
    public func showUnavailable(_ reason: String) {
        setEnabled(false)
        unavailableReason = reason
        show()
    }

    /// Gives the previous, play and next buttons their look, for the bar and for the drawing
    /// the toolbar's customization sheet shows.
    static func setUpTransport(_ previous: NSButton, _ play: NSButton, _ next: NSButton) {
        for (button, symbol, label) in [
            (previous, "backward.fill", "Previous"),
            (play, "play.fill", AppCommands.title(of: .play)), (next, "forward.fill", "Next"),
        ] {
            button.bezelStyle = .texturedRounded
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.toolTip = label
        }
    }

    func setEnabled(_ enabled: Bool) {
        connected = enabled
        for control in [previousButton, playButton, nextButton] { control.isEnabled = enabled }
        enableSeekBars()
    }

    /// The bars seek only in a track of known length, with the engine connected.
    private func enableSeekBars() {
        let seekable = connected && (model.state.durationSeconds ?? 0) > 0
        for bar in seekBars { bar.isEnabled = seekable }
    }

    func apply(_ update: PlaybackUpdate) {
        let before = model.currentURL
        model.apply(update)
        if model.currentURL != before {
            loadArt()
            // A drag over the last track mustn't seek this one.
            for bar in seekBars { bar.cancelTracking() }
        }
        show()
        tickWhilePlaying()
        if !model.isPlaying { Task { await showPosition() } }
        switch update.event {
        case .trackFailed?, .failed?:
            if let shown = model.problem, let dialog = ProblemDialog(shown) { showDialog(dialog) }
        default: break
        }
    }

    /// Shows `dialog` over the window, unless a sheet is up there already, as when several
    /// tracks fail for the same reason one after another.
    private func present(_ dialog: ProblemDialog) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = dialog.title
        alert.informativeText = dialog.text
        for button in dialog.buttons { alert.addButton(withTitle: button.title) }
        alert.beginSheetModal(for: window) { [weak self] response in
            let index =
                response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard let self, dialog.buttons.indices.contains(index) else { return }
            switch dialog.buttons[index] {
            case .fix(let fix): fixRequested(fix, dialog.shown.track)
            case .cancel: break
            }
        }
    }

    private func tickWhilePlaying() {
        if model.isPlaying, windowShows {
            startTimer()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func show() {
        let titleLine = titleFormat.fill(model.value(of:))
        let format = unavailableReason ?? model.message ?? model.formatLine
        let formatColor: NSColor =
            unavailableReason != nil
            ? .systemRed : model.message != nil ? .systemOrange : .secondaryLabelColor
        for header in headers {
            // A message says what went wrong even with nothing playing.
            header.showsParts =
                model.currentURL != nil || model.message != nil || unavailableReason != nil
            header.titleLabel.stringValue = model.title
            header.titleLineLabel.stringValue = titleLine
            // The line truncates at its tail, so the tooltip has all of it.
            header.titleLineLabel.toolTip = titleLine
            // An empty line leaves no blank line in its column.
            header.titleLineLabel.isHidden = titleLine.isEmpty
            header.subtitleLabel.stringValue = model.subtitle
            header.formatLabel.stringValue = format
            header.formatLabel.textColor = formatColor
            header.formatLabel.toolTip = format
        }
        // With nothing playing the art keeps its place unseen, so nothing beside it moves
        // when a track starts.
        for art in headers.map(\.art) + [statusBar.art] {
            art.alphaValue = model.currentURL == nil ? 0 : 1
        }
        statusBar.show(title: model.title, subtitle: model.subtitle)
        windowTitleChanged(model.windowTitle(windowTitle))
        statusBar.show(
            format: format, color: formatColor,
            problem: unavailableReason == nil && model.problem != nil)
        let playing = model.isPlaying
        let title = AppCommands.title(of: playing ? .pause : .play)
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: title)
        playButton.toolTip = title
        enableSeekBars()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.positionIntervalSeconds, repeats: true) {
            [weak self] _ in
            Task { @MainActor in await self?.showPosition() }
        }
        // A little slack lets the system batch the wakeups.
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func showPosition() async {
        let position = await engine?.position()
        // While the pointer holds a bar, the times follow it instead.
        guard pendingSeeks == 0, !seekBars.contains(where: \.isTracking) else { return }
        showTimes(model.times(positionSeconds: position))
        let fraction =
            if let duration = model.state.durationSeconds, duration > 0, let position {
                position / duration
            } else {
                0.0
            }
        for bar in seekBars { bar.fraction = fraction }
    }

    private func showTimes(_ times: (elapsed: String, total: String)) {
        for box in headers.map(\.seekBox) + [statusBar.seekBox] {
            box.showTimes(elapsed: times.elapsed, total: times.total)
        }
    }

    /// The toolbar's status and its Custom Status items, which show the same track.
    private var headers: [HeaderStatus] { [header] + customStatuses }

    /// The toolbar's and the status bar's.
    private var seekBars: [SeekBar] { headers.map(\.seekBox.bar) + [statusBar.seekBox.bar] }

    private func loadArt() {
        showArt(nil)
        guard let track = model.track, let embedded = track.art else { return }
        let key = ArtworkKey(path: track.path, art: embedded)
        if let image = artwork.cached(key) {
            showArt(NSImage(cgImage: image, size: .zero))
            return
        }
        let artwork = artwork
        let url = model.currentURL
        Task {
            let result = await artwork.load(embedded, path: track.path)
            guard self.model.currentURL == url else { return }
            switch result {
            case .success(let image): self.showArt(NSImage(cgImage: image, size: .zero))
            case .failure(let error):
                logger.error("\(error)")
                self.showArt(nil, toolTip: "\(error)")
            }
        }
    }

    private func showArt(_ image: NSImage?, toolTip: String? = nil) {
        for view in headers.map(\.art) + [statusBar.art] {
            view.image = image
            view.toolTip = toolTip
        }
    }

    // MARK: Buttons

    @objc private func playPause() {
        guard let engine else { return }
        Task { await engine.togglePause() }
    }

    @objc private func previous() {
        guard let engine else { return }
        Task { await engine.previous() }
    }

    @objc private func next() {
        guard let engine else { return }
        Task { await engine.next() }
    }

    /// Shows the times at `fraction` and both bars there; `done` seeks the engine, and the bars
    /// hold the target until it has.
    private func seek(to fraction: Double, done: Bool) {
        guard let engine, let duration = model.state.durationSeconds, duration > 0 else {
            for bar in seekBars { bar.fraction = 0 }
            return
        }
        let seconds = fraction * duration
        for bar in seekBars { bar.fraction = fraction }
        showTimes(model.times(positionSeconds: seconds))
        guard done else { return }
        pendingSeeks += 1
        Task {
            await engine.seek(toSeconds: seconds)
            pendingSeeks -= 1
            await showPosition()
        }
    }
}
