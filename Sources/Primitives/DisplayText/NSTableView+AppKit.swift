import AppKit

extension NSTableView {
    /// Adds a column with `identifier`, `title` and `width`; `stretches` lets it share the
    /// width the table gains, and the rest keep theirs.
    public func addColumn(
        _ identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat,
        stretches: Bool = false
    ) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.resizingMask =
            stretches ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        addTableColumn(column)
    }

    /// The table filled by `source`, with alternating full-width rows, in a bezeled scroll view:
    /// one look for the lists in sheets and panes.
    public func inListScrollView(source: some NSTableViewDataSource & NSTableViewDelegate)
        -> NSScrollView
    {
        dataSource = source
        delegate = source
        usesAlternatingRowBackgroundColors = true
        style = .fullWidth
        columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = self
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }
}
