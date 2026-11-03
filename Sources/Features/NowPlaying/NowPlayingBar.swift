import AppKit
import Artwork
import Commands
import Library
import Log
import Playback
import Settings

private let logger = moduleLogger()

/// The toolbar's playback items: the transport buttons, and the now-playing status with the
/// current track, its times, a seek bar and the output format, in two styles, each a toolbar
/// item of its own. It reads the engine's updates and sends it the buttons; the model decides
/// what to show.
@MainActor
public final class NowPlayingBar: NSObject {
    /// How often the position updates while playing. Nothing ticks while paused or stopped.
    static let positionIntervalSeconds = 0.5
    /// The art's size in points.
    public static let artPoints = 48.0
    /// The height of the centered style's capsule, in points.
    static let capsulePoints = 18.0

    public let model: NowPlayingModel
    /// The previous, play and next buttons.
    public let transport: NSView
    /// Art, title, artist and album, the format line, and a seek bar with times.
    public let status = NSView()
    /// "Title by Artist from Album" centered in bold, over a capsule with the elapsed time, a
    /// thin progress bar and the total time, as Swinsian's header draws it.
    public let centeredStatus = NSView()
    private let artwork: ArtworkLoader
    private var engine: PlaybackEngine?
    private var updates: Task<Void, Never>?
    private var timer: Timer?
    /// Seeks sent to the engine and not yet done, while which the bars keep the target.
    private var pendingSeeks = 0

    private let art = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let formatLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let remainingLabel = NSTextField(labelWithString: "")
    private let slider = SeekBar()
    private let previousButton = NSButton()
    private let playButton = NSButton()
    private let nextButton = NSButton()
    private let detailed = NSStackView()
    private let centered = NSStackView()
    private let bylineLabel = NSTextField(labelWithString: "")
    private let centeredElapsedLabel = NSTextField(labelWithString: "")
    private let totalLabel = NSTextField(labelWithString: "")
    private let progress = SeekBar()

    public init(model: NowPlayingModel, artwork: ArtworkLoader) {
        self.model = model
        self.artwork = artwork
        let transport = NSStackView(views: [previousButton, playButton, nextButton])
        transport.spacing = 4
        self.transport = transport
        super.init()
        setUp(previousButton, symbol: "backward.fill", label: "Previous", #selector(previous))
        setUp(
            playButton, symbol: "play.fill", label: AppCommands.title(of: .play),
            #selector(playPause))
        setUp(nextButton, symbol: "forward.fill", label: "Next", #selector(next))
        for label in [elapsedLabel, remainingLabel, centeredElapsedLabel, totalLabel] {
            label.font = .monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = [elapsedLabel, centeredElapsedLabel].contains(label) ? .right : .left
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }
        for bar in [slider, progress] {
            bar.seek = { [weak self] fraction, done in self?.seek(to: fraction, done: done) }
        }
        buildDetailed()
        buildCentered()
        for (layout, item) in [(detailed, status), (centered, centeredStatus)] {
            layout.translatesAutoresizingMaskIntoConstraints = false
            item.addSubview(layout)
            NSLayoutConstraint.activate([
                layout.leadingAnchor.constraint(equalTo: item.leadingAnchor),
                layout.trailingAnchor.constraint(equalTo: item.trailingAnchor),
                layout.centerYAnchor.constraint(equalTo: item.centerYAnchor),
            ])
        }
        detailed.heightAnchor.constraint(equalTo: status.heightAnchor).isActive = true
        // As tall as the art, the detailed layout's tallest view, so the toolbar keeps its
        // height whichever style it holds.
        centeredStatus.heightAnchor.constraint(equalToConstant: Self.artPoints).isActive = true
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

    /// The byline centered in bold, over a capsule with the elapsed time, a thin bar and the
    /// total time. No art.
    private func buildCentered() {
        bylineLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        bylineLabel.alignment = .center
        bylineLabel.lineBreakMode = .byTruncatingTail
        bylineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let times = NSStackView(views: [centeredElapsedLabel, progress, totalLabel])
        times.spacing = 6
        times.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        let capsule = NSBox()
        capsule.boxType = .custom
        capsule.borderWidth = 0
        capsule.fillColor = .quaternaryLabelColor
        capsule.cornerRadius = Self.capsulePoints / 2
        capsule.contentViewMargins = .zero
        capsule.contentView = times
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.heightAnchor.constraint(equalToConstant: Self.capsulePoints).isActive = true
        centered.setViews([bylineLabel, capsule], in: .center)
        centered.orientation = .vertical
        centered.alignment = .centerX
        centered.spacing = 3
        for view in [bylineLabel, capsule] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: centered.widthAnchor).isActive = true
        }
    }

    private func setUp(_ button: NSButton, symbol: String, label: String, _ action: Selector) {
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.target = self
        button.action = action
    }

    private func setEnabled(_ enabled: Bool) {
        for control in [previousButton, playButton, nextButton] { control.isEnabled = enabled }
        for bar in [slider, progress] { bar.isEnabled = enabled }
    }

    private func apply(_ update: PlaybackUpdate) {
        let before = model.currentURL
        model.apply(update)
        if model.currentURL != before { loadArt() }
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
        bylineLabel.stringValue = model.byline
        bylineLabel.toolTip = model.byline
        totalLabel.stringValue = model.totalTime
        formatLabel.stringValue = model.message ?? model.formatLine
        formatLabel.textColor = model.message == nil ? .secondaryLabelColor : .systemOrange
        formatLabel.toolTip = formatLabel.stringValue
        let playing = model.isPlaying
        let title = AppCommands.title(of: playing ? .pause : .play)
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: title)
        playButton.toolTip = title
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
        showTimes(model.times(positionSeconds: position))
        guard pendingSeeks == 0, !slider.isTracking, !progress.isTracking else { return }
        let fraction =
            if let duration = model.state.durationSeconds, duration > 0, let position {
                position / duration
            } else {
                0.0
            }
        slider.fraction = fraction
        progress.fraction = fraction
    }

    private func showTimes(_ times: (elapsed: String, remaining: String)) {
        elapsedLabel.stringValue = times.elapsed
        remainingLabel.stringValue = times.remaining
        centeredElapsedLabel.stringValue = times.elapsed
    }

    private func loadArt() {
        art.image = nil
        art.toolTip = nil
        guard let track = model.track, let embedded = track.art else { return }
        let key = ArtworkKey(path: track.path, offset: embedded.offset)
        if let image = artwork.cached(key) {
            art.image = NSImage(cgImage: image, size: .zero)
            return
        }
        let artwork = artwork
        let url = model.currentURL
        Task {
            let result = await Task.detached {
                Result { try artwork.image(embedded, path: track.path) }
            }
            .value
            guard self.model.currentURL == url else { return }
            switch result {
            case .success(let image): self.art.image = NSImage(cgImage: image, size: .zero)
            case .failure(let error):
                logger.error("\(error)")
                self.art.toolTip = "\(error)"
            }
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
        guard let engine, let duration = model.state.durationSeconds else { return }
        let seconds = fraction * duration
        slider.fraction = fraction
        progress.fraction = fraction
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
