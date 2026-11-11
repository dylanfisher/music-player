import AppKit

extension NSFont {
    /// One star's width in this font, as `stars` draws a rating: the unit a click or a hover
    /// over a row of stars is counted in.
    public var starWidth: CGFloat {
        (stars(1) as NSString).size(withAttributes: [.font: self]).width
    }
}
