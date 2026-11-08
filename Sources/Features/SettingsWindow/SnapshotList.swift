import AppKit

/// The Library section's list of snapshots: when each was written and its size, newest first.
@MainActor
final class SnapshotList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let writtenColumn = NSUserInterfaceItemIdentifier("snapshotTaken")
    private static let rowsShown = 5.0

    let table = NSTableView()
    let scroll = NSScrollView()
    var snapshots: [LibraryDatabase.Snapshot] = [] {
        didSet { table.reloadData() }
    }
    /// Called as the selection changes.
    var selectionChanged: () -> Void = {}

    override init() {
        super.init()
        for (identifier, title, width) in [
            (Self.writtenColumn, "Taken", 220.0),
            (NSUserInterfaceItemIdentifier("snapshotBytes"), "Size on Disk", 90),
        ] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Snapshots")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 330),
            scroll.heightAnchor.constraint(
                equalToConstant: table.rowHeight * Self.rowsShown + 28),
        ])
    }

    /// The selected snapshot, if one is.
    var selected: LibraryDatabase.Snapshot? {
        snapshots.indices.contains(table.selectedRow) ? snapshots[table.selectedRow] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { snapshots.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let snapshot = snapshots[row]
        let text =
            tableColumn?.identifier == Self.writtenColumn
            ? snapshot.takenText
            : LibraryDatabase.bytesText(snapshot.bytes)
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }
}
