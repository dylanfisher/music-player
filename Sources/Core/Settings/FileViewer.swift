/// The app Reveal in Finder shows files in.
public enum FileViewer: String, SettingChoice {
    case searcher, finder

    public var title: String {
        switch self {
        case .searcher: "Searcher"
        case .finder: "Finder"
        }
    }

    /// The app's bundle ID, from its `Info.plist` (ADR 0051).
    public var bundleID: String {
        switch self {
        case .searcher: "com.dylanfisher.searcher"
        case .finder: "com.apple.finder"
        }
    }
}
