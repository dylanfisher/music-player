/// A part a `BarLayout` can hold.
public protocol BarPart: SettingChoice, Hashable {
    /// Whether the part is as tall as the bar, as art is, so it can't stack with others.
    var fillsHeight: Bool { get }
}
