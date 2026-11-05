import Foundation

/// Where playback stood, for putting it back: the queue, the entry playing or paused in it, how
/// far in, and whether it played. `PlaybackEngine.spot()` reads one and `restore(_:)` puts it
/// back, for Back and Forward over a play (ADR 0089).
public struct PlaybackSpot: Equatable, Sendable {
    public var queue: [URL]
    /// Into `queue`; nil for an empty queue.
    public var index: Int?
    public var seconds: Double
    public var status: PlaybackState.Status

    public init(queue: [URL], index: Int?, seconds: Double, status: PlaybackState.Status) {
        self.queue = queue
        self.index = index
        self.seconds = seconds
        self.status = status
    }
}
