import AppKit

/// One row's slice of full-width album art: the art fills a square as wide as the column less
/// an inset each side, whose top sits at the top of the album's first row, `rowsDown` rows up.
/// Each row of the album draws its part, so together they show the art once across the rows.
final class AlbumArtCell: NSView {
    /// The space between the art and the column's edges, and above the album's first row.
    static let inset: CGFloat = 2

    var art: NSImage? {
        didSet { needsDisplay = true }
    }
    /// How many rows below the album's first row this one is.
    var rowsDown = 0 {
        didSet { needsDisplay = true }
    }
    /// The distance from one row's top to the next's.
    var rowPitch: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    /// The art's side in a column `width` points wide.
    static func side(width: CGFloat) -> CGFloat { max(0, width - 2 * inset) }

    override func setFrameSize(_ newSize: NSSize) {
        // The art's size follows the column's width, so a resized column redraws it.
        if newSize.width != frame.width { needsDisplay = true }
        super.setFrameSize(newSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let art, art.size.width > 0, art.size.height > 0 else { return }
        // Art that isn't square fits inside the square, centered across and at its top.
        let side = Self.side(width: bounds.width)
        let scale = side / max(art.size.width, art.size.height)
        let size = NSSize(width: art.size.width * scale, height: art.size.height * scale)
        let rect = NSRect(
            origin: NSPoint(
                x: Self.inset + (side - size.width) / 2,
                y: Self.inset - CGFloat(rowsDown) * rowPitch),
            size: size)
        art.draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}
