/// A part the status bar can show, as the user arranges them in its builder: the playing
/// track's art, its title and artist, its format, a seek bar and its rating, and the list's
/// totals.
public enum StatusPart: String, BarPart {
    case art, track, format, seek, rating, totals

    public var title: String {
        switch self {
        case .art: "Art"
        case .track: "Title and Artist"
        case .format: "Format and Bit Rate"
        case .seek: "Seek Bar"
        case .rating: "Rating"
        case .totals: "Track Totals"
        }
    }

    public var fillsHeight: Bool { self == .art }
    public static let stackTitle = "Stack in Tall Style"
    public static let centerHelp = "The dashed column is centered on the window."
    public static let stackCapPoints: Double? = StatusBarStyle.tallMaxPoints
}

extension BarLayout where Part == StatusPart {
    /// The totals alone, centered on the window across the free width.
    public static let defaultStatusBar = BarLayout(
        center: BarColumn(parts: [.totals], width: .flexible, alignment: .center))
}
