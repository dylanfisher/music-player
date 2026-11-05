import AppKit
import Commands
import KeyChord
import Library
import Settings

/// The play timeline's table: one row per play, newest first. It asks the model for rows and
/// reports what the user does; it decides nothing itself. Rows are told apart by history ID
/// (ADR 0022), so the selection survives new plays above it. Its columns are Played and then
/// the track table's, until the user changes the timeline's own.
@MainActor
final class TimelineController: RowListController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate
{
    private let model: TimelineModel
    private let keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome
    private let failed: (String) -> Void
    /// A row read failed; reported once until the next reload.
    private var reportedFetchFailure = false
    private static let playedColumn = NSUserInterfaceItemIdentifier("played")
    /// Played's width while the timeline shows the track table's columns.
    static let playedWidth = 130.0
    /// The timeline's own columns, once the user changed them; nil while it shows the track
    /// table's.
    private(set) var ownLayout: TimelineLayout?
    /// Called with the timeline's columns each time the user changes them.
    var layoutChanged: (TimelineLayout) -> Void = { _ in }
    /// Set while `show` moves and resizes columns, which isn't the user's change.
    private var applyingColumns = false
    /// How close to the last loaded row drawing may get before the next page is read.
    private static let loadAheadRows = 50
    private var typeSelect: TypeSelect?

    /// `library` is the track table's layout, whose columns the timeline shows until it has
    /// its own.
    init(
        model: TimelineModel, library: TrackTableLayout, play: @escaping (IndexSet, Int) -> Void,
        playNext: @escaping (IndexSet) -> Void,
        keyCommand: @escaping ([KeyChord]) -> CommandDispatcher.KeyOutcome,
        failed: @escaping (String) -> Void
    ) {
        self.model = model
        self.keyCommand = keyCommand
        self.failed = failed
        super.init(play: play, playNext: playNext)
        configure()
        show(Self.layout(following: library))
    }

    private func configure() {
        configureRows()
        table.dataSource = self
        table.delegate = self
        table.takeKey = { [weak self] event in self?.takeKey(event) ?? false }
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        // Rows go only to the sidebar's playlists, never to another app.
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        let played = NSTableColumn(identifier: Self.playedColumn)
        played.title = "Played"
        played.resizingMask = .userResizingMask
        table.addTableColumn(played)
        for column in TrackColumn.allCases where TimelineLayout.shows(column) {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.defaultWidth
            tableColumn.isHidden = true
            tableColumn.resizingMask =
                column == .title ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            if column.isNumeric { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        for tableColumn in table.tableColumns {
            tableColumn.minWidth = TrackTableLayout.widthRange.lowerBound
            tableColumn.maxWidth = TrackTableLayout.widthRange.upperBound
        }
        let header = NSMenu()
        header.delegate = self
        table.headerView?.menu = header
    }

    // MARK: Columns

    /// The track table's columns as the timeline shows them: after Played, without the ones
    /// a play has nothing for.
    static func layout(following library: TrackTableLayout) -> TimelineLayout {
        TimelineLayout(
            playedWidth: playedWidth,
            columns: library.columns.filter { TimelineLayout.shows($0.column) })
    }

    /// Shows the track table's changed columns, unless the timeline has its own.
    func follow(_ library: TrackTableLayout) {
        guard ownLayout == nil else { return }
        show(Self.layout(following: library))
    }

    /// Shows the timeline's own columns, as saved, and keeps them from now on.
    func showOwn(_ layout: TimelineLayout) {
        ownLayout = layout
        show(layout)
    }

    /// Shows `layout`'s columns in its order and widths after Played, and hides the others.
    private func show(_ layout: TimelineLayout) {
        applyingColumns = true
        defer { applyingColumns = false }
        table.tableColumn(withIdentifier: Self.playedColumn)?.width = layout.playedWidth
        let shown = Set(layout.columns.map { NSUserInterfaceItemIdentifier($0.column.rawValue) })
        for tableColumn in table.tableColumns where tableColumn.identifier != Self.playedColumn {
            tableColumn.isHidden = !shown.contains(tableColumn.identifier)
        }
        for (place, entry) in layout.columns.enumerated() {
            let identifier = NSUserInterfaceItemIdentifier(entry.column.rawValue)
            guard let index = table.tableColumns.firstIndex(where: { $0.identifier == identifier })
            else { continue }
            table.tableColumns[index].width = entry.width
            if index != place + 1 { table.moveColumn(index, toColumn: place + 1) }
        }
    }

    /// The columns as they stand, widths clamped to what Settings accepts.
    var layout: TimelineLayout {
        let range = TrackTableLayout.widthRange
        let width = { (column: NSTableColumn) in
            min(max(Double(column.width.rounded()), range.lowerBound), range.upperBound)
        }
        let played = table.tableColumn(withIdentifier: Self.playedColumn).map(width)
        return TimelineLayout(
            playedWidth: played ?? Self.playedWidth,
            columns: table.tableColumns.filter { !$0.isHidden }.compactMap { tableColumn in
                TrackColumn(rawValue: tableColumn.identifier.rawValue).map {
                    ColumnLayout(column: $0, width: width(tableColumn))
                }
            })
    }

    /// The user changed the columns: from now on the timeline keeps its own.
    private func columnsChanged() {
        let layout = layout
        ownLayout = layout
        layoutChanged(layout)
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        if !applyingColumns { columnsChanged() }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        columnResized(byUser: (table.headerView?.resizedColumn ?? -1) >= 0)
    }

    /// A column changed width: by the user dragging its header's edge, or by the table taking
    /// up a change of its own width, which leaves the columns the track table's.
    func columnResized(byUser: Bool) {
        if byUser, !applyingColumns { columnsChanged() }
    }

    /// Played stays first.
    func tableView(
        _ tableView: NSTableView, shouldReorderColumn columnIndex: Int,
        toColumn newColumnIndex: Int
    ) -> Bool {
        columnIndex != 0 && newColumnIndex != 0
    }

    /// One item per track column the timeline can show, checked when shown. Played is always
    /// shown, so any of them can be hidden.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in TrackColumn.allCases where TimelineLayout.shows(column) {
            guard
                let tableColumn = table.tableColumn(
                    withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
            else { continue }
            let item = NSMenuItem(
                title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = tableColumn.isHidden ? .off : .on
            menu.addItem(item)
        }
    }

    @objc private func toggleColumn(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
            let tableColumn = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(raw))
        else { return }
        tableColumn.isHidden.toggle()
        columnsChanged()
    }

    /// Reloads after the model changed, keeping the selected plays selected. The table still
    /// shows `previousIDs`, so the selection is read through those.
    func reload(previousIDs: [Int64]) {
        let selection = Set(
            table.selectedRowIndexes.compactMap {
                previousIDs.indices.contains($0) ? previousIDs[$0] : nil
            })
        // Not anchored at the top row, so plays added above it show.
        let top = scrollAnchor(in: previousIDs, fromRow: 1)
        reportedFetchFailure = false
        table.reloadData()
        select(model.rows(holding: selection))
        if let top { restore(top, row: model.rows(holding: [top.id]).first) }
        // With no plays there are no rows to draw; the loaded, empty list is the first frame.
        if model.isLoaded, model.entries.isEmpty { rowsDrawn() }
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { model.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn, model.entries.indices.contains(row) else { return nil }
        if row >= model.entries.count - Self.loadAheadRows {
            Task { await model.loadMore() }
        }
        let entry = model.entries[row]
        let played = playedTrack(row)
        rowsDrawn()
        let column = TrackColumn(rawValue: tableColumn.identifier.rawValue)
        let cell =
            tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil)
            as? TextCell ?? TextCell(tableColumn.identifier, alignment: column?.alignment ?? .left)
        let text: String
        switch (column, played?.track) {
        case (nil, _):
            text = dateFormat.string(
                from: Date(timeIntervalSince1970: TimeInterval(entry.playedSeconds)))
        case (.title?, _): text = played?.title ?? ""
        case (.artist?, nil): text = missingText
        case (_, nil): text = ""
        case (let column?, let track?): text = column.text(track, position: row)
        }
        cell.text = text
        let missing = played.map { $0.track == nil } ?? false
        cell.textColor = missing ? .tertiaryLabelColor : .labelColor
        cell.toolTip = missing ? played.map { "\(missingText): \($0.path)" } : nil
        return cell
    }

    /// The file and track at `row`; nil, reported once, when they can't be read.
    private func playedTrack(_ row: Int) -> PlayedTrack? {
        do {
            return try model.played(at: row)
        } catch {
            if !reportedFetchFailure {
                reportedFetchFailure = true
                failed("couldn't read rows for the timeline: \(error)")
            }
            return nil
        }
    }

    /// A play's track, for dropping on a playlist; a missing file carries nothing.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> (any NSPasteboardWriting)?
    {
        guard model.entries.indices.contains(row), playedTrack(row)?.track != nil else {
            return nil
        }
        return trackDragItem(model.entries[row].trackID)
    }

    // MARK: Keys and selection

    /// Every key goes through the registry; there's no sort column to type into.
    private func takeKey(_ event: NSEvent) -> Bool {
        routeKey(event, typeSelect: typeSelect, keyCommand: keyCommand) { _ in }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { selectionDidChange() }
}

/// What the Artist column says for a play whose file is no longer in the index.
let missingText = "Not in the library"
