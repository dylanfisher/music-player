import AppKit
import Commands
import DisplayText
import KeyChord
import Log
import Playback

/// The queue beside the track table: the current track, marked, then what plays after it.
/// Drag to reorder, Delete to remove, double-click to play one. Edits go to the engine, and the
/// panel redraws from its next update.
@MainActor
public final class QueuePanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let model: QueueModel
    /// Runs the command a key press in the queue is bound to.
    public var keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome = { _ in .unbound }
    private var engine: PlaybackEngine?
    private var updates: Task<Void, Never>?
    private let table = QueueTable()
    private var cursor: Int?
    private var anchor: Int?
    private let summary = NSTextField(labelWithString: "")
    private static let rowType = NSPasteboard.PasteboardType("\(bundleIdentifier).queue-rows")

    public init(model: QueueModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// Follows `engine` from now on.
    public func connect(_ engine: PlaybackEngine) {
        self.engine = engine
        updates?.cancel()
        updates = Task { [weak self] in
            for await update in await engine.updates() {
                guard let self else { return }
                // Only queue changes and track changes move rows or the marker.
                guard update.event.map(Self.concernsQueue) ?? true else { continue }
                self.show(update.state)
            }
        }
    }

    /// Lists `state`'s queue from its current track on. When the next track starts, the rows
    /// played leave the top and the rest move up as they are: reloading them all costs about
    /// 40 ms on the build Mac, since each row lays out its fields again.
    public func show(_ state: PlaybackState) {
        let rowsBefore = table.numberOfRows
        if let dropped = model.apply(state), dropped < rowsBefore {
            table.removeRows(at: IndexSet(integersIn: 0..<dropped), withAnimation: [])
            // The keys move from the same tracks, now higher up.
            cursor = cursor.map { $0 - dropped }.flatMap { $0 >= 0 ? $0 : nil }
            anchor = anchor.map { $0 - dropped }.flatMap { $0 >= 0 ? $0 : nil }
            // Row 0 is the current track now, marked and bold.
            table.reloadData(forRowIndexes: [0], columnIndexes: [0])
            (table.rowView(atRow: 0, makeIfNecessary: false) as? MarkedRowView)?.isMarked = true
        } else {
            table.reloadData()
        }
        summary.stringValue = model.summary
    }

    /// A rescan may have changed the queued tracks' tags.
    public func libraryChanged() {
        model.libraryChanged()
        table.reloadData()
    }

    private static func concernsQueue(_ event: PlaybackEvent) -> Bool {
        switch event {
        case .queueChanged, .trackStarted, .shuffleChanged, .finished, .stopped, .failed,
            .deviceLost:
            true
        default: false
        }
    }

    override public func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("queueEntry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(playClicked)
        table.registerForDraggedTypes([Self.rowType])
        table.deleteSelection = { [weak self] in self?.removeSelection() }
        table.keyCommand = { [weak self] chords in self?.keyCommand(chords) ?? .unbound }
        let menu = NSMenu()
        menu.addItem(withTitle: "Play", action: #selector(playClicked), keyEquivalent: "")
        menu.addItem(
            withTitle: "Remove from Queue", action: #selector(removeClicked), keyEquivalent: "")
        for item in menu.items { item.target = self }
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let title = NSTextField(labelWithString: "Queue")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, summary])
        header.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 4, right: 8)
        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for view in [header, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = stack
        summary.stringValue = model.summary
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { model.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let cell =
            tableView.makeView(withIdentifier: QueueCell.identifier, owner: nil) as? QueueCell
            ?? QueueCell()
        cell.show(model.item(at: row), current: row == model.currentRow)
        return cell
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = MarkedRowView.reused(in: tableView)
        rowView.isMarked = row == model.currentRow
        return rowView
    }

    // MARK: Reordering by drag

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> (any NSPasteboardWriting)?
    {
        // Moving the current track down would put the rows it passes before it, out of the
        // list.
        guard row != model.currentRow else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    public func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        tableView.setDropRow(model.dropRow(row), dropOperation: .above)
        return .move
    }

    public func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let rows = IndexSet(
            (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
                $0.string(forType: Self.rowType).flatMap(Int.init)
            })
        guard let engine, !rows.isEmpty else { return false }
        let positions = model.positions(ofRows: rows)
        let destination = model.position(ofRow: row)
        Task { await engine.moveQueueItems(positions, to: destination) }
        return true
    }

    // MARK: Actions

    @objc private func playClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let engine, row >= 0 else { return }
        let position = model.position(ofRow: row)
        Task { await engine.play(at: position) }
    }

    @objc private func removeClicked() {
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
            remove([clicked])
        } else {
            removeSelection()
        }
    }

    /// The queue's list, for moving the keys to it.
    public var list: NSView { table }

    public var hasSelection: Bool { !table.selectedRowIndexes.isEmpty }

    public func removeSelection() { remove(table.selectedRowIndexes) }

    /// Moves the selection, as the browser's lists do.
    public func move(_ move: RowMove, extending: Bool) {
        let rows = table.selectedRowIndexes
        let next = ListSelection(rows: rows, cursor: cursor ?? rows.last, anchor: anchor).moved(
            move, extending: extending, rowCount: table.numberOfRows,
            pageRows: Int(table.visibleRect.height / max(1, table.rowHeight)))
        table.selectRowIndexes(next.rows, byExtendingSelection: false)
        cursor = next.cursor
        anchor = next.anchor
        if let cursor { table.scrollRowToVisible(cursor) }
    }

    public func selectAll() { table.selectAll(nil) }

    /// Plays the first selected track.
    public func playSelection() {
        guard let engine, let row = table.selectedRowIndexes.first else { return }
        let position = model.position(ofRow: row)
        Task { await engine.play(at: position) }
    }

    private func remove(_ rows: IndexSet) {
        guard let engine, !rows.isEmpty else { return }
        table.deselectAll(nil)
        let positions = model.positions(ofRows: rows)
        Task { await engine.removeQueueItems(positions) }
    }
}

/// Takes Delete and forward delete without ⌘, ⌃ or ⌥, which a plain NSTableView ignores, before
/// the registry: Delete is Remove…'s chord in the track table, and here it removes from the
/// queue. Other key presses, ⌘⌫ among them, go to the registry first, as in the browser's lists.
private final class QueueTable: NSTableView {
    var deleteSelection: () -> Void = {}
    var keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome = { _ in .unbound }

    override func keyDown(with event: NSEvent) {
        let delete = event.charactersIgnoringModifiers?.unicodeScalars.first.map {
            Int($0.value) == NSDeleteCharacter || Int($0.value) == NSDeleteFunctionKey
        }
        if delete == true, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            return deleteSelection()
        }
        let chords = KeyChord.candidates(for: event)
        switch keyCommand(chords) {
        case .ran: return
        case .refused:
            NSSound.beep()
            return
        case .unbound: break
        }
        if let chord = chords.first,
            !chord.modifiers.isDisjoint(with: [.command, .control, .option])
        {
            NSSound.beep()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A queue row: title over "artist — album", the length on the right, bold when current.
private final class QueueCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("QueueCell")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let length = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        length.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        length.textColor = .secondaryLabelColor
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let row = NSStackView(views: [text, length])
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    func show(_ item: QueueItem, current: Bool) {
        title.stringValue = (current ? "▶ " : "") + item.title
        title.font =
            current
            ? .boldSystemFont(ofSize: NSFont.systemFontSize)
            : .systemFont(ofSize: NSFont.systemFontSize)
        detail.stringValue = item.detail
        length.stringValue = item.durationSeconds.map(clock) ?? ""
    }
}
