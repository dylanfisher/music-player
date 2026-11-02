import AppKit

/// A table that offers each key press to `takeKey` before AppKit's own handling.
final class KeyTableView: NSTableView {
    var takeKey: (NSEvent) -> Bool = { _ in false }

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
