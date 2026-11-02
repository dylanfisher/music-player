import AppKit

/// A table row that stands out from its neighbors whether or not it's selected, as the row of
/// the track playing does: a faint tint of the accent color across it, and a bar at its leading
/// edge that still shows over the selection, in the selection's text color.
public final class MarkedRowView: NSTableRowView {
    /// The bar's width in points: enough to see, narrow enough to stay clear of the first
    /// column's text.
    static let barWidth: CGFloat = 3

    public var isMarked = false {
        didSet { if isMarked != oldValue { needsDisplay = true } }
    }

    override public func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isMarked else { return }
        // Faint enough that the alternating rows and the text read through it, in light and
        // dark mode alike.
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        bounds.fill(using: .sourceOver)
        drawBar(.controlAccentColor)
    }

    override public func drawSelection(in dirtyRect: NSRect) {
        super.drawSelection(in: dirtyRect)
        guard isMarked else { return }
        // The selection is the accent color while the table has the keys, so the bar takes
        // the selected text's color then.
        drawBar(isEmphasized ? .alternateSelectedControlTextColor : .controlAccentColor)
    }

    private func drawBar(_ color: NSColor) {
        color.setFill()
        var bar = bounds
        bar.size.width = Self.barWidth
        bar.fill()
    }
}
