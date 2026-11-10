/// How many tracks, how many bytes, how long they play and how many albums they're on, as the
/// status bar counts them.
public struct TrackTotals: Equatable, Sendable {
    public var count: Int
    public var sizeBytes: Int
    public var durationSeconds: Double
    /// The albums the tracks are on, each counted once; a track with no album adds none.
    public var albumCount: Int

    public init(
        count: Int = 0, sizeBytes: Int = 0, durationSeconds: Double = 0, albumCount: Int = 0
    ) {
        self.count = count
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.albumCount = albumCount
    }
}

/// A track's file size, length and album, as `TrackTotals` adds them. The album is numbered
/// from 0 among the albums read with it, so the albums a list holds are counted in an array
/// rather than a set; -1 for none.
struct TrackSize {
    var bytes: Int
    var seconds: Double
    var album: Int32
}
