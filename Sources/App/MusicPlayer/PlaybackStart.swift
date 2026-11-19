import Foundation
import HALOutput
import Log
import Playback
import Settings

private let logger = moduleLogger()

/// The device output and the engine, made at launch, and what follows their streams.
extension AppDelegate {
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
                    self?.remote.queue.note(update.state, at: Date().timeIntervalSince1970)
                    self?.browser?.showPlaying(path: self?.currentTrackPath)
                    self?.playTracker?.handle(update)
                    if case .trackStarted(let index) = update.event {
                        self?.countPlay(update.state.queue[index].path)
                    }
                    switch update.event {
                    case .trackStarted, .paused, .stopped, .seeked, .finished:
                        self?.resumeSaver?.changed()
                    default: break
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

    /// Tells the watcher, so network rescans stay off the NAS while a track starts.
    func playbackChanged(_ state: PlaybackState) {
        let now = watcherActivity(state)
        guard now != activity, let settings else { return }
        activity = now
        watcher?.playbackChanged(
            now, pausePollingDuringPlayback: settings[\.pausePollingDuringPlayback])
    }
}
