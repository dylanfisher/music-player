import CoreGraphics
import Settings

/// Where the Album Art column draws an album's art, measured from the top-left corner of the
/// album's first row in the column.
enum ArtFrame {
    /// The art in a column `width` points wide, over an album whose rows are `runHeight` points
    /// tall in all. Full width fits the art in a square as wide as the column, and the rows past
    /// the album cut it off. Fit scales that square down to the album's rows. Either way the art
    /// sits at the top, centered across.
    static func rect(_ size: ArtSize, image: CGSize, width: CGFloat, runHeight: CGFloat) -> CGRect {
        let side = size == .fit ? min(width, runHeight) : width
        return centered(image, side: side, width: width)
    }

    /// The whole art in a square as wide as the column, shown over the rows on hover.
    static func whole(image: CGSize, width: CGFloat) -> CGRect {
        centered(image, side: width, width: width)
    }

    private static func centered(_ image: CGSize, side: CGFloat, width: CGFloat) -> CGRect {
        guard image.width > 0, image.height > 0, side > 0 else { return .zero }
        let scale = side / max(image.width, image.height)
        let drawn = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(origin: CGPoint(x: (width - drawn.width) / 2, y: 0), size: drawn)
    }
}
