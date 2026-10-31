import AppKit
import Commands
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
    let table = KeyTableView()
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
    /// The row the keys move from, and the one an extending move keeps.
    private var cursor: Int?
    private var anchor: Int?
    private var movingByKey = false
    private var typeSelect: TypeSelect? = TypeSelect()

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
        table.style = .fullWidth
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        // Only the title column has the autoresizing mask, so it takes up a change of width.
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(playClicked)
        table.takeKey = { [weak self] event in self?.takeKey(event) ?? false }
        let shown = layout.columns.map(\.column)
        let order = shown + TrackColumn.allCases.filter { !shown.contains($0) }
        for column in order {
            let tableColumn = NSTableColumn(identifier: columnIdentifier(column))
            tableColumn.title = column.title
            tableColumn.width = layout.columns.first { $0.column == column }?.width ?? 100
            tableColumn.minWidth = TrackTableLayout.widthRange.lowerBound
            tableColumn.maxWidth = TrackTableLayout.widthRange.upperBound
            tableColumn.isHidden = !shown.contains(column)
            tableColumn.resizingMask =
                column == .title ? [.autoresizingMask, .userResizingMask] : .userResizingMask
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

    /// Reloads after the model changed, keeping the selected tracks selected, and the first
    /// visible track in place when the library changed under the user. The table still shows
    /// `change.previousIDs`, so the selection and position are read through those.
    func reload(_ change: BrowserChange) {
        reportedFetchFailure = false
        let selection = Set(
            table.selectedRowIndexes.compactMap {
                change.previousIDs.indices.contains($0) ? change.previousIDs[$0] : nil
            })
        let anchor =
            change.reason == .libraryChanged ? scrollAnchor(in: change.previousIDs) : nil
        cache.setIDs(model.trackIDs)
        showSort()
        typeSelect?.reset()
        table.reloadData()
        let rows = model.rows(holding: selection)
        select(ListSelection(rows: rows, cursor: rows.first, anchor: rows.first))
        if let anchor {
            restore(anchor)
        } else if let first = rows.first {
            table.scrollRowToVisible(first)
        } else if !model.trackIDs.isEmpty {
            table.scrollRowToVisible(0)
        }
    }

    private func showSort() {
        applyingSort = true
        table.sortDescriptors = [
            NSSortDescriptor(key: model.sortColumn.rawValue, ascending: model.ascending)
        ]
        applyingSort = false
    }

    private var clip: NSClipView? { table.enclosingScrollView?.contentView }

    /// The top of the area rows show in, below the header, in the table's coordinates.
    private var visibleTop: CGFloat {
        guard let clip else { return 0 }
        return clip.bounds.minY + clip.contentInsets.top
    }

    /// The first visible row's track, among the `ids` the table shows, and how far it sits from
    /// the top of the visible area.
    private func scrollAnchor(in ids: [Int64]) -> (id: Int64, offset: CGFloat)? {
        let top = visibleTop
        let row = table.row(at: NSPoint(x: table.visibleRect.minX, y: top))
        guard row >= 0, ids.indices.contains(row) else { return nil }
        return (ids[row], table.rect(ofRow: row).minY - top)
    }

    private func restore(_ anchor: (id: Int64, offset: CGFloat)) {
        guard let clip, let row = model.rows(holding: [anchor.id]).first else { return }
        let y = table.rect(ofRow: row).minY - anchor.offset - clip.contentInsets.top
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        table.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Scrolls through every row a screenful at a time, drawing each, and passes each row to
    /// `visit`. For measuring memory after the whole table has been seen.
    func scrollThroughEveryRow(_ visit: (TrackRow) -> Void) {
        let perScreen = max(1, Int(table.visibleRect.height / table.rowHeight))
        var first = 0
        while first < model.trackIDs.count {
            let last = min(model.trackIDs.count - 1, first + perScreen - 1)
            table.scrollRowToVisible(last)
            table.displayIfNeeded()
            for index in first...last {
                if let row = trackRow(index) { visit(row) }
            }
            first = last + 1
        }
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
                let message = "couldn't read rows for the table: \(error)"
                logger.error("\(message)")
                actions.failed(message)
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
        let widths = TrackTableLayout.widthRange
        return TrackTableLayout(
            columns: table.tableColumns.filter { !$0.isHidden }.compactMap { tableColumn in
                TrackColumn(rawValue: tableColumn.identifier.rawValue).map {
                    // Clamped, since Settings refuses a width outside the range.
                    ColumnLayout(
                        column: $0,
                        width: min(
                            max(Double(tableColumn.width.rounded()), widths.lowerBound),
                            widths.upperBound))
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

    /// Plays the selected rows from the first, or every row when none is selected.
    func playSelected() {
        guard model.trackIDs.count > 0 else { return }
        actions.play(table.selectedRowIndexes, table.selectedRowIndexes.first ?? 0)
    }

    func playSelectedNext() {
        guard !table.selectedRowIndexes.isEmpty else { return }
        actions.playNext(table.selectedRowIndexes)
    }

    // MARK: Keys

    private func takeKey(_ event: NSEvent) -> Bool {
        routeKey(event, typeSelect: &typeSelect, keyCommand: actions.keyCommand) {
            [weak self] query in
            self?.typeToSelect(query)
        }
    }

    func move(_ move: RowMove, extending: Bool) {
        let current = ListSelection(
            rows: table.selectedRowIndexes, cursor: cursor, anchor: anchor)
        select(
            current.moved(
                move, extending: extending, rowCount: table.numberOfRows, pageRows: pageRows))
        if let cursor { table.scrollRowToVisible(cursor) }
    }

    /// Selects the row at the middle of the visible rows, as Go to Item asks.
    func selectCentered(_ row: Int) {
        guard row >= 0, row < table.numberOfRows else { return }
        select(ListSelection(rows: [row], cursor: row, anchor: row))
        guard let clip else { return }
        let visible = clip.bounds.height - clip.contentInsets.top
        let y = table.rect(ofRow: row).midY - visible / 2 - clip.contentInsets.top
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(-clip.contentInsets.top, y)))
        table.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    private func select(_ selection: ListSelection) {
        movingByKey = true
        table.selectRowIndexes(selection.rows, byExtendingSelection: false)
        movingByKey = false
        cursor = selection.cursor
        anchor = selection.anchor
    }

    /// Whole rows on screen below the header.
    private var pageRows: Int {
        guard let clip else { return 1 }
        let height = clip.bounds.height - clip.contentInsets.top
        return max(1, Int(height / (table.rowHeight + table.intercellSpacing.height)))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !movingByKey else { return }
        // A click: the clicked row is the cursor, and a Shift-click keeps the anchor.
        let row = table.selectedRow >= 0 ? table.selectedRow : nil
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        cursor = row
        if !shift || anchor == nil { anchor = row }
        typeSelect?.reset()
    }

    /// Selects the first row whose sort column starts with `query`: the artist, album or genre
    /// when the table sorts by one, else the title.
    private func typeToSelect(_ query: String) {
        let column = model.sortColumn
        Task {
            let names: [TrackName]?
            do {
                names = try await model.trackNames()
            } catch {
                actions.failed("couldn't read the tracks' names: \(error)")
                return
            }
            guard let names, query == typeSelect?.query else { return }
            let texts = names.lazy.map { name in
                switch column {
                case .artist: name.artist ?? ""
                case .album: name.album ?? ""
                case .genre: name.genre ?? ""
                default: name.title
                }
            }
            guard let row = TypeSelect.firstIndex(startingWith: query, in: texts) else {
                NSSound.beep()
                return
            }
            move(to: row)
        }
    }

    private func move(to row: Int) {
        select(ListSelection(rows: [row], cursor: row, anchor: row))
        table.scrollRowToVisible(row)
    }
}

private func columnIdentifier(_ column: TrackColumn) -> NSUserInterfaceItemIdentifier {
    NSUserInterfaceItemIdentifier(column.rawValue)
}
