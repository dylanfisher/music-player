import Library

extension SmartField {
    /// What the number after the value means, where it isn't plain.
    var unit: String? {
        switch self {
        case .duration: "seconds"
        case .sampleRate, .cutoff: "Hz"
        case .bitDepth, .effectiveBits: "bits"
        case .dynamicRange: "dB"
        case .truePeak: "dBTP"
        case .rating: "stars"
        case .dateAdded, .lastPlayed: "days"
        default: nil
        }
    }
}

extension SmartComparison {
    public var title: String {
        switch self {
        case .contains: "contains"
        case .doesNotContain: "doesn't contain"
        case .is: "is"
        case .isNot: "isn't"
        case .startsWith: "starts with"
        case .endsWith: "ends with"
        case .greaterThan: "is more than"
        case .lessThan: "is less than"
        case .inLast: "is in the last"
        case .notInLast: "isn't in the last"
        }
    }
}

extension SmartOrder {
    public var title: String {
        switch self {
        case .title: "title"
        case .artist: "artist"
        case .album: "album"
        case .recentlyAdded: "most recently added"
        case .recentlyPlayed: "most recently played"
        case .mostPlayed: "most played"
        case .leastPlayed: "least played"
        case .highestRated: "highest rating"
        }
    }
}

extension SmartRules.Match {
    public var title: String {
        switch self {
        case .all: "all"
        case .any: "any"
        }
    }
}
