/// How tall the status bar is: one line at the table header's height, or room for larger art
/// and the track on two lines.
public enum StatusBarStyle: String, SettingChoice {
    case minimal, tall

    /// The tall style's height, in points: two lines of text and art beside them.
    public static let tallPoints = 44.0
    /// The tallest the tall style grows to fit a stacked column, in points: three lines of
    /// text with the seek bar under them, so the bar never takes a list's rows. Anything taller
    /// is clipped.
    public static let tallMaxPoints = 80.0

    public var title: String {
        switch self {
        case .minimal: "Minimal"
        case .tall: "Tall"
        }
    }
}
