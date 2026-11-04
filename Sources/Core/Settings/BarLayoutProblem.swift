/// Why a `BarLayout` can't be laid out, naming the column.
public enum BarLayoutProblem: Equatable, Sendable, CustomStringConvertible {
    /// How many a setting's error lists before "N more".
    static let shownCount = 3

    /// A part, by its title, listed a second time, at the place of the second; each part is
    /// one view.
    case repeatedPart(String, BarPlace)
    case widthOutOfRange(BarPlace, points: Int)
    /// A part as tall as the bar, such as the art, by its title, in a column that stacks it
    /// with others.
    case stackedPartFillsHeight(String, BarPlace)

    /// A sentence without its capital and full stop, so the config banner can follow the key
    /// with it.
    public var description: String {
        switch self {
        case .repeatedPart(let part, let place):
            "\(part) is in the bar twice, the second time in \(place)"
        case .widthOutOfRange(let place, let points):
            "\(place) is \(points) points wide, but a fixed width is"
                + " \(BarWidth.fixedRangePoints.lowerBound) to"
                + " \(BarWidth.fixedRangePoints.upperBound) points"
        case .stackedPartFillsHeight(let part, let place):
            "\(part) is as tall as the bar, so it can't stack with other parts in \(place)"
        }
    }
}
