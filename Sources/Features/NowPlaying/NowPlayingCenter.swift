/// The system's Now Playing, as `MPNowPlayingInfoCenter` has it, so tests can use a fake.
@MainActor
public protocol NowPlayingCenter: AnyObject {
    /// Shows `info`, or clears Now Playing when it's nil.
    func show(_ info: NowPlayingInfo?)
}
