/// How the status bar shows the downloads on their way to the staging folder: the number of
/// albums, a line of words, or a progress bar with the number.
public enum DownloadsStatusStyle: String, SettingChoice {
    case count, label, progress

    public var title: String {
        switch self {
        case .count: "Count"
        case .label: "Label"
        case .progress: "Progress Bar"
        }
    }
}
