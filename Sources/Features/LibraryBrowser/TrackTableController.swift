import AppKit
import Library
import Log
import Settings

private let logger = moduleLogger()

/// The track table. It asks the model for IDs and the row cache for rows, and reports what the
/// user does; it decides nothing itself.
@MainActor
final class TrackTableController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate
{
    let table = NSTableView()
    private let model: BrowserModel
    private let cache: RowCache
    private let actions: BrowserActions
    /// Set while the table's sort descriptors are being set from the model, so that doesn't
    /// count as the user sorting.
    private var applyingSort = false
    /// A row fetch failed; reported once until the next reload.
    private var reportedFetchFailure = false
    /// The first time rows are drawn, for the launch measurement.
    var firstRowsDrawn: (() -> Void)?

    init(model: BrowserModel, cache: RowCache, layout: TrackTableLayout, actions: BrowserActions) {
        self.model = model
        self.cache = cache
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        configure(layout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
    }

    private func configure(_ layout: TrackTableLayout) {
        if #available(macOS 11.0, *) { table.style = .fullWidth }
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(playClicked)
        let shown = layout.columns.map(\.column)
        let order = shown + TrackColumn.allCases.filter { !shown.contains($0) }
        for column in order {
            let tableColumn = NSTableColumn(identifier: columnIdentifier(column))
            tableColumn.title = column.title
            tableColumn.width = layout.columns.first { $0.column == column }?.width ?? 100
            tableColumn.minWidth = TrackTableLayout.widthRange.lowerBound
            tableColumn.isHidden = !shown.contains(column)
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.rawValue, ascending: true)
            if column.isNumeric { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        let header = NSMenu()
        header.delegate = self
        table.headerView?.menu = header
        let menu = NSMenu()
        menu.addItem(withTitle: "Play", action: #selector(playSelection), keyEquivalent: "")
        menu.addItem(withTitle: "Play Next", action: #selector(playNext), keyEquivalent: "")
        for item in menu.items { item.target = self }
        table.menu = menu
        showSort()
    }

    // MARK: Model to view

    /// Reloads after the model changed, keeping the selection, and the scroll position when the
    /// library changed under the user.
    func reload(_ change: BrowserChange, keeping selection: Set<Int64>) {
        reportedFetchFailure = false
        let anchor = change.reason == .libraryChanged ? scrollAnchor() : nil
        cache.setIDs(model.trackIDs)
        showSort()
        table.reloadData()
        let rows = model.rows(holding: selection)
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let anchor {
            restore(anchor)
        } else if let first = rows.first {
            table.scrollRowToVisible(first)
        } else {
            table.scroll(.zero)
        }
    }

    var selectedIDs: Set<Int64> {
        Set(
            table.selectedRowIndexes.compactMap {
                model.trackIDs.indices.contains($0) ? model.trackIDs[$0] : nil
            })
    }

    private func showSort() {
        applyingSort = true
        table.sortDescriptors = [
            NSSortDescriptor(key: model.sortColumn.rawValue, ascending: model.ascending)
        ]
        applyingSort = false
    }

    /// The first visible row's track and how far it sits from the top of the visible area.
    private func scrollAnchor() -> (id: Int64, offset: CGFloat)? {
        let visible = table.visibleRect
        let row = table.row(at: NSPoint(x: visible.minX, y: visible.minY))
        guard row >= 0, model.trackIDs.indices.contains(row) else { return nil }
        return (model.trackIDs[row], table.rect(ofRow: row).minY - visible.minY)
    }

    private func restore(_ anchor: (id: Int64, offset: CGFloat)) {
        guard let row = model.rows(holding: [anchor.id]).first else { return }
        let y = table.rect(ofRow: row).minY - anchor.offset
        table.scroll(NSPoint(x: table.visibleRect.minX, y: max(0, y)))
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { model.trackIDs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn, let column = TrackColumn(rawValue: tableColumn.identifier.rawValue)
        else { return nil }
        let cell =
            tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil)
            as? NSTableCellView ?? makeCell(tableColumn.identifier, numeric: column.isNumeric)
        cell.textField?.stringValue = (trackRow(row)).map(column.text) ?? ""
        if let firstRowsDrawn {
            self.firstRowsDrawn = nil
            // After this pass draws, so the measurement includes the first frame.
            DispatchQueue.main.async { firstRowsDrawn() }
        }
        return cell
    }

    private func trackRow(_ index: Int) -> TrackRow? {
        do {
            return try cache.row(at: index)
        } catch {
            if !reportedFetchFailure {
                reportedFetchFailure = true
                logger.error("couldn't read rows for the table: \(error)")
                actions.failed("couldn't read rows for the table: \(error)")
            }
            return nil
        }
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, numeric: Bool)
        -> NSTableCellView
    {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.alignment = numeric ? .right : .left
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard !applyingSort, let first = tableView.sortDescriptors.first, let key = first.key,
            let column = TrackColumn(rawValue: key)
        else { return }
        actions.sort(column, first.ascending)
    }

    func tableViewColumnDidMove(_ notification: Notification) { actions.layoutChanged(layout) }

    func tableViewColumnDidResize(_ notification: Notification) { actions.layoutChanged(layout) }

    /// The visible columns as they stand, and the model's sort.
    var layout: TrackTableLayout {
        TrackTableLayout(
            columns: table.tableColumns.filter { !$0.isHidden }.compactMap { tableColumn in
                TrackColumn(rawValue: tableColumn.identifier.rawValue).map {
                    ColumnLayout(column: $0, width: Double(tableColumn.width.rounded()))
                }
            }, sortColumn: model.sortColumn, sortAscending: model.ascending)
    }

    // MARK: Header menu: one item per column, checked when shown

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let visible = table.tableColumns.filter { !$0.isHidden }.count
        for column in TrackColumn.allCases {
            guard let tableColumn = table.tableColumn(withIdentifier: columnIdentifier(column))
            else {
                continue
            }
            let item = NSMenuItem(
                title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = tableColumn.isHidden ? .off : .on
            // The table always keeps one column.
            item.isEnabled = tableColumn.isHidden || visible > 1
            menu.addItem(item)
        }
    }

    @objc private func toggleColumn(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
            let tableColumn = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(raw))
        else { return }
        tableColumn.isHidden.toggle()
        actions.layoutChanged(layout)
    }

    // MARK: Playing

    @objc private func playClicked() {
        let clicked = table.clickedRow
        guard clicked >= 0 else { return }
        actions.play(table.selectedRowIndexes, clicked)
    }

    /// The context menu's rows: the clicked row's selection, or the clicked row alone when it
    /// isn't selected, as Finder does.
    private var menuRows: IndexSet {
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) { return [clicked] }
        return table.selectedRowIndexes
    }

    @objc private func playSelection() {
        let rows = menuRows
        guard let first = rows.first else { return }
        actions.play(rows, first)
    }

    @objc func playNext() {
        let rows = menuRows
        guard !rows.isEmpty else { return }
        actions.playNext(rows)
    }

    override func keyDown(with event: NSEvent) {
        // Return plays the selection, as in Finder's open.
        if event.keyCode == 36, let first = table.selectedRowIndexes.first {
            actions.play(table.selectedRowIndexes, first)
        } else {
            super.keyDown(with: event)
        }
    }
}

private func columnIdentifier(_ column: TrackColumn) -> NSUserInterfaceItemIdentifier {
    NSUserInterfaceItemIdentifier(column.rawValue)
}
