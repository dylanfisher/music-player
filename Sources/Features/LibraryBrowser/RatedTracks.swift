import Library

/// Tracks the browser rated and the stars they got, from the Rating column, the menus, the
/// shortcuts, Get Info and the bars.
public struct RatedTracks: Sendable, Equatable {
    public let stars: Int
    let trackIDs: [Int64]

    /// Whether `track` is one of them.
    public func includes(_ track: TrackRow) -> Bool {
        trackIDs.contains(track.id)
    }
}
