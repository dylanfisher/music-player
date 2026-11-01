/// One play in the history, as the timeline lists it: small, since the timeline can hold
/// hundreds of thousands; `PlayedTrack` has what it shows.
public struct PlayEntry: Equatable, Sendable {
    /// The history row's ID, which identifies the timeline's row, since a track repeats there.
    public var id: Int64
    /// The played file's permanent ID, which is its track ID while the index holds it.
    public var trackID: Int64
    /// Whole seconds since 1970.
    public var playedSeconds: Int
}

/// A played file, and its track while the index has it.
public struct PlayedTrack: Equatable, Sendable {
    public var path: String
    /// Nil when the file is no longer in the index.
    public var track: TrackRow?

    /// The track's title, or for a file no longer in the index, its file name.
    public var title: String { track?.title ?? displayName(path) }
}
