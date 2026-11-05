import AppKit
import Commands
import KeyChord
import Library
import Settings

/// The play timeline's table: one row per play, newest first. It asks the model for rows and
/// reports what the user does; it decides nothing itself. Rows are told apart by history ID
/// (ADR 0022), so the selection survives new plays above it.
@MainActor
final class TimelineController: RowListController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: TimelineModel
    private let keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome
    private let failed: (String) -> Void
    /// A row read failed; reported once until the next reload.
    private var reportedFetchFailure = false
    /// The track table's columns the timeline shows after Played, with their widths.
    private static let trackColumns: [(TrackColumn, CGFloat)] = [
        (.title, 260), (.artist, 180), (.album, 200), (.duration, 60),
    ]
    private static let playedColumn = NSUserInterfaceItemIdentifier("played")
    /// How close to the last loaded row drawing may get before the next page is read.
    private static let loadAheadRows = 50
    private var typeSelect: TypeSelect?

    init(
        model: TimelineModel, play: @escaping (IndexSet, Int) -> Void,
        playNext: @escaping (IndexSet) -> Void,
        keyCommand: @escaping ([KeyChord]) -> CommandDispatcher.KeyOutcome,
        failed: @escaping (String) -> Void
    ) {
        self.model = model
        self.keyCommand = keyCommand
        self.failed = failed
        super.init(play: play, playNext: playNext)
        configure()
    }

    private func configure() {
        configureRows()
        table.dataSource = self
        table.delegate = self
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
            as? TextCell ?? TextCell(tableColumn.identifier, numeric: column?.isNumeric == true)
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
