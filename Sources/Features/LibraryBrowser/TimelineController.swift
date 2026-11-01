import AppKit
import Commands
import KeyChord
import Library
import Settings

/// The play timeline's table: one row per play, newest first. It asks the model for rows and
/// reports what the user does; it decides nothing itself. Rows are told apart by history ID
/// (ADR 0022), so the selection survives new plays above it.
@MainActor
final class TimelineController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table = KeyTableView()
    private let model: TimelineModel
    /// Double-click or Return: the selected rows and the one clicked.
    private let play: (IndexSet, Int) -> Void
    private let playNext: (IndexSet) -> Void
    private let keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome
    /// The track table's columns the timeline shows after Played, with their widths.
    private static let trackColumns: [(TrackColumn, CGFloat)] = [
        (.title, 260), (.artist, 180), (.album, 200), (.duration, 60),
    ]
    private static let playedColumn = NSUserInterfaceItemIdentifier("played")
    /// How close to the last loaded row drawing may get before the next page is read.
    private static let loadAheadRows = 50
    private var cursor: Int?
    private var anchor: Int?
    private var movingByKey = false
    private var typeSelect: TypeSelect?

    init(
        model: TimelineModel, play: @escaping (IndexSet, Int) -> Void,
        playNext: @escaping (IndexSet) -> Void,
        keyCommand: @escaping ([KeyChord]) -> CommandDispatcher.KeyOutcome
    ) {
        self.model = model
        self.play = play
        self.playNext = playNext
        self.keyCommand = keyCommand
        super.init(nibName: nil, bundle: nil)
        configure()
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

    private func configure() {
        table.style = .fullWidth
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(playClicked)
        table.takeKey = { [weak self] event in self?.takeKey(event) ?? false }
        // Rows go only to the sidebar's playlists, never to another app.
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        let played = NSTableColumn(identifier: Self.playedColumn)
        played.title = "Played"
        played.width = 130
        played.resizingMask = .userResizingMask
        table.addTableColumn(played)
        for (column, width) in Self.trackColumns {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = width
            tableColumn.resizingMask =
                column == .title ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            if column.isNumeric { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Play", action: #selector(playMenuRows), keyEquivalent: "")
        menu.addItem(withTitle: "Play Next", action: #selector(playMenuRowsNext), keyEquivalent: "")
        for item in menu.items { item.target = self }
        table.menu = menu
    }

    /// Reloads after the model changed, keeping the selected plays selected. The table still
    /// shows `previousIDs`, so the selection is read through those.
    func reload(previousIDs: [Int64]) {
        let selection = Set(
            table.selectedRowIndexes.compactMap {
                previousIDs.indices.contains($0) ? previousIDs[$0] : nil
            })
        let top = scrollAnchor(in: previousIDs)
        table.reloadData()
        let rows = model.rows(holding: selection)
        select(ListSelection(rows: rows, cursor: rows.first, anchor: rows.first))
        if let top { restore(top) }
    }

    private var clip: NSClipView? { table.enclosingScrollView?.contentView }

    /// The first visible play and how far it sits from the top, so plays added above it don't
    /// scroll the rows the user is reading.
    private func scrollAnchor(in ids: [Int64]) -> (id: Int64, offset: CGFloat)? {
        guard let clip else { return nil }
        let top = clip.bounds.minY + clip.contentInsets.top
        let row = table.row(at: NSPoint(x: table.visibleRect.minX, y: top))
        guard row > 0, ids.indices.contains(row) else { return nil }
        return (ids[row], table.rect(ofRow: row).minY - top)
    }

    private func restore(_ anchor: (id: Int64, offset: CGFloat)) {
        guard let clip, let row = model.rows(holding: [anchor.id]).first else { return }
        let y = table.rect(ofRow: row).minY - anchor.offset - clip.contentInsets.top
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        table.enclosingScrollView?.reflectScrolledClipView(clip)
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
        let column = TrackColumn(rawValue: tableColumn.identifier.rawValue)
        let cell =
            tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil)
            as? NSTableCellView
            ?? makeCell(tableColumn.identifier, numeric: column?.isNumeric == true)
        let text: String
        switch (column, entry.track) {
        case (nil, _):
            text = dateFormat.string(
                from: Date(timeIntervalSince1970: TimeInterval(entry.playedSeconds)))
        case (.title?, _): text = entry.title
        case (.artist?, nil): text = missingText
        case (_, nil): text = ""
        case (let column?, let track?): text = column.text(track, position: row)
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = entry.track == nil ? .tertiaryLabelColor : .labelColor
        cell.toolTip = entry.track == nil ? "\(missingText): \(entry.path)" : nil
        return cell
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

    /// A play's track, for dropping on a playlist; a missing file carries nothing.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> (any NSPasteboardWriting)?
    {
        guard model.entries.indices.contains(row), model.entries[row].track != nil else {
            return nil
        }
        return trackDragItem(model.entries[row].trackID)
    }

    // MARK: Playing

    @objc private func playClicked() {
        let clicked = table.clickedRow
        guard clicked >= 0 else { return }
        play(table.selectedRowIndexes, clicked)
    }

    /// The context menu's rows: the clicked row's selection, or the clicked row alone when it
    /// isn't selected, as Finder does.
    private var menuRows: IndexSet {
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) { return [clicked] }
        return table.selectedRowIndexes
    }

    @objc private func playMenuRows() {
        let rows = menuRows
        guard let first = rows.first else { return }
        play(rows, first)
    }

    @objc private func playMenuRowsNext() {
        let rows = menuRows
        guard !rows.isEmpty else { return }
        playNext(rows)
    }

    /// Plays the selected rows from the first, or every loaded row when none is selected.
    func playSelected() {
        guard !model.entries.isEmpty else { return }
        play(table.selectedRowIndexes, table.selectedRowIndexes.first ?? 0)
    }

    func playSelectedNext() {
        guard !table.selectedRowIndexes.isEmpty else { return }
        playNext(table.selectedRowIndexes)
    }

    // MARK: Keys and selection

    /// Every key goes through the registry; there's no sort column to type into.
    private func takeKey(_ event: NSEvent) -> Bool {
        routeKey(event, typeSelect: &typeSelect, keyCommand: keyCommand) { _ in }
    }

    func move(_ move: RowMove, extending: Bool) {
        let current = ListSelection(
            rows: table.selectedRowIndexes, cursor: cursor, anchor: anchor)
        select(
            current.moved(
                move, extending: extending, rowCount: table.numberOfRows, pageRows: pageRows))
        if let cursor { table.scrollRowToVisible(cursor) }
    }

    /// Selects `row` alone at the middle of the visible rows, as Go to Item asks.
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

    private var pageRows: Int {
        guard let clip else { return 1 }
        let height = clip.bounds.height - clip.contentInsets.top
        return max(1, Int(height / (table.rowHeight + table.intercellSpacing.height)))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !movingByKey else { return }
        let row = table.selectedRow >= 0 ? table.selectedRow : nil
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        cursor = row
        if !shift || anchor == nil { anchor = row }
    }
}

/// What the Artist column says for a play whose file is no longer in the index.
let missingText = "Not in the library"
