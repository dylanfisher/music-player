import AppKit
import Artwork
import Commands
import DisplayText
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
    private var typeSelect: TypeSelect? = TypeSelect()
    /// How the Album Art column draws, and the loader for that size, replaced when either
    /// changes.
    private var artSize = ArtSize.thumbnail
    private var art: RowArt
    /// The model's `emptyText`, centered over the table, hidden while it's nil.
    let emptyLabel = NSTextField(labelWithString: "")
    /// Called after every change of the selection, the keys' and a reload's too.
    var selectionChanged: () -> Void = {}
    /// The file of the track playing, whose row is marked wherever the table shows it.
    var playingPath: String? {
        didSet {
            guard playingPath != oldValue else { return }
            table.enumerateAvailableRowViews { rowView, row in
                (rowView as? MarkedRowView)?.isMarked = isPlaying(row)
            }
        }
    }

    init(model: BrowserModel, cache: RowCache, layout: TrackTableLayout, actions: BrowserActions) {
        self.model = model
        self.cache = cache
        self.actions = actions
        art = RowArt(artSize, rowHeight: Self.rowHeight)
        super.init(play: actions.play, playNext: actions.playNext)
        configure(layout)
        follow(art)
    }

    /// Points `art` at the rows on screen. A replaced loader wants nothing more and shows
    /// nothing it was still loading.
    private func follow(_ art: RowArt) {
        art.isWanted = { [weak self, weak art] key in
            guard let self, art === self.art else { return false }
            return visibleRows().contains { self.artKey($0) == key }
        }
        art.loaded = { [weak self, weak art] key, image in
            guard let self, art === self.art else { return }
            show(image, for: key)
        }
    }

    override func loadView() {
        super.loadView()
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
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
            tableColumn.width =
                layout.columns.first { $0.column == column }?.width
                ?? column.defaultWidth
            tableColumn.minWidth = TrackTableLayout.widthRange.lowerBound
            tableColumn.maxWidth = TrackTableLayout.widthRange.upperBound
            tableColumn.isHidden = !shown.contains(column)
            tableColumn.resizingMask =
                column == .title ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            if column.isSortable {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                    key: column.rawValue, ascending: true)
            }
            if column.isNumeric { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        let header = NSMenu()
        header.delegate = self
        table.headerView?.menu = header
        showSort()
    }

    /// Draws the lines, rows and art as the appearance settings say.
    func apply(_ appearance: TableAppearance) {
        var lines: NSTableView.GridLineStyle = []
        if appearance.columnLines { lines.insert(.solidVerticalGridLineMask) }
        if appearance.rowLines { lines.insert(.solidHorizontalGridLineMask) }
        table.gridStyleMask = lines
        table.usesAlternatingRowBackgroundColors = appearance.alternatingRows
        let rowHeight = appearance.rowHeight.points
        guard appearance.artSize != artSize || rowHeight != table.rowHeight else { return }
        table.rowHeight = rowHeight
        artSize = appearance.artSize
        art = RowArt(artSize, rowHeight: rowHeight)
        follow(art)
        // The art column's cells change kind, and their images size.
        table.reloadData()
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
        emptyLabel.stringValue = model.emptyText ?? ""
        emptyLabel.isHidden = model.emptyText == nil
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = MarkedRowView.reused(in: tableView)
        rowView.isMarked = isPlaying(row)
        return rowView
    }

    /// Whether `row` shows the track playing. Read from the row cache, which already holds the
    /// rows on screen.
    func isPlaying(_ row: Int) -> Bool {
        guard let playingPath, model.trackIDs.indices.contains(row) else { return false }
        return trackRow(row)?.path == playingPath
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn, let column = TrackColumn(rawValue: tableColumn.identifier.rawValue)
        else { return nil }
        if column == .art {
            rowsDrawn()
            switch artSize {
            case .thumbnail:
                let cell =
                    tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil)
                    as? NSTableCellView ?? makeImageCell(tableColumn.identifier)
                cell.imageView?.image = image(ofArtIn: row)
                return cell
            case .fullWidth:
                let cell =
                    tableView.makeView(withIdentifier: fullWidthArtIdentifier, owner: nil)
                    as? AlbumArtCell ?? makeFullWidthCell()
                fill(cell, row: row)
                return cell
            }
        }
        let cell =
            tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil)
            as? NSTableCellView ?? makeTextCell(tableColumn.identifier, numeric: column.isNumeric)
        cell.textField?.stringValue = trackRow(row).map { column.text($0, position: row) } ?? ""
        rowsDrawn()
        return cell
    }

    // MARK: Album art

    /// The rows on screen, whose art is worth loading.
    private func visibleRows() -> Range<Int> {
        let rows = table.rows(in: table.visibleRect)
        return rows.location..<min(rows.location + rows.length, model.trackIDs.count)
    }

    /// The row whose art `row` shows: its own, or at full width its album's first row's; nil
    /// for a row below its album's art.
    func artRow(_ row: Int) -> Int? {
        switch artSize {
        case .thumbnail: return row
        case .fullWidth:
            guard let column = table.tableColumn(withIdentifier: columnIdentifier(.art)) else {
                return nil
            }
            let side = AlbumArtCell.side(width: column.width)
            let pitch = table.rowHeight + table.intercellSpacing.height
            let rowsTall = Int(((AlbumArtCell.inset + side) / pitch).rounded(.up))
            return ArtRun.start(of: row, rowsTall: max(1, rowsTall)) { trackRow($0)?.albumID }
        }
    }

    private func artKey(_ row: Int) -> ArtworkKey? {
        guard let shown = artRow(row), let track = trackRow(shown), let embedded = track.art
        else { return nil }
        return ArtworkKey(path: track.path, offset: embedded.offset)
    }

    /// The cached image of `row`'s own art, or nil after asking for it to be loaded.
    private func image(ofArtIn row: Int) -> NSImage? {
        trackRow(row).flatMap { track in
            track.art.flatMap { art.image($0, path: track.path) }.map {
                NSImage(cgImage: $0, size: .zero)
            }
        }
    }

    /// Sets a full-width cell to its part of its album's art.
    private func fill(_ cell: AlbumArtCell, row: Int) {
        cell.rowPitch = table.rowHeight + table.intercellSpacing.height
        guard let start = artRow(row) else {
            cell.art = nil
            return
        }
        cell.rowsDown = row - start
        cell.art = image(ofArtIn: start)
    }

    /// Puts a loaded image in each row on screen that shows its art.
    private func show(_ image: CGImage, for key: ArtworkKey) {
        let column = table.column(withIdentifier: columnIdentifier(.art))
        guard column >= 0 else { return }
        for row in visibleRows() where artKey(row) == key {
            let image = NSImage(cgImage: image, size: .zero)
            switch table.view(atColumn: column, row: row, makeIfNecessary: false) {
            case let cell as AlbumArtCell: cell.art = image
            case let cell as NSTableCellView: cell.imageView?.image = image
            default: break
            }
        }
    }

    /// Fits each full-width cell to the art column's new width, which moves where an album's
    /// art ends.
    private func refitArt() {
        let column = table.column(withIdentifier: columnIdentifier(.art))
        guard column >= 0 else { return }
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: column) as? AlbumArtCell).map { fill($0, row: row) }
        }
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

    func tableViewColumnDidResize(_ notification: Notification) {
        actions.layoutChanged(layout)
        let resized = notification.userInfo?["NSTableColumn"] as? NSTableColumn
        if artSize == .fullWidth, resized?.identifier == columnIdentifier(.art) { refitArt() }
    }

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
        selectionChanged()
    }

    /// Selects the first row whose sort column starts with `query`.
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
            let texts = names.lazy.map { typeSelectText($0, sortedBy: column) }
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

/// The text type-to-select matches in a row of a table sorted by `column`: the artist it sorts
/// by, so a compilation grouped under Various Artists isn't found by a track artist's name, or
/// the album or genre when the table sorts by one, else the title.
func typeSelectText(_ name: TrackName, sortedBy column: TrackColumn) -> String {
    switch column {
    case .artist: name.sortArtist ?? ""
    case .album: name.album ?? ""
    case .genre: name.genre ?? ""
    default: name.title
    }
}

private func columnIdentifier(_ column: TrackColumn) -> NSUserInterfaceItemIdentifier {
    NSUserInterfaceItemIdentifier(column.rawValue)
}

/// The full-width art cells' identifier, apart from the thumbnails' so neither is reused as the
/// other.
private let fullWidthArtIdentifier = NSUserInterfaceItemIdentifier(
    TrackColumn.art.rawValue + "." + ArtSize.fullWidth.rawValue)

@MainActor
private func makeFullWidthCell() -> AlbumArtCell {
    let cell = AlbumArtCell()
    cell.identifier = fullWidthArtIdentifier
    return cell
}

/// A cell of one image, scaled down to fit the row.
@MainActor
private func makeImageCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let image = NSImageView()
    image.imageScaling = .scaleProportionallyDown
    image.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(image)
    cell.imageView = image
    NSLayoutConstraint.activate([
        image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1),
        image.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -1),
        image.topAnchor.constraint(equalTo: cell.topAnchor, constant: 1),
        image.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -1),
    ])
    return cell
}
