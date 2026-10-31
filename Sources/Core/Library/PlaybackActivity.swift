/// What playback is doing, as the engine reports it to `LibraryWatcher.playbackChanged`, so
/// network rescans stay out of its way.
public enum PlaybackActivity: Sendable {
    case stopped
    /// Opening a file and configuring the device: no network rescan starts or runs, since a
    /// NAS busy with a scan makes the first read slow.
    case starting
    /// Network rescans run unless `library.pausePollingDuringPlayback` is on.
    case playing
}
