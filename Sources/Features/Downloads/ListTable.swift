import AppKit

/// `table` in a bezeled scroll view with alternating full-width rows, filled by `source`: the
/// look the Downloads window, its sheets and the tagger's tables share.
@MainActor
func listTable(
    _ table: NSTableView, source: some NSTableViewDataSource & NSTableViewDelegate
) -> NSScrollView {
    table.dataSource = source
    table.delegate = source
    table.usesAlternatingRowBackgroundColors = true
    table.style = .fullWidth
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    return scroll
}

/// A column of `table` with `identifier`, `title` and `width`; `stretches` lets it take the
/// width the table grows by.
@MainActor
func addColumn(
    to table: NSTableView, _ identifier: String, title: String, width: CGFloat,
    stretches: Bool = false
) {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
    column.title = title
    column.width = width
    column.resizingMask = stretches ? [.autoresizingMask, .userResizingMask] : .userResizingMask
    table.addTableColumn(column)
}
