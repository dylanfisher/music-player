import AppKit
import Commands

/// What the track table and the play timeline share: the scrolling table, playing rows from a
/// double-click or the context menu, moving the selection by key, and keeping the rows the user
/// reads in place when the list changes. Each subclass is the table's data source and delegate,
/// and forwards `tableViewSelectionDidChange` to `selectionDidChange`.
@MainActor
class RowListController: NSViewController {
    let table = KeyTableView()
    /// Double-click or Return: the selected rows and the one clicked.
    let play: (IndexSet, Int) -> Void
    let playNext: (IndexSet) -> Void
    /// Called once, when the list first draws rows, for the launch measurement.
    var firstRowsDrawn: (() -> Void)?
    /// The row the keys move from, and the one an extending move keeps.
    private var cursor: Int?
    private var anchor: Int?
    private var movingByKey = false

    init(play: @escaping (IndexSet, Int) -> Void, playNext: @escaping (IndexSet) -> Void) {
        self.play = play
        self.playNext = playNext
        super.init(nibName: nil, bundle: nil)
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

    /// The style both lists share, double-click to play, and the Play and Play Next menu.
    func configureRows() {
        table.style = .fullWidth
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        // Only the title column has the autoresizing mask, so it takes up a change of width.
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(playClicked)
        let menu = NSMenu()
        menu.addItem(withTitle: "Play", action: #selector(playMenuRows), keyEquivalent: "")
        menu.addItem(
            withTitle: AppCommands.title(of: .playNext), action: #selector(playMenuRowsNext),
            keyEquivalent: "")
        for item in menu.items { item.target = self }
        table.menu = menu
    }

    /// Reports the first rows drawn, after this pass draws, so the measurement includes the
    /// first frame.
    func rowsDrawn() {
        guard let firstRowsDrawn else { return }
        self.firstRowsDrawn = nil
        DispatchQueue.main.async { firstRowsDrawn() }
    }

    // MARK: Keeping the place

    var clip: NSClipView? { table.enclosingScrollView?.contentView }

    /// The first visible row's ID, among the `ids` the table shows, and how far it sits from the
    /// top of the visible area. Nil above `firstRow`, for a list that should show rows added at
    /// its top.
    func scrollAnchor(in ids: [Int64], fromRow firstRow: Int = 0) -> (id: Int64, offset: CGFloat)? {
        guard let clip else { return nil }
        let top = clip.bounds.minY + clip.contentInsets.top
        let row = table.row(at: NSPoint(x: table.visibleRect.minX, y: top))
        guard row >= firstRow, ids.indices.contains(row) else { return nil }
        return (ids[row], table.rect(ofRow: row).minY - top)
    }

    /// Scrolls so `row`, the anchor's row now, sits where the anchor was.
    func restore(_ anchor: (id: Int64, offset: CGFloat), row: Int?) {
        guard let clip, let row else { return }
        let y = table.rect(ofRow: row).minY - anchor.offset - clip.contentInsets.top
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        table.enclosingScrollView?.reflectScrolledClipView(clip)
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

    /// Plays the selected rows from the first, or every row when none is selected.
    func playSelected() {
        guard table.numberOfRows > 0 else { return }
        play(table.selectedRowIndexes, table.selectedRowIndexes.first ?? 0)
    }

    func playSelectedNext() {
        guard !table.selectedRowIndexes.isEmpty else { return }
        playNext(table.selectedRowIndexes)
    }

    // MARK: Selection

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

    /// Selects `rows` alone, with the first as cursor and anchor, as after a reload.
    func select(_ rows: IndexSet) {
        select(ListSelection(rows: rows, cursor: rows.first, anchor: rows.first))
    }

    func select(_ selection: ListSelection) {
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

    /// The selection changed. A click makes the clicked row the cursor, and a Shift-click keeps
    /// the anchor. False for a change made by key, which already set both.
    @discardableResult
    func selectionDidChange() -> Bool {
        guard !movingByKey else { return false }
        let row = table.selectedRow >= 0 ? table.selectedRow : nil
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        cursor = row
        if !shift || anchor == nil { anchor = row }
        return true
    }
}

/// A cell of one text field in the lists' small font, numbers on the right.
@MainActor
func makeTextCell(_ identifier: NSUserInterfaceItemIdentifier, numeric: Bool) -> NSTableCellView {
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
