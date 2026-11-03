/// How tall the status bar is: one line at the table header's height, or room for larger art
/// and the track on two lines.
public enum StatusBarStyle: String, SettingChoice {
    case minimal, tall

    public var title: String {
        switch self {
        case .minimal: "Minimal"
        case .tall: "Tall"
        }
    }
}
