/// The order Upgrade to FLAC Automatically queues candidates in (ADR 0200).
extension UpgradeCandidate {
    /// The average rating, in stars, of an album's rated tracks that boosts it.
    static let boostStars = 4
    /// The bit rate a play counts once at; lower ones count more, higher ones less.
    static let referenceKbps = 320.0
    /// The lowest bit rate the score reads, so a file with no length doesn't score without
    /// bound.
    static let floorKbps = 32
    /// What a liked or highly rated album's score is multiplied by.
    static let boost = 2.0

    /// (plays + 1) × 320 / kbps, doubled when `boosted`: the most-played, lowest-quality
    /// albums first. The + 1 keeps an album never played in order of its quality.
    package var priority: Double {
        Double(plays + 1) * Self.referenceKbps / Double(max(kbps, Self.floorKbps))
            * (boosted ? Self.boost : 1)
    }

    /// Whether `self` is queued before `other`: the higher score, then the lower album id.
    package func precedes(_ other: UpgradeCandidate) -> Bool {
        priority != other.priority ? priority > other.priority : albumID < other.albumID
    }
}
