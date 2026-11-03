import AppKit

/// A table that offers each key press to `takeKey` before AppKit's own handling.
final class KeyTableView: NSTableView, ResolvedBackgroundTable {
    var takeKey: (NSEvent) -> Bool = { _ in false }
    /// The column whose cells fill the column, the spacing and padding beside them included.
    var edgeToEdgeColumn: NSUserInterfaceItemIdentifier?
    /// The color the table was given, which can follow the appearance. The table holds it
    /// resolved for the current appearance: with a system color, AppKit takes 130–160 ms to
    /// draw the alternating rows below the last row, as the empty table at launch shows, and a
    /// few ms with the same color resolved (ADR 0086).
    private(set) var backgroundAsSet: NSColor = .controlBackgroundColor

    override var backgroundColor: NSColor {
        get { super.backgroundColor }
        set {
            backgroundAsSet = newValue
            super.backgroundColor = resolved(newValue)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        super.backgroundColor = resolved(backgroundAsSet)
    }

    private func resolved(_ color: NSColor) -> NSColor {
        var resolved = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // A pattern has no components and stays as it is.
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    /// The tint of every other row on the window's glass, where AppKit's alternating colors,
    /// which are opaque, would hide it: the text's color, faint, so it darkens in light mode and
    /// lightens in dark.
    static let translucentRowColor = NSColor.labelColor.withAlphaComponent(0.05)
    /// Draws every other row in `translucentRowColor`, in place of AppKit's alternating rows.
    var drawsTranslucentRows = false {
        didSet { if drawsTranslucentRows != oldValue { needsDisplay = true } }
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        guard drawsTranslucentRows else { return }
        Self.translucentRowColor.setFill()
        let rows = rows(in: clipRect)
        // Odd rows, as AppKit's second alternating color.
        for row in rows.location..<rows.location + rows.length where row % 2 == 1 {
            rect(ofRow: row).intersection(clipRect).fill(using: .sourceOver)
        }
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        guard let edgeToEdgeColumn, tableColumns.indices.contains(column),
            tableColumns[column].identifier == edgeToEdgeColumn
        else { return frame }
        let columnRect = rect(ofColumn: column)
        return NSRect(
            x: columnRect.minX, y: frame.minY, width: columnRect.width, height: frame.height)
    }

    override func keyDown(with event: NSEvent) {
        if !takeKey(event) { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard menu != nil, prepareMenu(at: row(at: convert(event.locationInWindow, from: nil)))
        else { return nil }
        return super.menu(for: event)
    }

    /// Before the context menu opens on `row`: selects it when it isn't selected, as Swinsian
    /// does, and takes the keys, since the menu's commands act on the selection of the list
    /// with the keys. False off the rows, where there is no menu.
    func prepareMenu(at row: Int) -> Bool {
        guard row >= 0 else { return false }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        window?.makeFirstResponder(self)
        return true
    }
}

/// The sidebar's outline, with the same hook.
final class KeyOutlineView: NSOutlineView {
    var takeKey: (NSEvent) -> Bool = { _ in false }

    override func keyDown(with event: NSEvent) {
        if !takeKey(event) { super.keyDown(with: event) }
    }
}
