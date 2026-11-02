/// How many tracks, how many bytes and how long they play, as the status bar counts them.
public struct TrackTotals: Equatable, Sendable {
    public var count: Int
    public var sizeBytes: Int
    public var durationSeconds: Double

    public init(count: Int = 0, sizeBytes: Int = 0, durationSeconds: Double = 0) {
        self.count = count
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
    }
}

/// A track's file size and length, as `TrackTotals` adds them.
struct TrackSize {
    var bytes: Int
    var seconds: Double
}
