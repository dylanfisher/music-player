/// A Rating submenu item's mark: on for the rating every track it acts on has, mixed for each
/// of several ratings they have between them, Clear Rating's being unrated.
public enum RatingMark: Equatable, Sendable {
    case off, on, mixed

    /// The mark of the item for `stars`, 0 for Clear Rating, over tracks with `ratings`.
    init(stars: Int, ratings: Set<Int>) {
        self = !ratings.contains(stars) ? .off : ratings.count == 1 ? .on : .mixed
    }
}
