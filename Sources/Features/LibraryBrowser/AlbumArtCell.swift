import AppKit
import Settings

/// One row's slice of an album's art, which `ArtFrame` places from the top of the album's first
/// row, `rowsDown` rows up. Each row of the album draws its part, so together they show the art
/// once across the rows. The table gives the cell the column's spacing on both sides
/// (`KeyTableView.edgeToEdgeColumn`), so full-width art fills the column edge to edge and no row
/// highlight shows beside it.
final class AlbumArtCell: NSView {
    var art: NSImage? {
        didSet { needsDisplay = true }
    }
    var size = ArtSize.fit {
        didSet { needsDisplay = true }
    }
    /// How many rows below the album's first row this one is.
    var rowsDown = 0 {
        didSet { needsDisplay = true }
    }
    /// How many of the album's rows the art may cover.
    var runRows = 1 {
        didSet { needsDisplay = true }
    }
    /// The distance from one row's top to the next's.
    var rowPitch: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        // The art's size follows the column's width, so a resized column redraws it.
        if newSize.width != frame.width { needsDisplay = true }
        super.setFrameSize(newSize)
    }

    /// Where the art is drawn in this row, in the cell's coordinates.
    var artRect: NSRect {
        guard let art else { return .zero }
        return ArtFrame.rect(
            size, image: art.size, width: bounds.width, runHeight: CGFloat(runRows) * rowPitch
        ).offsetBy(dx: 0, dy: -CGFloat(rowsDown) * rowPitch)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let art else { return }
        art.draw(
            in: artRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}
