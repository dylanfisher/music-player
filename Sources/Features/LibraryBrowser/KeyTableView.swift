import AppKit

/// A table that offers each key press to `takeKey` before AppKit's own handling.
final class KeyTableView: NSTableView {
    var takeKey: (NSEvent) -> Bool = { _ in false }
    /// The column whose cells fill the column, the spacing and padding beside them included.
    var edgeToEdgeColumn: NSUserInterfaceItemIdentifier?
    /// The background color as set, which can follow the appearance. The table holds it
    /// resolved for the current appearance: with a system color, AppKit takes 130–160 ms to
    /// draw the alternating rows below the last row, as the empty table at launch shows, and a
    /// few ms with the same color resolved (ADR 0086).
    private var backgroundAsSet: NSColor?
    /// The last system color set, which may come back resolved.
    private var systemBackground: NSColor?

    override var backgroundColor: NSColor {
        get { super.backgroundColor }
        set {
            if newValue.type == .catalog { systemBackground = newValue }
            // A resolved color set back, as Glass puts back the one it replaced, is the system
            // color it came from, which goes on following the appearance.
            let source =
                systemBackground.flatMap { isResolved(newValue, from: $0) ? $0 : nil } ?? newValue
            backgroundAsSet = source
            super.backgroundColor = resolved(source, in: effectiveAppearance)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let backgroundAsSet {
            super.backgroundColor = resolved(backgroundAsSet, in: effectiveAppearance)
        }
    }

    private func isResolved(_ color: NSColor, from source: NSColor) -> Bool {
        [NSAppearance.Name.aqua, .darkAqua].contains { name in
            NSAppearance(named: name).map { color == resolved(source, in: $0) } ?? false
        }
    }

    private func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            // A pattern has no components and stays as it is.
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
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
