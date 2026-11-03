import Artwork
import Commands
import CoreGraphics
import Foundation
import Log
import Playback

private let logger = moduleLogger()

/// Media keys, headphone buttons and Now Playing in Control Center, from the engine's updates.
/// The remote commands run the registry's commands through the dispatcher, so they do what the
/// menus do.
///
/// Nothing ticks. The system works out the elapsed time from the last value and the rate, so the
/// info is set again only when playback starts, pauses, resumes, seeks or stops, or what it
/// shows changes. Each of those takes the position the update carries, from the output, whose
/// clock is the DAC's, so
/// the system's count can't drift from it for longer than one stretch of uninterrupted playing.
@MainActor
public final class MediaControls {
    /// The art's longest side in pixels: Control Center's largest view of it on a Retina display,
    /// with room to spare.
    public static let artPixels = 512
    /// How far before the end a scrub may go: at the very end nothing is left to play, and the
    /// track would end before Now Playing showed the time.
    static let endMarginSeconds = 0.1

    public let model: NowPlayingModel
    private let dispatcher: CommandDispatcher
    private let remote: any RemoteCommandCenter
    private let center: any NowPlayingCenter
    private let artwork: ArtworkLoader
    private let seek: (Double) -> Void
    private let clock: () -> Double
    private var enabled: Set<RemoteCommand> = []
    private var shown: NowPlayingInfo?
    /// The clock's reading when `shown` was set.
    private var shownAt = 0.0
    /// The current track's art, once it's decoded.
    private var art: CGImage?
    private var artLoad: Task<Void, Never>?
    private var updates: Task<Void, Never>?

    /// `seek` moves the current track to a time in seconds. `clock` is in seconds and only ever
    /// goes forward.
    public init(
        model: NowPlayingModel, dispatcher: CommandDispatcher, remote: any RemoteCommandCenter,
        center: any NowPlayingCenter, artwork: ArtworkLoader,
        seek: @escaping (Double) -> Void,
        clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.model = model
        self.dispatcher = dispatcher
        self.remote = remote
        self.center = center
        self.artwork = artwork
        self.seek = seek
        self.clock = clock
        remote.setEnabled([])
        remote.start { [weak self] action in self?.handle(action) ?? false }
    }

    /// Follows `engine` from now on.
    public func connect(_ engine: PlaybackEngine) {
        updates?.cancel()
        refreshCommands()
        updates = Task { [weak self] in
            for await update in await engine.updates() {
                self?.apply(update)
            }
        }
    }

    /// Offers the system the commands that can run now. Every update calls this; call it too
    /// when the dispatcher's checks change without one, such as the engine going away.
    public func refreshCommands() {
        let now = Set(
            RemoteCommand.allCases.filter {
                $0.isEnabled(model.state, commandIsEnabled: dispatcher.isEnabled)
            })
        guard now != enabled else { return }
        enabled = now
        remote.setEnabled(now)
    }

    /// A rescan may have changed the current track's tags or art.
    public func libraryChanged() {
        model.libraryChanged()
        loadArt()
        show(elapsedSeconds: nil)
    }

    func apply(_ update: PlaybackUpdate) {
        let before = model.currentURL
        model.apply(update)
        if model.currentURL != before { loadArt() }
        refreshCommands()
        let positionSeconds = update.positionSeconds
        switch update.event {
        case .seeked(let seconds): show(elapsedSeconds: seconds)
        // The output may not report the new track's position yet.
        case .trackStarted: show(elapsedSeconds: positionSeconds ?? 0)
        case nil, .resumed, .paused, .deviceLost, .deviceReturned:
            show(elapsedSeconds: positionSeconds)
        default: show(elapsedSeconds: nil)
        }
    }

    /// Runs what the system sent; false when it's off now. Checked again here rather than
    /// trusting what was last offered, which can be out of date.
    func handle(_ action: RemoteAction) -> Bool {
        guard action.command.isEnabled(model.state, commandIsEnabled: dispatcher.isEnabled)
        else { return false }
        guard let id = action.command.commandID else { return seek(toSeconds: action.seconds) }
        return dispatcher.run(id)
    }

    /// True once the seek is sent; the engine doesn't confirm it, and an update follows.
    private func seek(toSeconds seconds: Double?) -> Bool {
        guard let seconds, seconds.isFinite, let duration = model.state.durationSeconds,
            duration.isFinite
        else { return false }
        seek(min(max(0, seconds), max(0, duration - Self.endMarginSeconds)))
        return true
    }

    /// Sets Now Playing from the model. With `elapsedSeconds` nil, the time goes on from the
    /// last one shown, and nothing is set unless something else changed.
    private func show(elapsedSeconds: Double?) {
        guard model.state.status != .stopped, model.currentURL != nil else {
            if shown != nil { center.show(nil) }
            shown = nil
            return
        }
        let now = clock()
        let duration = model.state.durationSeconds ?? model.track?.durationSeconds
        let elapsed =
            elapsedSeconds ?? shown.map { $0.elapsedSeconds + $0.rate * (now - shownAt) } ?? 0
        let info = NowPlayingInfo(
            title: model.title, artist: model.track?.artist, album: model.track?.album,
            durationSeconds: duration,
            elapsedSeconds: min(max(0, elapsed), duration ?? .infinity),
            isPlaying: model.isPlaying, art: art)
        if elapsedSeconds == nil, let shown, info.sameApartFromTime(as: shown) { return }
        center.show(info)
        shown = info
        shownAt = now
    }

    /// Reads the current track's art off the main thread, then shows it.
    private func loadArt() {
        art = nil
        artLoad?.cancel()
        guard let track = model.track, let embedded = track.art else { return }
        if let image = artwork.cached(ArtworkKey(path: track.path, art: embedded)) {
            art = image
            return
        }
        let artwork = artwork
        let url = model.currentURL
        artLoad = Task {
            let result = await artwork.load(embedded, path: track.path)
            guard !Task.isCancelled, model.currentURL == url else { return }
            switch result {
            case .success(let image):
                art = image
                show(elapsedSeconds: nil)
            case .failure(let error): logger.error("\(error)")
            }
        }
    }
}
