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
    /// How often the position updates while playing. Nothing ticks while paused or stopped.
    static let positionIntervalSeconds = 0.5
    /// The art's size in points.
    public static let artPoints = 48.0

    public let model: NowPlayingModel
    /// The previous, play and next buttons.
    public let transport: NSView
    /// Art, title, artist and album, the format line, and a seek bar with times.
    public let status = NSView()
    /// The status bar's art, track, format and seek bar.
    public let statusBar = StatusBarParts()
    private let artwork: ArtworkLoader
    private var engine: PlaybackEngine?
    private var updates: Task<Void, Never>?
    private var timer: Timer?
    /// Seeks sent to the engine and not yet done, while which the bars keep the target.
    private var pendingSeeks = 0
    /// Whether the engine is connected and an output opened.
    private var connected = false

    private let art = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let formatLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let remainingLabel = NSTextField(labelWithString: "")
    let slider = SeekBar()
    private let previousButton = NSButton()
    private let playButton = NSButton()
    private let nextButton = NSButton()
    private let detailed = NSStackView()

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
        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = label == elapsedLabel ? .right : .left
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }
        for bar in [slider, statusBar.seekBar] {
            bar.seek = { [weak self] fraction, done in self?.seek(to: fraction, done: done) }
        }
        buildDetailed()
        detailed.translatesAutoresizingMaskIntoConstraints = false
        status.addSubview(detailed)
        NSLayoutConstraint.activate([
            detailed.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            detailed.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            detailed.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            detailed.heightAnchor.constraint(equalTo: status.heightAnchor),
        ])
        setEnabled(false)
        show()
    }

    /// Follows `engine` from now on.
    public func connect(_ engine: PlaybackEngine) {
        self.engine = engine
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
        formatLabel.stringValue = reason
        formatLabel.textColor = .systemRed
        statusBar.show(format: reason, color: .systemRed)
    }

    /// Art, then the title, the artist and album, and the format line over the seek bar.
    private func buildDetailed() {
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 3
        art.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        formatLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        for label in [subtitleLabel, formatLabel] {
            label.textColor = .secondaryLabelColor
        }
        for label in [titleLabel, subtitleLabel, formatLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [titleLabel, subtitleLabel, formatLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let seek = NSStackView(views: [elapsedLabel, slider, remainingLabel])
        seek.spacing = 4
        let middle = NSStackView(views: [text, seek])
        middle.orientation = .vertical
        middle.alignment = .leading
        middle.spacing = 2
        for view in [text, seek] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: middle.widthAnchor).isActive = true
        }
        detailed.setViews([art, middle], in: .leading)
        detailed.spacing = 10
        detailed.alignment = .centerY
        art.translatesAutoresizingMaskIntoConstraints = false
        // A centered stack lets a tall view overflow it; this makes it tall enough instead.
        NSLayoutConstraint.activate([
            middle.topAnchor.constraint(greaterThanOrEqualTo: detailed.topAnchor),
            middle.bottomAnchor.constraint(lessThanOrEqualTo: detailed.bottomAnchor),
            art.widthAnchor.constraint(equalToConstant: Self.artPoints),
            art.heightAnchor.constraint(equalToConstant: Self.artPoints),
        ])
        detailed.distribution = .fill
        detailed.setClippingResistancePriority(.required, for: .vertical)
        // A stack view's own hugging is its huggingPriority, not its content hugging.
        middle.setHuggingPriority(.init(1), for: .horizontal)
        seek.distribution = .fill
        art.setContentHuggingPriority(.required, for: .horizontal)
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
        for bar in [slider, statusBar.seekBar] { bar.isEnabled = seekable }
    }

    func apply(_ update: PlaybackUpdate) {
        let before = model.currentURL
        model.apply(update)
        if model.currentURL != before {
            loadArt()
            // A drag over the last track mustn't seek this one.
            for bar in [slider, statusBar.seekBar] { bar.cancelTracking() }
        }
        show()
        if model.isPlaying {
            startTimer()
        } else {
            timer?.invalidate()
            timer = nil
            Task { await showPosition() }
        }
    }

    private func show() {
        titleLabel.stringValue = model.title
        subtitleLabel.stringValue = model.subtitle
        formatLabel.stringValue = model.message ?? model.formatLine
        formatLabel.textColor = model.message == nil ? .secondaryLabelColor : .systemOrange
        formatLabel.toolTip = formatLabel.stringValue
        statusBar.show(title: model.title, subtitle: model.subtitle)
        statusBar.show(format: formatLabel.stringValue, color: formatLabel.textColor ?? .labelColor)
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
        guard pendingSeeks == 0, !slider.isTracking, !statusBar.seekBar.isTracking else { return }
        showTimes(model.times(positionSeconds: position))
        let fraction =
            if let duration = model.state.durationSeconds, duration > 0, let position {
                position / duration
            } else {
                0.0
            }
        slider.fraction = fraction
        statusBar.seekBar.fraction = fraction
    }

    private func showTimes(_ times: (elapsed: String, remaining: String)) {
        elapsedLabel.stringValue = times.elapsed
        remainingLabel.stringValue = times.remaining
        statusBar.showTimes(elapsed: times.elapsed, remaining: times.remaining)
    }

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
        for view in [art, statusBar.art] {
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
            for bar in [slider, statusBar.seekBar] { bar.fraction = 0 }
            return
        }
        let seconds = fraction * duration
        slider.fraction = fraction
        statusBar.seekBar.fraction = fraction
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
