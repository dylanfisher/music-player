/// Why a `BarLayout` can't be laid out, naming the column.
public enum BarLayoutProblem: Equatable, Sendable, CustomStringConvertible {
    /// How many a setting's error lists before "N more".
    static let shownCount = 3

    /// A part listed a second time, at the place of the second; each part is one view.
    case repeatedPart(String, BarPlace)
    case widthOutOfRange(BarPlace, points: Int)
    /// A part as tall as the bar, such as the art, in a column that stacks.
    case stackedPartFillsHeight(String, BarPlace)

    public var description: String {
        switch self {
        case .repeatedPart(let part, let place): "\(part) is listed again in \(place)"
        case .widthOutOfRange(let place, let points):
            "\(place) is \(points) points wide; a fixed width is"
                + " \(BarWidth.fixedRangePoints.lowerBound)...\(BarWidth.fixedRangePoints.upperBound)"
        case .stackedPartFillsHeight(let part, let place):
            "\(part) fills the bar's height, so \(place) can't stack it"
        }
    }
}
