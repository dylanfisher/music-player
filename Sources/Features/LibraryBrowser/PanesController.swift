import AppKit
import Commands
import KeyChord
import Library
import Settings

/// The browser's three columns, side by side, each with an All row first. Right-clicking a
/// column's header picks what it groups by, as in Swinsian.
@MainActor
final class PanesController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate
{
    private let model: BrowserModel
    /// The columns' tables, left to right.
    private(set) var tables: [KeyTableView] = []
    /// An entry chosen, or All for nil, in the column grouping by what the columns showed.
    private let select: (BrowserGrouping, BrowserValue?) -> Void
    private let setGrouping: (BrowserGrouping, Int) -> Void
    private let keyCommand: ([KeyChord]) -> CommandDispatcher.KeyOutcome
    /// Moves the keys to the next column, or with false the previous one.
    private let focusPane: (Bool) -> Void
    /// Set while selections are set from the model, so they don't count as clicks.
    private var applying = false
    private var typeSelect: TypeSelect? = TypeSelect()

    init(
        model: BrowserModel, select: @escaping (BrowserGrouping, BrowserValue?) -> Void,
        setGrouping: @escaping (BrowserGrouping, Int) -> Void,
        keyCommand: @escaping ([KeyChord]) -> CommandDispatcher.KeyOutcome,
        focusPane: @escaping (Bool) -> Void
    ) {
        self.model = model
        self.select = select
        self.setGrouping = setGrouping
        self.keyCommand = keyCommand
        self.focusPane = focusPane
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func loadView() {
        // Equal widths, as in Swinsian; the columns don't resize apart from each other.
        let row = NSStackView()
        row.distribution = .fillEqually
        row.spacing = 1
        for column in 0..<BrowserColumn.count {
            let table = KeyTableView()
            table.takeKey = { [weak self] event in self?.takeKey(event, in: column) ?? false }
            let tableColumn = NSTableColumn(identifier: entryIdentifier)
            tableColumn.title = model.columns[column].header
            tableColumn.resizingMask = .autoresizingMask
            table.addTableColumn(tableColumn)
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.style = .fullWidth
            table.rowHeight = 18
            table.dataSource = self
            table.delegate = self
            let menu = NSMenu()
            menu.delegate = self
            table.headerView?.menu = menu
            tables.append(table)
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            row.addArrangedSubview(scroll)
        }
        view = row
    }

    func reload() {
        typeSelect?.reset()
        applying = true
        defer { applying = false }
        for (column, table) in tables.enumerated() {
            table.tableColumns.first?.headerCell.title = model.columns[column].header
            table.headerView?.needsDisplay = true
            table.reloadData()
            let entries = model.entries[column]
            let row =
                selected(column).flatMap { value in entries.firstIndex { $0.value == value } }
                .map { $0 + 1 } ?? 0
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    /// ← and → move between the columns, as in Swinsian, ahead of the registry, where they skip
    /// tracks: a column has no track of its own to skip.
    private func takeKey(_ event: NSEvent, in column: Int) -> Bool {
        if let chord = KeyChord(event: event), chord.modifiers.isEmpty,
            chord.key == .left || chord.key == .right
        {
            typeSelect?.reset()
            focusPane(chord.key == .right)
            return true
        }
        return routeKey(event, typeSelect: typeSelect, keyCommand: keyCommand) {
            [weak self] query in
            guard let self else { return }
            // Row 0 is All.
            guard
                let index = TypeSelect.firstIndex(
                    startingWith: query, in: model.entries[column].lazy.map(\.name))
            else {
                NSSound.beep()
                return
            }
            selectRow(index + 1, in: column)
        }
    }

    /// Moves a column's selection. Columns select one row, so an extending move is a plain one.
    func move(_ move: RowMove, in column: Int) {
        let table = tables[column]
        let row = table.selectedRow >= 0 ? table.selectedRow : nil
        let next = ListSelection(rows: row.map { [$0] } ?? [], cursor: row, anchor: row).moved(
            move, extending: false, rowCount: table.numberOfRows,
            pageRows: Int(table.visibleRect.height / max(1, table.rowHeight)))
        if let cursor = next.cursor { selectRow(cursor, in: column) }
    }

    private func selectRow(_ row: Int, in column: Int) {
        let table = tables[column]
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func column(of table: NSTableView) -> Int? {
        tables.firstIndex { $0 === table }
    }

    private func selected(_ column: Int) -> BrowserValue? {
        model.filter.selections[model.columns[column]]
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        column(of: tableView).map { model.entries[$0].count + 1 } ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let column = column(of: tableView) else { return nil }
        let identifier = entryIdentifier
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let text = NSTextField(labelWithString: "")
                text.lineBreakMode = .byTruncatingTail
                text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(text)
                cell.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
        let entries = model.entries[column]
        cell.textField?.stringValue =
            row == 0 ? model.columns[column].allTitle(entries.count) : entries[row - 1].name
        cell.textField?.font =
            row == 0
            ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applying, let table = notification.object as? NSTableView,
            let column = column(of: table)
        else { return }
        typeSelect?.reset()
        let row = table.selectedRow
        let entries = model.entries[column]
        // No selection, or the All row, means All.
        select(
            model.columns[column], row > 0 && row <= entries.count ? entries[row - 1].value : nil)
    }

    // MARK: Header menu: what the column groups by

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let column = tables.firstIndex(where: { $0.headerView?.menu === menu }) else {
            return
        }
        fill(menu, column: column)
    }

    /// Lists every grouping, the column's own checked.
    func fill(_ menu: NSMenu, column: Int) {
        menu.removeAllItems()
        for grouping in BrowserGrouping.allCases {
            let item = NSMenuItem(
                title: grouping.title, action: #selector(chooseGrouping(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = GroupingChoice(grouping: grouping, column: column)
            item.state = model.columns[column] == grouping ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func chooseGrouping(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? GroupingChoice else { return }
        setGrouping(choice.grouping, choice.column)
    }
}

/// A header menu item's grouping and the column it's for.
private final class GroupingChoice: NSObject {
    let grouping: BrowserGrouping
    let column: Int

    init(grouping: BrowserGrouping, column: Int) {
        self.grouping = grouping
        self.column = column
    }
}

/// Each column's one column of the table, and its cells.
private let entryIdentifier = NSUserInterfaceItemIdentifier("entry")

extension BrowserModel.Pane {
    public var title: String {
        switch self {
        case .genre: TrackColumn.genre.title
        case .artist: TrackColumn.artist.title
        case .album: TrackColumn.album.title
        }
    }
}
