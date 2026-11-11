import CoreGraphics

/// The rating a click on a row of stars sets: the star under the pointer, counted from the
/// text's left edge, where the stars draw. Left of the first star, or on the last star of the
/// rating the track has, clears it, since an unrated track's stars don't show to click.
public enum RatingClick {
    /// `x` is from the left of the cell's text, `starWidth` one star's in the cell's font.
    /// `current` is nil for tracks rated differently, which a click on a star never clears.
    public static func stars(at x: CGFloat, starWidth: CGFloat, current: Int?) -> Int {
        let star = hovered(at: x, starWidth: starWidth)
        return star == current ? 0 : star
    }

    /// The stars a pointer at `x` fills, up to the one under it; 0 left of the first.
    public static func hovered(at x: CGFloat, starWidth: CGFloat) -> Int {
        guard x >= 0, starWidth > 0 else { return 0 }
        return min(SmartField.maxRating, Int(x / starWidth) + 1)
    }
}
