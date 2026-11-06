import Foundation

/// Everything a UI, media keys or a remote shows about playback.
public struct PlaybackState: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case stopped, playing, paused
    }

    public enum Device: Sendable, Equatable {
        case connected
        /// Unplugged or gone. Playback paused instead of moving to another device.
        case lost
        /// Back after being lost, so playback can resume where it paused.
        case returned
    }

    public var status = Status.stopped
    public var queue: [URL] = []
    /// Indices into `queue` in the order they play: the queue as listed, or shuffled.
    public var order: [Int] = []
    /// Into `queue`: the track playing or paused, or the one `play()` starts.
    public var currentIndex: Int?
    public var repeatMode = RepeatMode.off
    public var shuffle = false
    /// Once the current track has started.
    public var durationSeconds: Double?
    public var outputFormat: String?
    public var device = Device.connected

    public init() {}
}

/// One change to `PlaybackState`, and what caused it.
public struct PlaybackUpdate: Sendable {
    public var state: PlaybackState
    /// Nil for the first update a subscriber gets, which is the state at the time.
    public var event: PlaybackEvent?
    /// Seconds into the current track when this was published, as `position()` had it then,
    /// so it can't belong to a later state.
    public var positionSeconds: Double? = nil
}

public enum PlaybackEvent: Sendable, Equatable {
    case queueChanged
    /// The track at this index into the queue began playing.
    case trackStarted(index: Int)
    case trackEnded(index: Int)
    case resumed
    case paused
    case stopped
    /// The current track moved to this many seconds in. The output may not have caught up yet,
    /// so this is where it will be, not where it is.
    case seeked(seconds: Double)
    case repeatChanged
    case shuffleChanged
    case formatChanged(FormatChange)
    /// The track was skipped because it couldn't be played.
    /// `entry` is the track's index into the queue.
    case trackFailed(URL, entry: Int, PlaybackProblem)
    case underrun(frames: Int)
    case deviceLost
    case deviceReturned
    /// The output stopped because of an error.
    case failed(PlaybackProblem)
    /// The queue played to its end.
    case finished
}
