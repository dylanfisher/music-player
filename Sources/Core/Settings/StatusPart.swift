/// A part the status bar can show, as the user arranges them in Settings ▸ Appearance: the
/// playing track's art, its title and artist, its format, a seek bar, and the list's totals.
public enum StatusPart: String, SettingChoice {
    case art, track, format, seek, totals

    public var title: String {
        switch self {
        case .art: "Art"
        case .track: "Title and Artist"
        case .format: "Format and Bit Rate"
        case .seek: "Seek Bar"
        case .totals: "Track Totals"
        }
    }
}
