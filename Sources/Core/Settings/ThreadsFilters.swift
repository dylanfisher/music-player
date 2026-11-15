/// A kind of thread the Threads panel's Kinds pull-down shows or hides (ADR 0209), named as
/// music-recommender names it. The `artist` kind isn't one: Other Artists Only says it.
public enum ThreadsKind: String, SettingChoice {
    case credit, related, label, styles

    public var title: String {
        switch self {
        case .credit: "Credits"
        case .related: "Related Artists"
        case .label: "Labels"
        case .styles: "Styles"
        }
    }
}

/// Which albums of the threads the Played pop-up keeps, by the plays the profile sent.
public enum ThreadsPlayed: String, SettingChoice {
    case anyTime
    /// `plays` 0.
    case neverPlayed
    /// Never played, or last played more than a year ago.
    case notInAYear

    public var title: String {
        switch self {
        case .anyTime: "Any Time"
        case .neverPlayed: "Never Played"
        case .notInAYear: "Not in a Year"
        }
    }
}

/// Which albums of the threads the Years pop-up keeps, by their year beside the seed's.
public enum ThreadsYears: String, SettingChoice {
    case anyYear, within5Years, within10Years

    public var title: String {
        switch self {
        case .anyYear: "Any Year"
        case .within5Years: "Within 5 Years"
        case .within10Years: "Within 10 Years"
        }
    }

    /// The most years an album's may be from the seed's; nil for Any Year.
    public var span: Int? {
        switch self {
        case .anyYear: nil
        case .within5Years: 5
        case .within10Years: 10
        }
    }
}
