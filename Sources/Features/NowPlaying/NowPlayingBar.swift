import AppKit
import Artwork
import Library
import Log
import Playback

private let logger = moduleLogger()

/// The bar across the top of the window: art, title and artist, transport, seek, times and the
/// output format. It reads the engine's updates and sends it the buttons; the model decides what
/// to show.
@MainActor
public final class NowPlayingBar: NSViewController {
    /// How often the position updates while playing. Nothing ticks while paused or stopped.
    static let positionIntervalSeconds = 0.5
    /// The art's size in points.
    public static let artPoints = 48.0

    public let model: NowPlayingModel
    /// Shows or hides the queue panel.
    public var toggleQueue: () -> Void = {}
    private let artwork: ArtworkLoader
    private var engine: PlaybackEngine?
    private var updates: Task<Void, Never>?
    private var timer: Timer?
    private var dragging = false

    private let art = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let formatLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let remainingLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let previousButton = NSButton()
    private let playButton = NSButton()
    private let nextButton = NSButton()
    private let queueButton = NSButton()

    public init(model: NowPlayingModel, artwork: ArtworkLoader) {
        self.model = model
        self.artwork = artwork
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

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

    /// No output could be opened, so nothing can play. Says why in the format line.
    public func showUnavailable(_ reason: String) {
        setEnabled(false)
        formatLabel.stringValue = reason
        formatLabel.textColor = .systemRed
    }

    override public func loadView() {
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 3
        art.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        formatLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        for label in [subtitleLabel, formatLabel, elapsedLabel, remainingLabel] {
            label.textColor = .secondaryLabelColor
        }
        for label in [titleLabel, subtitleLabel, formatLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.alignment = label === elapsedLabel ? .right : .left
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }
        slider.target = self
        slider.action = #selector(seek)
        slider.isContinuous = true
        slider.controlSize = .small
        setUp(previousButton, symbol: "backward.fill", label: "Previous", #selector(previous))
        setUp(playButton, symbol: "play.fill", label: "Play", #selector(playPause))
        setUp(nextButton, symbol: "forward.fill", label: "Next", #selector(next))
        setUp(queueButton, symbol: "list.bullet", label: "Show Queue", #selector(queueClicked))

        let transport = NSStackView(views: [previousButton, playButton, nextButton])
        transport.spacing = 4
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
        let bar = NSStackView(views: [transport, art, middle, queueButton])
        bar.spacing = 10
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        art.translatesAutoresizingMaskIntoConstraints = false
        // A centered stack lets a tall view overflow it; this makes the bar tall enough instead.
        NSLayoutConstraint.activate([
            middle.topAnchor.constraint(greaterThanOrEqualTo: bar.topAnchor, constant: 6),
            middle.bottomAnchor.constraint(lessThanOrEqualTo: bar.bottomAnchor, constant: -6),
            art.widthAnchor.constraint(equalToConstant: Self.artPoints),
            art.heightAnchor.constraint(equalToConstant: Self.artPoints),
        ])
        bar.distribution = .fill
        bar.setClippingResistancePriority(.required, for: .vertical)
        // A stack view's own hugging is its huggingPriority, not its content hugging.
        middle.setHuggingPriority(.init(1), for: .horizontal)
        transport.setHuggingPriority(.required, for: .horizontal)
        slider.setContentHuggingPriority(.init(1), for: .horizontal)
        seek.distribution = .fill
        for view in [art, queueButton] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        view = bar
        setEnabled(false)
        show()
    }

    private func setUp(_ button: NSButton, symbol: String, label: String, _ action: Selector) {
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.target = self
        button.action = action
    }

    private func setEnabled(_ enabled: Bool) {
        for control in [previousButton, playButton, nextButton, slider] as [NSControl] {
            control.isEnabled = enabled
        }
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
        formatLabel.stringValue = model.message ?? model.formatLine
        formatLabel.textColor = model.message == nil ? .secondaryLabelColor : .systemOrange
        formatLabel.toolTip = formatLabel.stringValue
        let playing = model.isPlaying
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: playing ? "Pause" : "Play")
        playButton.toolTip = playing ? "Pause" : "Play"
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
        let times = model.times(positionSeconds: position)
        elapsedLabel.stringValue = times.elapsed
        remainingLabel.stringValue = times.remaining
        guard !dragging else { return }
        if let duration = model.state.durationSeconds, duration > 0, let position {
            slider.doubleValue = position / duration
        } else {
            slider.doubleValue = 0
        }
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

    @objc private func queueClicked() { toggleQueue() }

    @objc private func seek() {
        guard let engine, let duration = model.state.durationSeconds else { return }
        let seconds = slider.doubleValue * duration
        let ended = NSApp.currentEvent?.type == .leftMouseUp
        dragging = !ended
        let times = model.times(positionSeconds: seconds)
        elapsedLabel.stringValue = times.elapsed
        remainingLabel.stringValue = times.remaining
        // Seek once, when the drag ends, rather than on every step of it.
        if ended { Task { await engine.seek(toSeconds: seconds) } }
    }
}
