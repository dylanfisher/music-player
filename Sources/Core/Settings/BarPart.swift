/// A part a `BarLayout` can hold.
public protocol BarPart: SettingChoice, Hashable {
    /// Whether the part is as tall as the bar, as art is, so it can't stack with others.
    var fillsHeight: Bool { get }
    /// The builder's title for a column's stacking.
    static var stackTitle: String { get }
    /// A sentence saying what the bar's center column does.
    static var centerHelp: String { get }
    /// The tallest the bar grows to fit a stack, in points, or nil when only its parts limit it.
    static var stackCapPoints: Double? { get }
}
