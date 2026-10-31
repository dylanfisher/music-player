import Library
import Playback

/// What the engine's state means for the library watcher's network polls. Between a load and the
/// track's first sample the engine is playing with no duration yet, which is the start the
/// watcher keeps the NAS clear for. Paused counts as stopped: nothing is reading the NAS.
func watcherActivity(_ state: PlaybackState) -> PlaybackActivity {
    switch state.status {
    case .playing: state.durationSeconds == nil ? .starting : .playing
    case .paused, .stopped: .stopped
    }
}
