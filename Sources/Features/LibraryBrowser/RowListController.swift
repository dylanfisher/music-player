import AppKit
import Commands

/// What the track table and the play timeline share: the scrolling table, playing rows from a
/// double-click, moving the selection by key, and keeping the rows the user
/// reads in place when the list changes. Each subclass is the table's data source and delegate,
/// and forwards `tableViewSelectionDidChange` to `selectionDidChange`.
@MainActor
class RowListController: NSViewController {
    /// The rows' height in points until the track table's Row Height setting changes it.
    nonisolated static let rowHeight: CGFloat = 18

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
        // Layer-backed, so the table scrolls responsively: AppKit moves the drawn rows and draws
        // only the ones uncovered.
        scroll.wantsLayer = true
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
    }

    /// The style both lists share, and double-click to play.
    func configureRows() {
        table.style = .fullWidth
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        // Set, so KeyTableView resolves it.
        table.backgroundColor = .controlBackgroundColor
        table.allowsMultipleSelection = true
        // Only the title column has the autoresizing mask, so it takes up a change of width.
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(playClicked)
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
        doubleClicked()
        play(table.selectedRowIndexes, clicked)
    }

    /// A double-click on a row, before it plays: what its first click started can be undone.
    func doubleClicked() {}

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
        center(row)
    }

    /// Scrolls `row` to the middle of the visible rows, as far as the list allows.
    func center(_ row: Int) {
        guard let clip else { return }
        let visible = clip.bounds.height - clip.contentInsets.top - clip.contentInsets.bottom
        let y = table.rect(ofRow: row).midY - visible / 2 - clip.contentInsets.top
        let bottom = lastScrollY(clip)
        clip.scroll(
            to: NSPoint(
                x: clip.bounds.minX, y: max(-clip.contentInsets.top, min(y, max(0, bottom)))))
        table.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// How far down the clip can scroll: to the last row above the bottom inset, which the
    /// status bar lies over.
    private func lastScrollY(_ clip: NSClipView) -> CGFloat {
        table.bounds.height - clip.bounds.height + clip.contentInsets.bottom
    }

    /// Scrolls the list `rows` rows down, or up when negative, leaving the selection alone.
    func scroll(byRows rows: Int) {
        guard let clip else { return }
        let pitch = table.rowHeight + table.intercellSpacing.height
        let bottom = max(-clip.contentInsets.top, lastScrollY(clip))
        let y = min(max(clip.bounds.minY + CGFloat(rows) * pitch, -clip.contentInsets.top), bottom)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        table.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Scrolls the first selected row to the middle, if a row is selected.
    func centerSelection() {
        if let first = table.selectedRowIndexes.first { center(first) }
    }

    /// Scrolls the first selected row to the middle if it isn't on screen.
    func centerSelectionIfHidden() {
        guard let first = table.selectedRowIndexes.first,
            !table.visibleRect.contains(table.rect(ofRow: first))
        else { return }
        center(first)
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

    /// Whole rows on screen between the header and the status bar.
    private var pageRows: Int {
        guard let clip else { return 1 }
        let height = clip.bounds.height - clip.contentInsets.top - clip.contentInsets.bottom
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
