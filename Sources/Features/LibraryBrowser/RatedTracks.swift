import Library

/// Tracks the browser rated and the stars they got: by id from the Rating column, the menus and
/// the shortcuts, by path from Get Info and the bars.
public struct RatedTracks: Sendable, Equatable {
    public let stars: Int
    let trackIDs: [Int64]
    let paths: [String]

    /// Whether `track` is one of them.
    public func includes(_ track: TrackRow) -> Bool {
        trackIDs.contains(track.id) || paths.contains(track.path)
    }
}
