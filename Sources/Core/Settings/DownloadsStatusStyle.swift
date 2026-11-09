/// How the status bar shows the downloads on their way to the staging folder: the number of
/// albums, a line of text, or a progress bar with the number.
public enum DownloadsStatusStyle: String, SettingChoice {
    case count, text, progress

    public var title: String {
        switch self {
        case .count: "Count"
        case .text: "Text"
        case .progress: "Progress Bar"
        }
    }
}
