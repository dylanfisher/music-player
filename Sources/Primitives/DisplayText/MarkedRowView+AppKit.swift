import AppKit

/// A table row that stands out from its neighbors whether or not it's selected, as the row of
/// the track playing does: a faint tint of the accent color across it, and a bar at its leading
/// edge that still shows over the selection, in the selection's text color.
public final class MarkedRowView: NSTableRowView {
    /// The bar's width in points: enough to see, narrow enough to stay clear of the first
    /// column's text.
    static let barWidth: CGFloat = 3
    /// The marked row's fill: a light gray, faint enough that the alternating rows and the text
    /// read through it in light and dark mode alike, and unlike the blue of a selection.
    static let tint = NSColor.systemGray.withAlphaComponent(0.22)

    /// A row `table` has finished with, or a new one. A table keeps every row view made without
    /// an identifier, so a new one per row grew memory with each row scrolled past.
    public static func reused(in table: NSTableView) -> MarkedRowView {
        if let row = table.makeView(withIdentifier: identifier, owner: nil) as? MarkedRowView {
            return row
        }
        let row = MarkedRowView()
        row.identifier = identifier
        return row
    }

    private static let identifier = NSUserInterfaceItemIdentifier("MarkedRowView")

    public var isMarked = false {
        didSet { if isMarked != oldValue { needsDisplay = true } }
    }
    /// The marked row's fill in place of `tint`; nil for `tint`.
    public var markTint: NSColor? {
        didSet { if markTint != oldValue { needsDisplay = true } }
    }
    /// The line along the row's bottom, drawn by the row so each row can have its own; nil for
    /// none.
    public var bottomLine: NSColor? {
        didSet { if bottomLine != oldValue { needsDisplay = true } }
    }
    /// The line along each shown column's right edge, drawn by the row so the plain column can
    /// go without; nil for none.
    public var columnLines: NSColor? {
        didSet { if columnLines != oldValue { needsDisplay = true } }
    }
    /// The table column drawn plain, in the table's background with no line, alternating
    /// shade, mark or selection over it; nil for none.
    public var plainColumn: NSUserInterfaceItemIdentifier? {
        didSet { if plainColumn != oldValue { needsDisplay = true } }
    }

    override public func drawBackground(in dirtyRect: NSRect) {
        let plain = plainRect
        // The plain column is left out of the shade rather than painted over it: on the
        // window's glass the table's background is clear, and only nothing drawn shows the
        // glass.
        outside(plain) {
            super.drawBackground(in: dirtyRect)
            if let bottomLine {
                bottomLine.setFill()
                NSRect(x: 0, y: isFlipped ? bounds.maxY - 1 : 0, width: bounds.width, height: 1)
                    .fill(using: .sourceOver)
            }
            if let columnLines, let table = superview as? NSTableView {
                columnLines.setFill()
                for (column, tableColumn) in table.tableColumns.enumerated()
                where !tableColumn.isHidden {
                    let edge = table.rect(ofColumn: column).maxX - 1
                    NSRect(x: edge, y: bounds.minY, width: 1, height: bounds.height)
                        .fill(using: .sourceOver)
                }
            }
            if isMarked {
                (markTint ?? Self.tint).setFill()
                bounds.fill(using: .sourceOver)
            }
        }
        if let plain, let table = superview as? NSTableView {
            table.backgroundColor.setFill()
            plain.fill(using: .sourceOver)
        }
        guard isMarked else { return }
        drawBar(.controlAccentColor)
    }

    override public func drawSelection(in dirtyRect: NSRect) {
        outside(plainRect) { super.drawSelection(in: dirtyRect) }
        guard isMarked else { return }
        // The selection is the accent color while the table has the keys, so the bar takes
        // the selected text's color then.
        drawBar(isEmphasized ? .alternateSelectedControlTextColor : .controlAccentColor)
    }

    /// Where `plainColumn` is in the row, when the table shows it.
    private var plainRect: NSRect? {
        guard let plainColumn, let table = superview as? NSTableView else { return nil }
        let column = table.column(withIdentifier: plainColumn)
        guard column >= 0, !table.tableColumns[column].isHidden else { return nil }
        let rect = table.rect(ofColumn: column)
        return NSRect(x: rect.minX, y: bounds.minY, width: rect.width, height: bounds.height)
    }

    /// Runs `draw` clipped to the row without `plain`.
    private func outside(_ plain: NSRect?, _ draw: () -> Void) {
        guard let plain else { return draw() }
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: plain.minX, height: bounds.height))
        clip.append(
            NSBezierPath(
                rect: NSRect(
                    x: plain.maxX, y: 0, width: max(0, bounds.width - plain.maxX),
                    height: bounds.height)))
        clip.addClip()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBar(_ color: NSColor) {
        color.setFill()
        var bar = bounds
        bar.size.width = Self.barWidth
        bar.fill()
    }
}
