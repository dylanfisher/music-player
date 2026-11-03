import CoreGraphics
import Library

/// The rating a click in the Rating column sets: the star under the pointer, counted from the
/// text's left edge, where the stars draw. Left of the first star, or on the last star of the
/// rating the track has, clears it, since an unrated track's stars don't show to click.
enum RatingClick {
    /// `x` is from the left of the cell's text, `starWidth` one star's in the cell's font.
    static func stars(at x: CGFloat, starWidth: CGFloat, current: Int) -> Int {
        guard x >= 0, starWidth > 0 else { return 0 }
        let star = min(SmartField.maxRating, Int(x / starWidth) + 1)
        return star == current ? 0 : star
    }
}
