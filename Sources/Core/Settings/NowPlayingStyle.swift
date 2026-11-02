/// How the toolbar's now-playing status draws the current track.
public enum NowPlayingStyle: String, SettingChoice {
    /// Art, title, artist and album, the format line, and a seek bar with times.
    case detailed
    /// "Title by Artist from Album" centered in bold, over a capsule with the elapsed time, a
    /// thin progress bar and the total time, as Swinsian's header draws it.
    case centered

    public var title: String {
        switch self {
        case .detailed: "Detailed"
        case .centered: "Centered"
        }
    }
}
