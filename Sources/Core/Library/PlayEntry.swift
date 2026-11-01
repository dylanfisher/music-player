/// One play in the history, as the timeline lists it.
public struct PlayEntry: Equatable, Sendable {
    /// The history row's ID, which identifies the timeline's row, since a track repeats there.
    public var id: Int64
    /// The played file's permanent ID, which is its track ID while the index holds it.
    public var trackID: Int64
    public var path: String
    /// Whole seconds since 1970.
    public var playedSeconds: Int
    /// Nil when the file is no longer in the index.
    public var track: TrackRow?

    public init(id: Int64, trackID: Int64, path: String, playedSeconds: Int, track: TrackRow? = nil)
    {
        self.id = id
        self.trackID = trackID
        self.path = path
        self.playedSeconds = playedSeconds
        self.track = track
    }
}
