/// A track of the list the window shows, with what the status bar adds up for it.
public struct ListedTrack: Equatable, Sendable {
    public var id: Int64
    public var sizeBytes: Int
    public var durationSeconds: Double
}
