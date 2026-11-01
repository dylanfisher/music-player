import AppKit
import Commands
import Library
import Log
import Settings

private let logger = moduleLogger()

/// The track table. It asks the model for IDs and the row cache for rows, and reports what the
/// user does; it decides nothing itself.
@MainActor
final class TrackTableController: RowListController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate
{
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
    private var typeSelect: TypeSelect? = TypeSelect()

    init(model: BrowserModel, cache: RowCache, layout: TrackTableLayout, actions: BrowserActions) {
        self.model = model
        self.cache = cache
        self.actions = actions
        super.init(play: actions.play, playNext: actions.playNext)
        configure(layout)
    }

    private func configure(_ layout: TrackTableLayout) {
        configureRows()
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.dataSource = self
        table.delegate = self
        table.takeKey = { [weak self] event in self?.takeKey(event) ?? false }
        table.registerForDraggedTypes([trackIDsType])
        // Rows go only to the sidebar and to other rows, never to another app.
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
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
        select(rows)
        if let anchor {
            restore(anchor, row: model.rows(holding: [anchor.id]).first)
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
            as? NSTableCellView ?? makeTextCell(tableColumn.identifier, numeric: column.isNumeric)
        cell.textField?.stringValue = trackRow(row).map { column.text($0, position: row) } ?? ""
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

    // MARK: Dragging

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> (any NSPasteboardWriting)?
    {
        model.trackIDs.indices.contains(row) ? trackDragItem(model.trackIDs[row]) : nil
    }

    /// Rows move only within a manual playlist shown in its own order, between rows.
    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table, model.canReorder else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let ids = draggedTrackIDs(info.draggingPasteboard)
        guard !ids.isEmpty, model.canReorder else { return false }
        actions.move(ids, row)
        return true
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

    // MARK: Keys

    private func takeKey(_ event: NSEvent) -> Bool {
        routeKey(event, typeSelect: &typeSelect, keyCommand: actions.keyCommand) {
            [weak self] query in
            self?.typeToSelect(query)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if selectionDidChange() { typeSelect?.reset() }
    }

    /// Selects the first row whose sort column starts with `query`: the artist, album or genre
    /// when the table sorts by one, else the title.
    private func typeToSelect(_ query: String) {
        let column = model.sortColumn
        Task {
            let names: [TrackName]
            do {
                names = try await model.trackNames()
            } catch {
                actions.failed("couldn't read the tracks' names: \(error)")
                return
            }
            guard query == typeSelect?.query else { return }
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
